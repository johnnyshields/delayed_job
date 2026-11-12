module Delayed
  # Runs a worker process: owns one or more Delayed::Workers, each on its own
  # thread, and feeds them jobs. Every worker process (forked, daemonized,
  # rake, or Worker#start) runs exactly one Dispatcher, whatever its thread count.
  #
  # Each poll reserves only as many jobs as there are idle workers (via
  # Delayed::Job.reserve_batch) and hands one job to each, so the database is
  # polled once per cycle regardless of the thread count, and a job is never
  # locked while it waits for a free thread.
  #
  # Lifecycle callbacks:
  # * :loop wraps each poll and yields the Dispatcher.
  # * :execute wraps each worker thread's lifetime and yields the Worker
  #   (so the ClearLocks plugin releases every worker's locks on exit).
  # * :perform, :error and :failure yield the Worker running the job.
  #
  # Queue and priority settings are process-wide (class-level settings of
  # Delayed::Worker), so all threads of a process work the same queues.
  class Dispatcher # rubocop:disable ClassLength
    include Logging

    STOP = Object.new.freeze

    # Give up (raising FatalBackendError) after this many consecutive
    # failures to reserve jobs.
    MAX_FAILED_RESERVATIONS = 10

    # Log throughput at least this often while the queue stays busy.
    REPORT_EVERY = 100

    # Seconds to wait for interrupted jobs to stop before giving up on them.
    INTERRUPT_GRACE = 5

    # How often (in seconds) a supervised worker checks that its parent
    # process is still alive, even while all its threads are busy.
    SUPERVISOR_CHECK_INTERVAL = 1

    attr_reader :workers, :name_prefix

    # Pid of the parent process supervising this one (the forking launcher),
    # or nil. A supervised dispatcher stops when its parent goes away, e.g.
    # when the launcher is SIGKILLed, instead of running on as an orphan.
    attr_accessor :supervisor_pid

    # Options are those of Delayed::Worker, plus:
    # * :threads - number of workers (threads) to run (default 1)
    # * :workers - run these workers instead of building new ones
    # * :supervisor_pid - see #supervisor_pid
    def initialize(options = {})
      @quiet = options.key?(:quiet) ? options[:quiet] : true
      @workers = options[:workers] || build_workers(options)
      raise ArgumentError, 'threads must be 1 or greater' if @workers.empty?
      @workers.each { |worker| worker.dispatcher = self }
      @supervisor_pid = options[:supervisor_pid]
      @stopped = false
      @quit = false
      @stop_requested_at = nil

      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @idle = []
      @inboxes = {}
      @threads = []
      @running = {} # thread => job it is running
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

    # Installs signal traps and runs until stopped. `pending_signals` are
    # signals the process received before it could install them (see
    # Launcher::Forking#fork_worker); they are handled first.
    def start(pending_signals = [])
      trap_signals
      pending_signals.each { |signal| handle_pending_signal(signal) }
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

    # Stops polling. Running jobs are allowed to finish, for at most
    # Worker.shutdown_timeout seconds if set; then they are interrupted and
    # released (see #quit). Safe to call from a signal trap.
    def stop
      @stop_requested_at ||= monotonic_now
      @stopped = true
      wake_up
    end

    def stop?
      @stopped
    end

    # Stops at once: interrupts running jobs with Delayed::ShutdownInterrupt
    # and releases them, unlocked and with their attempts unchanged, for
    # another worker to run. Safe to call from a signal trap.
    def quit
      @quit = true
      stop
    end

    def quit?
      @quit
    end

  private

    def build_workers(options)
      count = Integer(options.fetch(:threads, 1))
      Array.new([count, 0].max) do |index|
        # Worker.new resets the global lifecycle, so all workers are built
        # here, before any thread starts.
        Worker.new(options).tap { |worker| worker.thread_index = index if count > 1 }
      end
    end

    # Signals INT and TERM stop the dispatcher once running jobs finish (or
    # Worker.shutdown_timeout passes), or raise a SignalException, see
    # Worker.raise_signal_exceptions. QUIT stops it at once, see #quit.
    def trap_signals
      trap('TERM') do
        first = !stop?
        Thread.new { say 'Exiting...' } if first
        stop
        raise SignalException, 'TERM' if first && Worker.raise_signal_exceptions
      end

      trap('INT') do
        first = !stop?
        Thread.new { say 'Exiting...' } if first
        stop
        raise SignalException, 'INT' if first && Worker.raise_signal_exceptions && Worker.raise_signal_exceptions != :term
      end

      return unless Signal.list.key?('QUIT')
      trap('QUIT') do
        Thread.new { say 'Received SIGQUIT: interrupting running jobs and exiting...' }
        quit
      end
    end

    # Acts on a signal received before the traps were installed, as its trap
    # would, except that no SignalException is raised: nothing is running yet.
    def handle_pending_signal(signal)
      say "Received SIG#{signal} while starting", 'warn'
      signal == 'QUIT' ? quit : stop
    end

    def poll_loop # rubocop:disable CyclomaticComplexity, PerceivedComplexity
      until stop?
        raise_thread_error
        break if supervisor_gone?
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
        wait_for_event(seen, poll_wait(reserved.size < idle.size))
      end
      raise_thread_error
    end

    # How long to wait before the next poll: until a worker frees up, or
    # sleep_delay when the queue ran dry - and no longer than
    # SUPERVISOR_CHECK_INTERVAL when supervised.
    def poll_wait(queue_dry)
      timeout = queue_dry ? Worker.sleep_delay : nil
      return timeout unless supervisor_pid
      [timeout, SUPERVISOR_CHECK_INTERVAL].compact.min
    end

    # Whether the parent process went away (this process was re-parented).
    # Stops the dispatcher gracefully if so: running jobs finish (or are
    # interrupted after Worker.shutdown_timeout), then the process exits.
    def supervisor_gone?
      return false unless supervisor_pid && Process.ppid != supervisor_pid
      say "Parent process #{supervisor_pid} is gone; stopping", 'warn'
      stop
      true
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
        begin
          until (job = inbox.pop).equal?(STOP)
            synchronize { @running[Thread.current] = job }
            result = with_reloader { worker.perform_job(job) }
            synchronize { @running.delete(Thread.current) }
            job_finished(worker, result)
          end
        rescue ShutdownInterrupt
          release_interrupted(worker, synchronize { @running.delete(Thread.current) })
        end
      end
    rescue Exception => error # rubocop:disable RescueException
      synchronize do
        @running.delete(Thread.current)
        @thread_error ||= error
        signal_event
      end
    end

    # Lets running jobs finish, then waits for every thread to exit. Jobs
    # still running at the shutdown deadline (see #shutdown_deadline) are
    # interrupted and released. If the dispatcher is exiting because of a
    # signal exception (see Worker.raise_signal_exceptions), it is raised in
    # running jobs as well.
    def stop_threads(error)
      @stop_requested_at ||= monotonic_now
      @inboxes.each_value { |inbox| inbox << STOP }
      if error.is_a?(SignalException)
        @threads.each { |thread| thread.raise(error.class, error.message) if thread.alive? }
      end
      wait_for_threads
      interrupt_threads(synchronize { @running.keys.select(&:alive?) }) if shutdown_deadline
    end

    # Waits until every thread exits or the shutdown deadline passes. The
    # deadline is checked again on each wait, so #quit takes effect at once.
    def wait_for_threads
      loop do
        busy = @threads.find(&:alive?)
        break unless busy
        deadline = shutdown_deadline
        remaining = deadline && deadline - monotonic_now
        break if remaining && remaining <= 0
        busy.join(remaining ? [remaining, 0.1].min : 0.1)
      end
    end

    def interrupt_threads(busy)
      return if busy.empty?
      reason = quit? ? 'Quitting' : format('Shutdown timeout of %gs exceeded', Worker.shutdown_timeout)
      say "#{reason}: interrupting #{busy.size} running job(s)", 'warn'
      busy.each { |thread| thread.raise(ShutdownInterrupt, reason) }
      deadline = monotonic_now + INTERRUPT_GRACE
      busy.each { |thread| thread.join([deadline - monotonic_now, 0].max) }
      stuck = busy.count(&:alive?)
      return if stuck.zero?
      say format('%d job(s) did not stop within %gs of being interrupted; ', stuck, INTERRUPT_GRACE) +
          'leaving them locked until max_run_time expires', 'error'
    end

    # When running jobs are interrupted: at once after #quit, else
    # Worker.shutdown_timeout seconds after #stop, else never (nil).
    def shutdown_deadline
      return monotonic_now if quit?
      timeout = Worker.shutdown_timeout
      @stop_requested_at + timeout if timeout
    end

    # Releases a job interrupted by shutdown for another worker to run: its
    # lock is cleared, its attempts and run_at are left as they were.
    def release_interrupted(worker, job)
      worker.job_say(job, 'interrupted by shutdown; released for another worker', 'warn') if job
      Delayed::Job.clear_locks!(worker.name)
    rescue StandardError => error
      say "Could not release the jobs of #{worker.name}: #{error.class}: #{error.message}", 'error'
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

    # Waits until a worker finishes a job (or dies), the dispatcher is stopped, or
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
