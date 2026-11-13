module Delayed
  module Backend
    module Base
      def self.included(base)
        base.extend ClassMethods
      end

      module ClassMethods
        # Add a job to the queue
        def enqueue(*args)
          job_options = Delayed::Backend::JobPreparer.new(*args).prepare
          enqueue_job(job_options)
        end

        def enqueue_job(options)
          new(options).tap do |job|
            Delayed::Worker.lifecycle.run_callbacks(:enqueue, job) do
              job.hook(:enqueue)
              Delayed::Worker.delay_job?(job) ? job.save : job.invoke_job
            end
          end
        end

        def reserve(worker, max_run_time = Worker.max_run_time)
          # We get up to 5 jobs from the db. In case we cannot get exclusive access to a job we try the next.
          # this leads to a more even distribution of jobs across the worker processes
          find_available(worker.name, worker.read_ahead, max_run_time).detect do |job|
            job.lock_exclusively!(max_run_time, worker.name)
          end
        end

        # Reserve up to one job for each of the given workers, used by
        # Delayed::Dispatcher to fill its idle threads. Returns an array
        # of [worker, job] pairs, in the order of the given workers.
        #
        # Each job must be locked under the name of the worker it is paired
        # with. The default implementation calls #reserve once per worker
        # (so backend-specific reserve optimizations are kept) and stops at
        # the first worker for which no job is available. Backends may
        # override this with a single-query batch reservation.
        def reserve_batch(workers, max_run_time = Worker.max_run_time)
          reserved = []
          workers.each do |worker|
            job = reserve(worker, max_run_time)
            break unless job
            reserved << [worker, job]
          end
          reserved
        rescue StandardError
          # Don't strand jobs that were already locked; if the error persists
          # it will be raised again by the next reservation.
          raise if reserved.empty?
          reserved
        end

        # Whether reserve_batch may reserve fewer jobs than it was asked for
        # while jobs are still available - e.g. because candidates it picked
        # were reserved by other processes meanwhile. If so, Delayed::Dispatcher
        # polls again at once after such a partial batch; otherwise a
        # partial batch means the queue ran dry, and it waits sleep_delay.
        # The default reserve_batch stops only when reserve finds no job.
        def partial_batch_may_leave_jobs?
          false
        end

        # Returns the jobs locked by the named worker, or nil if the backend
        # can't list them. Backends implement this so that Delayed Job can
        # recover the jobs of a worker process that died (see
        # Delayed::Worker.recover_jobs_of); without it, those jobs' locks are
        # only cleared.
        def locked_jobs(_worker_name)
          nil
        end

        # Whether the backend supports lock heartbeats (see
        # Delayed::Worker.lock_heartbeat_interval): it implements
        # touch_locks, and honours the max_run_time passed to reserve as the
        # age after which a lock counts as abandoned.
        def lock_heartbeats?
          false
        end

        # Refreshes (sets locked_at to now) the locks held by the named
        # workers. Returns the number of jobs touched.
        def touch_locks(_worker_names)
          raise NotImplementedError, "#{name} does not support lock heartbeats"
        end

        # Runs the block with the backend's query logging silenced on the
        # calling thread only (see Delayed::Worker.silence_polling).
        # The default silences ActiveRecord::Base.logger below WARN, if it
        # supports ActiveSupport's thread-local #silence. Backends logging
        # through another logger (e.g. the Mongo driver's) override this.
        def silence_polling(&block)
          logger = defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.logger
          return yield unless logger.respond_to?(:silence)
          logger.silence(::Logger::WARN, &block)
        end

        # Allow the backend to attempt recovery from reserve errors
        def recover_from(_error); end

        # Hook method that is called before a new worker is forked
        def before_fork; end

        # Hook method that is called after a new worker is forked
        def after_fork; end

        def work_off(num = 100)
          warn '[DEPRECATION] `Delayed::Job.work_off` is deprecated. Use `Delayed::Worker.new.work_off instead.'
          Delayed::Worker.new.work_off(num)
        end
      end

      attr_reader :error

      def error=(error)
        @error = error
        self.last_error = "#{error.message}\n#{error.backtrace.join("\n")}" if respond_to?(:last_error=)
      end

      def failed?
        !!failed_at
      end
      alias_method :failed, :failed?

      ParseObjectFromYaml = %r{!ruby/\w+:([^\s]+)} # rubocop:disable Naming/ConstantName

      def name
        @name ||= payload_object.respond_to?(:display_name) ? payload_object.display_name : payload_object.class.name
      rescue DeserializationError
        ParseObjectFromYaml.match(handler)[1]
      end

      def payload_object=(object)
        @payload_object = object
        self.handler = object.to_yaml
      end

      def payload_object
        @payload_object ||= YAML.load_dj(handler)
      rescue TypeError, LoadError, NameError, ArgumentError, SyntaxError, Psych::SyntaxError => error
        raise DeserializationError, "Job failed to load: #{error.message}. Handler: #{handler.inspect}"
      end

      def invoke_job
        Delayed::Worker.lifecycle.run_callbacks(:invoke_job, self) do
          hook :before
          payload_object.perform
          hook :success
        rescue Exception => error # rubocop:disable Lint/RescueException
          hook :error, error
          raise error
        ensure
          hook :after
        end
      end

      # Unlock this job (note: not saved to DB)
      def unlock
        self.locked_at    = nil
        self.locked_by    = nil
      end

      def hook(name, *args)
        if payload_object.respond_to?(name)
          method = payload_object.method(name)
          method.arity.zero? ? method.call : method.call(self, *args)
        end
      rescue DeserializationError # rubocop:disable Lint/SuppressedException
      end

      def reschedule_at
        if payload_object.respond_to?(:reschedule_at)
          payload_object.reschedule_at(self.class.db_time_now, attempts)
        else
          self.class.db_time_now + (attempts**4) + 5
        end
      end

      def max_attempts
        payload_object.max_attempts if payload_object.respond_to?(:max_attempts)
      end

      def max_run_time
        return unless payload_object.respond_to?(:max_run_time)
        return unless (run_time = payload_object.max_run_time)

        if run_time > Delayed::Worker.max_run_time
          Delayed::Worker.max_run_time
        else
          run_time
        end
      end

      def destroy_failed_jobs?
        payload_object.respond_to?(:destroy_failed_jobs?) ? payload_object.destroy_failed_jobs? : Delayed::Worker.destroy_failed_jobs
      rescue DeserializationError
        Delayed::Worker.destroy_failed_jobs
      end

      def fail!
        self.failed_at = self.class.db_time_now
        save!
      end

    protected

      def set_default_run_at
        self.run_at ||= self.class.db_time_now
      end

      # Call during reload operation to clear out internal state
      def reset
        @payload_object = nil
      end
    end
  end
end
