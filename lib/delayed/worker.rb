require 'timeout'
require 'active_support/dependencies'
require 'active_support/core_ext/numeric/time'
require 'active_support/core_ext/class/attribute_accessors'
require 'active_support/core_ext/kernel/reporting'
require 'active_support/hash_with_indifferent_access'
require 'active_support/core_ext/hash/indifferent_access'
require 'logger'

module Delayed
  # Runs jobs. In a worker process, Delayed::Dispatcher runs each Worker on its
  # own thread and hands it jobs. Worker#work_off runs jobs inline on the
  # calling thread instead (e.g. in tests or a console).
  class Worker # rubocop:disable Metrics/ClassLength
    include Logging

    DEFAULT_LOG_LEVEL        = 'info'.freeze
    DEFAULT_SLEEP_DELAY      = 1
    DEFAULT_MAX_ATTEMPTS     = 25
    DEFAULT_MAX_RUN_TIME     = 4.hours
    DEFAULT_DEFAULT_PRIORITY = 0
    DEFAULT_DELAY_JOBS       = true
    DEFAULT_QUEUES           = [].freeze
    DEFAULT_QUEUE_ATTRIBUTES = HashWithIndifferentAccess.new.freeze
    DEFAULT_READ_AHEAD       = 5
    DEFAULT_SHUTDOWN_TIMEOUT = nil
    DEFAULT_LOCK_HEARTBEAT_INTERVAL = nil
    DEFAULT_LOCK_TIMEOUT = 5.minutes
    DEFAULT_PREFETCH = 0
    MAX_PREFETCH = 20

    cattr_accessor :min_priority, :max_priority, :max_attempts, :max_run_time,
                   :default_priority, :sleep_delay, :logger, :delay_jobs, :queues,
                   :read_ahead, :plugins, :destroy_failed_jobs, :exit_on_complete,
                   :default_log_level

    # Jobs each worker thread may hold queued behind the one it runs, so
    # that it starts its next job without waiting for a poll (see
    # Delayed::Dispatcher). 0 (the default) reserves only for idle threads.
    # With prefetch_dynamic, the queue depth starts at 0, grows by one after
    # each poll that got every job it asked for (up to prefetch), and drops
    # back to 0 after one that got fewer.
    cattr_accessor :prefetch, :prefetch_dynamic

    # Called with errors raised outside of a job's own handling, which would
    # otherwise only be logged: failed reservations, failed lock heartbeats,
    # a worker thread or dispatcher crashing, failing failure hooks, failed
    # recovery of a dead worker process' jobs. E.g. to report them to an
    # error tracker:
    #
    #   Delayed::Worker.on_thread_error = ->(error, info) { Sentry.capture_exception(error, extra: info) }
    #
    # `info` holds :context (what failed) and, where known, :dispatcher,
    # :worker and :job. A handler taking one argument gets only the error,
    # and one taking none is just called.
    # Job errors are not reported here: see the :error lifecycle callback.
    # Errors raised by the handler are logged and ignored.
    cattr_accessor :on_thread_error

    # Silences the backend's query log while polling for jobs and refreshing
    # job locks (see Delayed::Job.silence_polling), so an idle worker
    # doesn't log a reservation query every sleep_delay seconds. Queries made
    # by jobs, and by workers finishing jobs, are logged as usual.
    cattr_accessor :silence_polling

    # Seconds a stopping worker waits for running jobs to finish before
    # interrupting them (see Delayed::ShutdownInterrupt). nil, the default,
    # waits for as long as they take.
    cattr_accessor :shutdown_timeout

    # Whether a job interrupted by shutdown (see Delayed::ShutdownInterrupt)
    # counts as a failed attempt: it is rescheduled with back-off, or fails
    # permanently after max_attempts. Off by default: an interrupted job is
    # released with its attempts unchanged, as a shutdown isn't the job's
    # fault - but then a job that always outlasts shutdown_timeout comes
    # back on every deploy.
    cattr_accessor :count_shutdown_interrupts

    # Lock heartbeats (off by default). While a job runs, its worker process
    # refreshes the job's lock every lock_heartbeat_interval seconds, and a
    # lock not refreshed for lock_timeout seconds counts as abandoned: its
    # job can be reserved by another worker. So the job of a worker that
    # died or hung is picked up after lock_timeout instead of max_run_time.
    # Needs a backend that supports it (Delayed::Job.lock_heartbeats?), and
    # every worker on the same jobs must enable it: a worker without
    # heartbeats would have its long-running jobs taken over.
    cattr_accessor :lock_heartbeat_interval, :lock_timeout

    # Named queue into which jobs are enqueued by default
    cattr_accessor :default_queue_name

    cattr_reader :backend, :queue_attributes

    # name_prefix is ignored if name is set directly
    attr_accessor :name_prefix

    # Index of the thread this worker runs on when a Delayed::Dispatcher runs
    # several workers. When set, it is appended to the default name so that
    # every thread locks jobs under a unique name.
    attr_accessor :thread_index

    # The Delayed::Dispatcher running this worker, if any.
    attr_accessor :dispatcher

    def self.reset
      self.default_log_level = DEFAULT_LOG_LEVEL
      self.sleep_delay       = DEFAULT_SLEEP_DELAY
      self.max_attempts      = DEFAULT_MAX_ATTEMPTS
      self.max_run_time      = DEFAULT_MAX_RUN_TIME
      self.default_priority  = DEFAULT_DEFAULT_PRIORITY
      self.delay_jobs        = DEFAULT_DELAY_JOBS
      self.queues            = DEFAULT_QUEUES
      self.queue_attributes  = DEFAULT_QUEUE_ATTRIBUTES
      self.read_ahead        = DEFAULT_READ_AHEAD
      self.shutdown_timeout  = DEFAULT_SHUTDOWN_TIMEOUT
      self.lock_heartbeat_interval = DEFAULT_LOCK_HEARTBEAT_INTERVAL
      self.lock_timeout      = DEFAULT_LOCK_TIMEOUT
      self.on_thread_error   = nil
      self.silence_polling   = false
      self.count_shutdown_interrupts = false
      self.prefetch          = DEFAULT_PREFETCH
      self.prefetch_dynamic  = false
      self.exit_on_complete  = nil
      self.min_priority      = nil
      self.max_priority      = nil
      self.default_queue_name = nil
      @lifecycle = nil
    end

    # Add or remove plugins in this list before the worker is instantiated
    self.plugins = [Delayed::Plugins::ClearLocks]

    # By default failed jobs are destroyed after too many attempts. If you want to keep them around
    # (perhaps to inspect the reason for the failure), set this to false.
    self.destroy_failed_jobs = true

    # By default, Signals INT and TERM stop the Delayed::Dispatcher, which exits upon completion of the current jobs.
    # If you would prefer to raise a SignalException and exit immediately you can use this.
    # Be aware daemons uses TERM to stop and restart
    # false - No exceptions will be raised
    # :term - Will only raise an exception on TERM signals but INT will wait for the current job to finish
    # true - Will raise an exception on TERM and INT
    cattr_accessor :raise_signal_exceptions
    self.raise_signal_exceptions = false

    def self.backend=(backend)
      if backend.is_a? Symbol
        require "delayed/serialization/#{backend}"
        require "delayed/backend/#{backend}"
        backend = "Delayed::Backend::#{backend.to_s.classify}::Job".constantize
      end
      @@backend = backend # rubocop:disable Style/ClassVars
      silence_warnings { ::Delayed.const_set(:Job, backend) }
    end

    def self.queue_attributes=(val)
      @@queue_attributes = val.with_indifferent_access # rubocop:disable Style/ClassVars
    end

    def self.guess_backend
      warn '[DEPRECATION] guess_backend is deprecated. Please remove it from your code.'
    end

    def self.before_fork
      unless @files_to_reopen
        @files_to_reopen = []
        ObjectSpace.each_object(File) do |file|
          # A pidfile's lock must be inherited, not dropped by reopening it.
          @files_to_reopen << file unless file.closed? || Delayed::Pidfile.lock_file?(file)
        end
      end

      backend.before_fork
    end

    def self.after_fork
      # Re-open file handles
      @files_to_reopen.each do |file|
        file.reopen file.path, 'a+'
        file.sync = true
      rescue ::Exception # rubocop:disable Lint/SuppressedException, Lint/RescueException
      end
      backend.after_fork
    end

    def self.lifecycle
      # In case a worker has not been set up, job enqueueing needs a lifecycle.
      setup_lifecycle unless @lifecycle

      @lifecycle
    end

    def self.setup_lifecycle
      @lifecycle = Delayed::Lifecycle.new
      plugins.each { |klass| klass.new }
    end

    # Default worker/dispatcher name: identifies the process.
    def self.default_name(prefix = nil, pid = Process.pid)
      "#{prefix}host:#{Socket.gethostname} pid:#{pid}"
    rescue StandardError
      "#{prefix}pid:#{pid}"
    end

    # The name a worker locks jobs under, by default.
    def self.lock_name(prefix = nil, pid = Process.pid, thread_index = nil)
      "#{default_name(prefix, pid)}#{" thread:#{thread_index}" if thread_index}"
    end

    # The lock names of every worker in a worker process with the given name
    # prefix, pid, thread count and prefetch (see Delayed::Dispatcher): with
    # prefetch, each thread's jobs are locked under its slot names.
    def self.lock_names(prefix, pid, threads, prefetch = 0)
      names = threads <= 1 ? [lock_name(prefix, pid)] : Array.new(threads) { |index| lock_name(prefix, pid, index) }
      return names unless prefetch.to_i > 0
      names.flat_map { |name| Array.new(prefetch.to_i + 1) { |slot| slot_name(name, slot) } }
    end

    # The name a worker locks the job in one of its slots under, with
    # prefetch: each job it holds (running or queued) has a slot of its own,
    # as reserving for a name also returns the jobs already locked under it.
    def self.slot_name(worker_name, slot)
      "#{worker_name} slot:#{slot}"
    end

    # Raises ArgumentError unless prefetch is a whole number from 0 to
    # MAX_PREFETCH.
    def self.validate_prefetch!(value = prefetch)
      return if value.is_a?(Integer) && value.between?(0, MAX_PREFETCH)
      raise ArgumentError, "prefetch must be a whole number from 0 to #{MAX_PREFETCH} (got #{value.inspect})"
    end

    # Recovers the jobs left locked by workers whose process died while
    # running them: each counts as a failed attempt, as if the job had raised
    # `error` - it is rescheduled with back-off, or fails permanently after
    # max_attempts, so a job that keeps killing its worker eventually stops.
    # Backends that can't list a worker's jobs (Job.locked_jobs returns nil)
    # only have the locks cleared. Returns the number of jobs recovered.
    def self.recover_jobs_of(worker_names, error)
      # In one query for all the names (see Job.locked_jobs_of): a process
      # with many threads and prefetch slots has hundreds.
      jobs = Delayed::Job.locked_jobs_of(worker_names)
      if jobs.nil?
        Delayed::Job.clear_locks_of!(worker_names)
        return 0
      end
      # A job that had already failed permanently keeps its lock (as when a
      # live worker fails it, until ClearLocks runs on exit): it wasn't
      # running, so it only has its lock cleared, below.
      by_worker = jobs.reject(&:failed?).group_by(&:locked_by) # Before recovery unlocks them.
      recovered = by_worker.sum do |worker_name, held|
        worker = named(worker_name)
        held.count { |job| recover_job(worker, job, error) }
      end
      Delayed::Job.clear_locks_of!(worker_names)
      publish_recovered(by_worker, error)
      recovered
    end

    def self.publish_recovered(by_worker, error)
      return if by_worker.empty?
      Delayed.instrument(:locks_released, :workers => by_worker.keys, :count => by_worker.values.sum(&:size),
                                          :reason => 'process exit', :error => error)
    end
    private_class_method :publish_recovered

    # Counts a failed attempt of a job recovered from a dead worker. An
    # error doing so (e.g. a failure hook that raises, or a lost database
    # connection) is reported, and leaves this job's lock to be cleared (see
    # #recover_jobs_of): the dead worker's other jobs are still recovered.
    # Returns whether it was recovered.
    def self.recover_job(worker, job, exit_error)
      worker.fail_attempt(job, exit_error)
      true
    rescue StandardError => error
      thread_error(error, :context => 'Recovering jobs', :worker => worker.name, :job => job)
      false
    end
    private_class_method :recover_job

    # Reports an error raised outside of a job's own handling: publishes a
    # thread_error event and calls Worker.on_thread_error. Never raises.
    def self.thread_error(error, info = {})
      Delayed.instrument(:thread_error, info.merge(:error => error))
      handler = on_thread_error
      return unless handler
      case handler_arity(handler)
      when 0 then handler.call
      when 1 then handler.call(error)
      else handler.call(error, info)
      end
    rescue StandardError => error
      logger.error("Error in Delayed::Worker.on_thread_error: #{error.class}: #{error.message}") if logger
    end

    # The arity of an on_thread_error handler: of the handler itself (a
    # Proc, Method), else of its #call method (any object responding to it).
    def self.handler_arity(handler)
      handler.respond_to?(:arity) ? handler.arity : handler.method(:call).arity
    end
    private_class_method :handler_arity

    # Whether lock heartbeats are enabled and supported by the backend.
    def self.lock_heartbeats?
      !lock_heartbeat_interval.nil? && Delayed::Job.lock_heartbeats?
    end

    # How long a job's lock is honoured: lock_timeout with lock heartbeats,
    # else max_run_time (after which the job must have been interrupted).
    def self.lock_expiry
      lock_heartbeats? ? lock_timeout : max_run_time
    end

    # Raises ArgumentError for lock heartbeat settings that would let a live
    # worker's locks expire between two heartbeats.
    def self.validate_lock_heartbeats!(interval = lock_heartbeat_interval, timeout = lock_timeout)
      return if interval.nil?
      raise ArgumentError, 'lock_heartbeat_interval must be greater than 0' unless interval > 0
      return if timeout && timeout >= 2 * interval
      raise ArgumentError, "lock_timeout (#{timeout.inspect}) must be at least twice " \
                           "lock_heartbeat_interval (#{interval})"
    end

    # Raises ArgumentError for settings a worker process would refuse to
    # start with: the Worker settings (e.g. from an initializer) overridden
    # by `options` (as Worker.new does). Lets the launcher fail at once,
    # rather than every worker process it forks.
    def self.validate_settings!(options = {})
      setting = ->(name) { options.key?(name) ? options[name] : send(name) }
      validate_prefetch!(setting.call(:prefetch))
      validate_lock_heartbeats!(setting.call(:lock_heartbeat_interval), setting.call(:lock_timeout))
    end

    # A worker that only records job outcomes under the given name. Unlike
    # Worker.new, it doesn't reset the lifecycle or process-wide settings.
    def self.named(name)
      allocate.tap do |worker|
        worker.instance_variable_set(:@quiet, true)
        worker.name = name
      end
    end

    def self.delay_job?(job)
      if delay_jobs.is_a?(Proc)
        delay_jobs.arity == 1 ? delay_jobs.call(job) : delay_jobs.call
      else
        delay_jobs
      end
    end

    def initialize(options = {})
      if Thread.current[:delayed_job_running]
        raise 'Delayed::Worker.new was called from a running job: it would reset the settings and ' \
              'plugin callbacks of every worker in this process. To run jobs inline, use Delayed::Job#invoke_job.'
      end
      @quiet = options.key?(:quiet) ? options[:quiet] : true

      [:min_priority, :max_priority, :sleep_delay, :read_ahead, :queues, :exit_on_complete, :shutdown_timeout,
       :lock_heartbeat_interval, :lock_timeout, :silence_polling, :count_shutdown_interrupts,
       :prefetch, :prefetch_dynamic].each do |option|
        self.class.send("#{option}=", options[option]) if options.key?(option)
      end

      # Reset lifecycle on the offhand chance that something lazily
      # triggered its creation before all plugins had been registered.
      self.class.setup_lifecycle
    end

    # Every worker has a unique name which by default is the pid of the process. There are some
    # advantages to overriding this with something which survives worker restarts:  Workers can
    # safely resume working on tasks which are locked by themselves. The worker will assume that
    # it crashed before.
    def name
      return @name unless @name.nil?
      self.class.lock_name(@name_prefix, Process.pid, thread_index)
    end

    # Sets the name of the worker.
    # Setting the name to nil will reset the default worker name
    attr_writer :name

    # Runs this worker in the foreground until stopped, via a Delayed::Dispatcher,
    # as every worker process does.
    def start
      Dispatcher.new(:workers => [self], :quiet => @quiet).tap { |dispatcher| dispatcher.name_prefix = name_prefix }.start
    end

    # Stops this worker, and the dispatcher running it (if any).
    def stop
      @exit = true
      dispatcher.stop if dispatcher
    end

    def stop?
      !!@exit
    end

    # Do num jobs inline on the calling thread and return stats on
    # success/failure. Exit early if interrupted or no job is available.
    # Reservation goes through this worker's Delayed::Dispatcher, as in a
    # worker process.
    def work_off(num = 100)
      (dispatcher || Dispatcher.new(:workers => [self], :quiet => @quiet)).work_off(num, self)
    end

    # `time_cap`: at most this many seconds, if given (by the dispatcher,
    # for a job whose lock expires sooner than its max_run_time, see
    # Dispatcher#lock_time_left).
    def run(job, time_cap = nil)
      job_say job, 'RUNNING'
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      limit = max_run_time(job).to_i
      limit = limit > 0 ? [limit, time_cap].min : time_cap if time_cap
      dispatcher.job_timed(self, job, limit) if dispatcher
      # Only the job's own code (its #perform) can be interrupted by
      # shutdown (see Dispatcher#work and Backend::Base#invoke_job): never
      # its hooks or finishing it, below, so a job that ran is never
      # released to run again.
      Timeout.timeout(limit, WorkerTimeout) { job.invoke_job }
      owned_destroy(job)
      runtime = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      job_say job, format('COMPLETED after %.4f', runtime)
      true # did work
    rescue ShutdownInterrupt
      raise # the job didn't fail; Delayed::Dispatcher releases it
    rescue SignalException => error
      # Raised into the job by a stopping dispatcher (see
      # Worker.raise_signal_exceptions): the job didn't fail either. Run
      # inline (e.g. #work_off), it counts as a failed attempt, as before.
      raise if Dispatcher.worker_thread?
      fail_attempt(job, error)
      false # work failed
    rescue DeserializationError => error
      job_say job, "FAILED permanently with #{error.class.name}: #{error.message}", 'error'

      job.error = error
      failed(job)
      false # work failed
    rescue Exception => error # rubocop:disable Lint/RescueException
      fail_attempt(job, error)
      false # work failed
    end

    # Records a failed attempt of the job: runs the :error callbacks, then
    # reschedules the job, or fails it permanently after max_attempts.
    def fail_attempt(job, error)
      self.class.lifecycle.run_callbacks(:error, self, job) { handle_failed_job(job, error) }
    end

    # Reschedule the job in the future (when a job fails).
    # Uses an exponential scale depending on the number of failed attempts.
    def reschedule(job, time = nil)
      if (job.attempts += 1) < max_attempts(job)
        time ||= job.reschedule_at
        job.run_at = time
        owner = job.locked_by
        job.unlock
        owned_save(job, owner)
      else
        job_say job, "FAILED permanently because of #{job.attempts} consecutive failures", 'error'
        failed(job)
      end
    end

    def failed(job)
      Delayed.instrument(:job_failed, :job => job, :worker => name, :error => job.error)
      self.class.lifecycle.run_callbacks(:failure, self, job) do
        job.hook(:failure)
      rescue StandardError => error
        say "Error when running failure callback: #{error}", 'error'
        say error.backtrace.join("\n"), 'error'
        self.class.thread_error(error, :context => 'Failure hook', :worker => name, :job => job)
      ensure
        job.destroy_failed_jobs? ? owned_destroy(job) : owned_fail(job)
      end
    end

    def job_say(job, text, level = default_log_level)
      text = "Job #{job.name} (id=#{job.id})#{say_queue(job.queue)} #{text}"
      say text, level
    end

    def max_attempts(job)
      job.max_attempts || self.class.max_attempts
    end

    def max_run_time(job)
      job.max_run_time || self.class.max_run_time
    end

    # Runs an already reserved job, including its :perform callbacks.
    # Returns true if the job succeeded, false if it failed.
    def perform_job(job, time_cap = nil)
      running = Thread.current[:delayed_job_running]
      Thread.current[:delayed_job_running] = true # See #initialize.
      Delayed.instrument(:perform, :job => job, :worker => name) do |payload|
        payload[:success] = self.class.lifecycle.run_callbacks(:perform, self, job) { run(job, time_cap) }
      end
    ensure
      Thread.current[:delayed_job_running] = running
    end

  protected

    # Owner-guarded writes. A job is finished, rescheduled or failed only if
    # this worker still holds its lock: if the lock expired and another
    # worker reserved the job meanwhile (see Worker.lock_timeout), the other
    # worker's run decides the job's fate, and this outcome is discarded.
    # Applies to backends that implement destroy_if_locked_by and
    # save_if_locked_by, and to locked jobs; others are written as before.
    def owned_destroy(job)
      owner = job.locked_by
      return job.destroy unless owner && job.respond_to?(:destroy_if_locked_by)
      lost_lock(job, 'finished') unless job.destroy_if_locked_by(owner)
    end

    def owned_save(job, owner)
      return job.save! unless owner && job.respond_to?(:save_if_locked_by)
      lost_lock(job, 'rescheduled') unless job.save_if_locked_by(owner)
    end

    def owned_fail(job)
      owner = job.locked_by
      return job.fail! unless owner && job.respond_to?(:save_if_locked_by)
      job.failed_at = job.class.db_time_now
      lost_lock(job, 'failed') unless job.save_if_locked_by(owner)
    end

    def lost_lock(job, outcome)
      Delayed.instrument(:lock_lost, :job => job, :worker => name, :outcome => outcome)
      job_say job, "was #{outcome} here, but its lock expired and another worker reserved it; " \
                   'leaving the job to that worker', 'warn'
    end

    def say_queue(queue)
      " (queue=#{queue})" if queue
    end

    def handle_failed_job(job, error)
      job.error = error
      Delayed.instrument(:attempt_failed, :job => job, :worker => name, :error => error, :attempts => job.attempts + 1)
      job_say job, "FAILED (#{job.attempts} prior attempts) with #{error.class.name}: #{error.message}", 'error'
      reschedule(job)
    end
  end
end

Delayed::Worker.reset
