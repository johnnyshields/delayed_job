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
  class Worker # rubocop:disable ClassLength
    include Logging

    DEFAULT_LOG_LEVEL        = 'info'.freeze
    DEFAULT_SLEEP_DELAY      = 5
    DEFAULT_MAX_ATTEMPTS     = 25
    DEFAULT_MAX_RUN_TIME     = 4.hours
    DEFAULT_DEFAULT_PRIORITY = 0
    DEFAULT_DELAY_JOBS       = true
    DEFAULT_QUEUES           = [].freeze
    DEFAULT_QUEUE_ATTRIBUTES = HashWithIndifferentAccess.new.freeze
    DEFAULT_READ_AHEAD       = 5
    DEFAULT_SHUTDOWN_TIMEOUT = nil
    DEFAULT_LOCK_HEARTBEAT_INTERVAL = nil
    DEFAULT_LOCK_TIMEOUT     = 5.minutes

    cattr_accessor :min_priority, :max_priority, :max_attempts, :max_run_time,
                   :default_priority, :sleep_delay, :logger, :delay_jobs, :queues,
                   :read_ahead, :plugins, :destroy_failed_jobs, :exit_on_complete,
                   :default_log_level

    # Seconds a stopping worker waits for running jobs to finish before
    # interrupting them (see Delayed::ShutdownInterrupt). nil, the default,
    # waits for as long as they take.
    cattr_accessor :shutdown_timeout

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
      @lifecycle             = nil
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
      @@backend = backend # rubocop:disable ClassVars
      silence_warnings { ::Delayed.const_set(:Job, backend) }
    end

    # rubocop:disable ClassVars
    def self.queue_attributes=(val)
      @@queue_attributes = val.with_indifferent_access
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
        begin
          file.reopen file.path, 'a+'
          file.sync = true
        rescue ::Exception # rubocop:disable HandleExceptions, RescueException
        end
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
    # prefix, pid and thread count (see Delayed::Dispatcher).
    def self.lock_names(prefix, pid, threads)
      return [lock_name(prefix, pid)] if threads <= 1
      Array.new(threads) { |index| lock_name(prefix, pid, index) }
    end

    # Recovers the jobs left locked by workers whose process died while
    # running them: each counts as a failed attempt, as if the job had raised
    # `error` - it is rescheduled with back-off, or fails permanently after
    # max_attempts, so a job that keeps killing its worker eventually stops.
    # Backends that can't list a worker's jobs (Job.locked_jobs returns nil)
    # only have the locks cleared. Returns the number of jobs recovered.
    def self.recover_jobs_of(worker_names, error)
      worker_names.inject(0) do |count, worker_name|
        jobs = Delayed::Job.locked_jobs(worker_name)
        if jobs.nil?
          Delayed::Job.clear_locks!(worker_name)
          next count
        end
        worker = named(worker_name)
        jobs.each { |job| worker.fail_attempt(job, error) }
        # Jobs failed permanently keep their lock (as when a live worker fails
        # them, until ClearLocks runs on exit); the dead worker can't clear it.
        Delayed::Job.clear_locks!(worker_name)
        Delayed.instrument(:locks_released, :workers => [worker_name], :count => jobs.size, :reason => 'process exit', :error => error) unless jobs.empty?
        count + jobs.size
      end
    end

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
    def self.validate_lock_heartbeats!
      return if lock_heartbeat_interval.nil?
      raise ArgumentError, 'lock_heartbeat_interval must be greater than 0' unless lock_heartbeat_interval > 0
      return if lock_timeout && lock_timeout >= 2 * lock_heartbeat_interval
      raise ArgumentError, "lock_timeout (#{lock_timeout.inspect}) must be at least twice " \
                           "lock_heartbeat_interval (#{lock_heartbeat_interval})"
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
      @quiet = options.key?(:quiet) ? options[:quiet] : true

      [:min_priority, :max_priority, :sleep_delay, :read_ahead, :queues, :exit_on_complete, :shutdown_timeout,
       :lock_heartbeat_interval, :lock_timeout].each do |option|
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

    def run(job)
      job_say job, 'RUNNING'
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Timeout.timeout(max_run_time(job).to_i, WorkerTimeout) { job.invoke_job }
      owned_destroy(job)
      runtime = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      job_say job, format('COMPLETED after %.4f', runtime)
      return true # did work
    rescue ShutdownInterrupt
      raise # the job didn't fail; Delayed::Dispatcher releases it
    rescue DeserializationError => error
      job_say job, "FAILED permanently with #{error.class.name}: #{error.message}", 'error'

      job.error = error
      failed(job)
      return false # work failed
    rescue Exception => error # rubocop:disable RescueException
      fail_attempt(job, error)
      return false # work failed
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
        begin
          job.hook(:failure)
        rescue => error
          say "Error when running failure callback: #{error}", 'error'
          say error.backtrace.join("\n"), 'error'
        ensure
          job.destroy_failed_jobs? ? owned_destroy(job) : owned_fail(job)
        end
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
    def perform_job(job)
      Delayed.instrument(:perform, :job => job, :worker => name) do |payload|
        payload[:success] = self.class.lifecycle.run_callbacks(:perform, self, job) { run(job) }
      end
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
