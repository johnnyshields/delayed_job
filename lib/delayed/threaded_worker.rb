module Delayed
  # Runs several jobs concurrently within a single process.
  #
  # A ThreadedWorker is a dispatcher: it owns `thread_count` child workers,
  # each running on its own thread. The dispatcher reserves only as many jobs
  # as there are idle threads (via Delayed::Job.reserve_batch) and hands each
  # job to an idle thread, so a process polls the database once per cycle
  # regardless of its thread count, and a job is never locked while it waits
  # for a free thread.
  #
  # Each child locks jobs under its own name ("... thread:N"), runs the :perform
  # callbacks for its jobs and the :execute callbacks for its lifetime (so the
  # ClearLocks plugin releases each thread's locks on exit). The dispatcher runs
  # the :loop callbacks.
  #
  # Queue and priority settings are process-wide (they are class-level settings
  # of Delayed::Worker), so all threads of a process work the same queues.
  class ThreadedWorker < Worker # rubocop:disable ClassLength
    STOP = Object.new.freeze

    attr_reader :thread_count, :children

    # The lifecycle is held in a class-level instance variable of
    # Delayed::Worker, where plugins register their callbacks; share it.
    def self.lifecycle
      Worker.lifecycle
    end

    def self.setup_lifecycle
      Worker.setup_lifecycle
    end

    def initialize(options = {})
      super
      @thread_count = Integer(options.fetch(:thread_count, 1))
      raise ArgumentError, 'thread_count must be 1 or greater' if @thread_count < 1

      @idle = []
      @inboxes = {}
      @in_flight = 0
      @success = 0
      @failure = 0
      @events = 0
      @thread_error = nil
      @threads = []

      # Build the children up front, on the calling thread: Worker.new resets
      # the global lifecycle, which must not happen once threads are running.
      @children = Array.new(@thread_count) do |index|
        Worker.new(:quiet => @quiet).tap { |child| child.thread_index = index }
      end
    end

    def name_prefix=(prefix)
      super
      children.each { |child| child.name_prefix = prefix }
    end

    def work_loop
      say "Starting job worker with #{thread_count} threads"
      warn_if_connection_pool_too_small
      start_threads
      error = nil
      begin
        run_loop
      rescue Exception => error # rubocop:disable RescueException
        raise
      ensure
        stop_threads(error)
      end
    end

    # Dispatches reserved jobs to idle threads until `num` jobs have completed,
    # the worker is stopped, or no job can be reserved while no job is running.
    # Returns the number of [succeeded, failed] jobs completed in the meantime.
    def work_off(num = 100)
      until stop?
        raise_thread_error
        idle, seen, completed = snapshot
        break if completed >= num

        reserved = idle.empty? ? [] : reserve_jobs(idle)
        reserved.each { |child, job| dispatch(child, job) }
        break if reserved.empty? && in_flight.zero?

        # Wait for a thread to free up. If the queue looked empty, poll again
        # after sleep_delay so that idle threads pick up newly enqueued jobs.
        wait_for_event(seen, reserved.size < idle.size ? self.class.sleep_delay : nil)
      end
      raise_thread_error
      take_results
    end

  protected

    def start_threads
      @idle = children.dup
      @threads = children.map do |child|
        inbox = @inboxes[child] = Queue.new
        Thread.new { child_loop(child, inbox) }.tap do |thread|
          thread.report_on_exception = false if thread.respond_to?(:report_on_exception=)
          thread.name = "delayed_job thread:#{child.thread_index}" if thread.respond_to?(:name=)
        end
      end
    end

    # Lets running jobs finish (as a single-threaded worker would), then waits
    # for every thread to exit. If the dispatcher is exiting because of a
    # signal exception (see Worker.raise_signal_exceptions), the exception is
    # raised in running jobs as well.
    def stop_threads(error)
      @inboxes.each_value { |inbox| inbox << STOP }
      if error.is_a?(SignalException)
        @threads.each { |thread| thread.raise(error.class, error.message) if thread.alive? }
      end
      @threads.each(&:join)
    end

    def child_loop(child, inbox)
      self.class.lifecycle.run_callbacks(:execute, child) do
        loop do
          job = inbox.pop
          break if job.equal?(STOP)
          result = with_reloader { child.perform_job(job) }
          job_finished(child, result)
        end
      end
    rescue Exception => error # rubocop:disable RescueException
      synchronize do
        @thread_error ||= error
        @events += 1
        @wake_cond.broadcast
      end
    end

    def dispatch(child, job)
      synchronize do
        @idle.delete(child)
        @in_flight += 1
      end
      @inboxes[child] << job
    end

    def job_finished(child, result)
      synchronize do
        result ? @success += 1 : @failure += 1
        @in_flight -= 1
        @idle << child
        @events += 1
        @wake_cond.broadcast
      end
    end

    def reserve_jobs(idle)
      reserved = with_executor { Delayed::Job.reserve_batch(idle) }
      @failed_reserve_count = 0
      reserved
    rescue ::Exception => error # rubocop:disable RescueException
      say "Error while reserving job: #{error}"
      Delayed::Job.recover_from(error)
      @failed_reserve_count += 1
      raise FatalBackendError if @failed_reserve_count >= 10
      []
    end

    # Waits until a thread finishes a job (or fails), the worker is stopped,
    # or the timeout (if any) expires. `seen` is the event count observed when
    # the decision to wait was made, so no event can be missed.
    def wait_for_event(seen, timeout)
      synchronize do
        @wake_cond.wait(@wake_mutex, timeout) if @events == seen && !stop?
      end
    end

    def snapshot
      synchronize { [@idle.dup, @events, @success + @failure] }
    end

    def in_flight
      synchronize { @in_flight }
    end

    def take_results
      synchronize do
        results = [@success, @failure]
        @success = @failure = 0
        results
      end
    end

    def raise_thread_error
      error = synchronize { @thread_error }
      raise error if error
    end

    def synchronize(&block)
      @wake_mutex.synchronize(&block)
    end

    # Each job runs inside the Rails reloader so that code reloading and
    # database connections are managed safely across threads.
    def with_reloader(&block)
      app = rails_application
      app ? app.reloader.wrap(&block) : yield
    end

    def with_executor(&block)
      app = rails_application
      app ? app.executor.wrap(&block) : yield
    end

    # Reloading is handled per job by the Rails reloader.
    def reload!; end

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
