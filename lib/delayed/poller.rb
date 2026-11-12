module Delayed
  # Runs a worker process: owns one or more Delayed::Workers, each on its own
  # thread, and feeds them jobs. Every worker process (forked, daemonized,
  # rake, or Worker#start) runs exactly one Poller, whatever its thread count.
  #
  # Each poll reserves only as many jobs as there are idle workers (via
  # Delayed::Job.reserve_batch) and hands one job to each, so the database is
  # polled once per cycle regardless of the thread count, and a job is never
  # locked while it waits for a free thread.
  #
  # Lifecycle callbacks:
  # * :loop wraps each poll and yields the Poller.
  # * :execute wraps each worker thread's lifetime and yields the Worker
  #   (so the ClearLocks plugin releases every worker's locks on exit).
  # * :perform, :error and :failure yield the Worker running the job.
  #
  # Queue and priority settings are process-wide (class-level settings of
  # Delayed::Worker), so all threads of a process work the same queues.
  class Poller # rubocop:disable ClassLength
    include Logging

    STOP = Object.new.freeze

    # Give up (raising FatalBackendError) after this many consecutive
    # failures to reserve jobs.
    MAX_FAILED_RESERVATIONS = 10

    # Log throughput at least this often while the queue stays busy.
    REPORT_EVERY = 100

    attr_reader :workers, :name_prefix

    # Options are those of Delayed::Worker, plus:
    # * :thread_count - number of workers (threads) to run (default 1)
    # * :workers - run these workers instead of building new ones
    def initialize(options = {})
      @quiet = options.key?(:quiet) ? options[:quiet] : true
      @workers = options[:workers] || build_workers(options)
      raise ArgumentError, 'thread_count must be 1 or greater' if @workers.empty?
      @workers.each { |worker| worker.poller = self }
      @stopped = false

      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @idle = []
      @inboxes = {}
      @threads = []
      @in_flight = 0
      @events = 0
      @thread_error = nil
      @failed_reserve_count = 0
      reset_stats
    end

    def thread_count
      workers.size
    end

    def name
      Worker.default_name(name_prefix)
    end

    def name_prefix=(prefix)
      @name_prefix = prefix
      workers.each { |worker| worker.name_prefix = prefix }
    end

    def start
      trap_signals
      run
    end

    # Runs until stopped, or with Worker.exit_on_complete until no job is
    # left, without installing signal traps. Running jobs are allowed to
    # finish before returning.
    def run
      say thread_count > 1 ? "Starting job worker with #{thread_count} threads" : 'Starting job worker'
      warn_if_connection_pool_too_small
      start_threads
      error = nil
      begin
        poll_loop
      rescue Exception => error # rubocop:disable RescueException
        raise
      ensure
        stop_threads(error)
      end
    end

    # Runs up to `num` jobs inline on the calling thread with the given worker
    # (no threads, no :loop callbacks), stopping early when no job is
    # available or the worker is stopped. Returns [succeeded, failed] counts.
    def work_off(num = 100, worker = workers.first)
      success = 0
      failure = 0
      num.times do
        _, job = reserve([worker]).first
        break unless job
        worker.perform_job(job) ? success += 1 : failure += 1
        break if worker.stop?
      end
      [success, failure]
    end

    def stop
      @stopped = true
      wake_up
    end

    def stop?
      @stopped
    end

  private

    def build_workers(options)
      count = Integer(options.fetch(:thread_count, 1))
      Array.new([count, 0].max) do |index|
        # Worker.new resets the global lifecycle, so all workers are built
        # here, before any thread starts.
        Worker.new(options).tap { |worker| worker.thread_index = index if count > 1 }
      end
    end

    # Signals INT and TERM stop the poller once running jobs finish, or raise
    # a SignalException, see Worker.raise_signal_exceptions.
    def trap_signals
      trap('TERM') do
        Thread.new { say 'Exiting...' }
        stop
        raise SignalException, 'TERM' if Worker.raise_signal_exceptions
      end

      trap('INT') do
        Thread.new { say 'Exiting...' }
        stop
        raise SignalException, 'INT' if Worker.raise_signal_exceptions && Worker.raise_signal_exceptions != :term
      end
    end

    def poll_loop # rubocop:disable CyclomaticComplexity, PerceivedComplexity
      until stop?
        raise_thread_error
        idle, seen = snapshot
        reserved = idle.empty? ? [] : poll(idle)
        reserved.each { |worker, job| dispatch(worker, job) }

        if reserved.empty? && in_flight.zero?
          report
          if Worker.exit_on_complete
            say 'No more jobs available. Exiting'
            break
          end
        elsif completed >= REPORT_EVERY
          report
        end

        # Wait for a worker to free up. If the queue ran dry, poll again
        # after sleep_delay so that newly enqueued jobs get picked up.
        wait_for_event(seen, reserved.size < idle.size ? Worker.sleep_delay : nil)
      end
      raise_thread_error
    end

    def poll(idle)
      reserved = []
      Worker.lifecycle.run_callbacks(:loop, self) { reserved = reserve(idle) }
      reserved
    end

    # Reserves up to one job per given worker. On error, lets the backend
    # recover and returns no jobs, until too many consecutive failures.
    def reserve(workers)
      reserved = with_executor { Delayed::Job.reserve_batch(workers) }
      @failed_reserve_count = 0
      reserved
    rescue ::Exception => error # rubocop:disable RescueException
      say "Error while reserving job: #{error}"
      Delayed::Job.recover_from(error)
      @failed_reserve_count += 1
      raise FatalBackendError if @failed_reserve_count >= MAX_FAILED_RESERVATIONS
      []
    end

    def start_threads
      @idle = workers.dup
      @threads = workers.each_with_index.map do |worker, index|
        inbox = @inboxes[worker] = Queue.new
        Thread.new { work(worker, inbox) }.tap do |thread|
          thread.report_on_exception = false if thread.respond_to?(:report_on_exception=)
          thread.name = "delayed_job worker:#{index}" if thread.respond_to?(:name=)
        end
      end
    end

    # Body of each worker thread: runs the jobs it is handed until told to stop.
    def work(worker, inbox)
      Worker.lifecycle.run_callbacks(:execute, worker) do
        until (job = inbox.pop).equal?(STOP)
          result = with_reloader { worker.perform_job(job) }
          job_finished(worker, result)
        end
      end
    rescue Exception => error # rubocop:disable RescueException
      synchronize do
        @thread_error ||= error
        signal_event
      end
    end

    # Lets running jobs finish, then waits for every thread to exit. If the
    # poller is exiting because of a signal exception (see
    # Worker.raise_signal_exceptions), it is raised in running jobs as well.
    def stop_threads(error)
      @inboxes.each_value { |inbox| inbox << STOP }
      if error.is_a?(SignalException)
        @threads.each { |thread| thread.raise(error.class, error.message) if thread.alive? }
      end
      @threads.each(&:join)
    end

    def dispatch(worker, job)
      synchronize do
        @idle.delete(worker)
        @in_flight += 1
      end
      @inboxes[worker] << job
    end

    def job_finished(worker, result)
      synchronize do
        result ? @success += 1 : @failure += 1
        @in_flight -= 1
        @idle << worker
        signal_event
      end
    end

    # Waits until a worker finishes a job (or dies), the poller is stopped, or
    # the timeout (if any) expires. `seen` is the event count observed before
    # deciding to wait, so no event can be missed.
    def wait_for_event(seen, timeout)
      synchronize do
        @cond.wait(@mutex, timeout) if @events == seen && !stop?
      end
    end

    def signal_event
      @events += 1
      @cond.broadcast
    end

    def wake_up
      synchronize { @cond.broadcast }
    rescue ThreadError
      # A Mutex cannot be locked from within a signal trap, so deliver the
      # wake-up from a separate thread instead.
      Thread.new { wake_up }
    end

    def snapshot
      synchronize { [@idle.dup, @events] }
    end

    def in_flight
      synchronize { @in_flight }
    end

    def completed
      synchronize { @success + @failure }
    end

    def report
      success, failure, elapsed = synchronize do
        stats = [@success, @failure, monotonic_now - @stats_started]
        reset_stats
        stats
      end
      count = success + failure
      return if count.zero?
      say format("#{count} jobs processed at %.4f j/s, %d failed", count / elapsed, failure)
    end

    def reset_stats
      @success = 0
      @failure = 0
      @stats_started = monotonic_now
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def raise_thread_error
      error = synchronize { @thread_error }
      raise error if error
    end

    def synchronize(&block)
      @mutex.synchronize(&block)
    end

    # Each job runs inside the Rails reloader, which reloads code in
    # development and manages database connections safely across threads.
    def with_reloader(&block)
      app = rails_application
      app && app.respond_to?(:reloader) ? app.reloader.wrap(&block) : yield
    end

    def with_executor(&block)
      app = rails_application
      app && app.respond_to?(:executor) ? app.executor.wrap(&block) : yield
    end

    def rails_application
      ::Rails.application if defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
    end

    def warn_if_connection_pool_too_small
      return unless defined?(::ActiveRecord::Base)
      pool_size = ::ActiveRecord::Base.connection_pool.size
      return if pool_size >= thread_count + 1
      say "WARNING: database connection pool size (#{pool_size}) is smaller than the number of " \
          "threads plus one (#{thread_count + 1}). Increase the pool size in config/database.yml.", 'warn'
    rescue StandardError
      nil
    end
  end
end
