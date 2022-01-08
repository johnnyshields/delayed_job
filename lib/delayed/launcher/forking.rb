module Delayed
  module Launcher

    # Parent launcher class which spawns DelayedJob worker processes
    # in the foreground.
    class Forking
      KILL_TIMEOUT = 30

      attr_accessor :worker_count,
                    :pools,
                    :process_prefix,
                    :process_identifier

      def initialize(options)
        @worker_index = 0
        @worker_count = options.delete(:worker_count) || 1
        @pools = options.delete(:pools)
        @pools = nil if @pools == []
        @monitor = options.delete(:monitor)
        @process_prefix = options.delete(:prefix)
        @process_identifier = options.delete(:identifier)
        @args = options.delete(:args)

        @options = options
        @options[:pid_dir] ||= "#{Delayed.root}/tmp/pids"
        @options[:log_dir] ||= "#{Delayed.root}/log"
      end

      def launch
        @stopped = !!@options[:exit_on_complete]
        @killed = false
        setup_logger
        trap_signals
        Delayed::Worker.before_fork if worker_count > 1
        setup_workers
        run_loop if worker_count > 1
        before_graceful_exit
      end

      def shutdown(timeout = nil)
        @stopped = true
        message = " with #{timeout} second grace period" if timeout
        logger.info "Shutdown invoked#{message}"
        signal_workers('TERM')
        schedule_kill(timeout) if timeout
      end

      def kill(exit_status = 0, message = nil)
        @stopped = true
        @killed = true
        message = " #{message}" if message
        logger.warn "Kill invoked#{message}"
        signal_workers('KILL')
        logger.warn "#{parent_name} exited forcefully#{message} - pid #{$$}"
        exit(exit_status)
      end

    private

      def trap_signals
        trap_shutdown_signal('INT')
        trap_shutdown_signal('TERM')
      end

      # Trapped signals are forwarded worker processes.
      # Hence it is not necessary to explicitly shutdown workers;
      # we only need to stop the run loop.
      def trap_shutdown_signal(signal)
        Signal.trap(signal) do
          Thread.new { logger.info("Received SIG#{signal}. Waiting for workers to finish current job...") }
          @stopped = true
        end
      end

      def workers
        @workers ||= {}
      end

      def setup_workers
        if pools
          setup_pooled_workers
        elsif process_identifier
          setup_identified_worker
        elsif worker_count > 1
          setup_multiple_workers
        else
          setup_single_worker
        end
      end

      def setup_pooled_workers
        pools.each do |queues, pool_worker_count|
          options = @options.merge(:queues => queues)
          pool_worker_count.times { add_worker(options) }
        end
      end

      def setup_multiple_workers
        worker_count.times { add_worker(@options) }
      end

      def setup_single_worker
        set_process_name(get_name(process_identifier))
        Delayed::Worker.new(@options).start
      end
      alias_method :setup_identified_worker, :setup_single_worker

      def add_worker(options)
        worker_name = get_name(@worker_index)
        worker_pid = fork_worker(worker_name, options)

        queues = options[:queues]
        queue_msg = " queues=#{queues.empty? ? '*' : queues.join(',')}" if queues
        logger.info "Worker #{worker_name} started - pid #{worker_pid}#{queue_msg}"

        workers[worker_pid] = [worker_name, queues]
        @worker_index += 1
      end

      def fork_worker(worker_name, options)
        fork { run_worker(worker_name, options) }
      end

      def run_worker(worker_name, options)
        Dir.chdir(Delayed.root)
        set_process_name(worker_name)
        Delayed::Worker.after_fork
        setup_logger
        worker = Delayed::Worker.new(options)
        worker.name_prefix = "#{worker_name} "
        worker.start
      rescue => e
        STDERR.puts e.message
        STDERR.puts e.backtrace
        logger.fatal(e)
        exit_with_error_status
      end

      def run_loop # rubocop:disable CyclomaticComplexity, PerceivedComplexity
        loop do
          worker_pid = Process.wait
          next unless workers.key?(worker_pid)
          worker_name, queues = workers.delete(worker_pid)
          child_status = $?
          logger.info "Worker #{worker_name} exited - #{child_status}"

          # If any child was SIGKILL'ed, we must shutdown all children.
          # This first will attempt a graceful SIGTERM of the children,
          # followed by a SIGKILL after a timeout period.
          if child_status.termsig == 9 && !@killed
            @killed = true
            logger.warn "Worker #{worker_name} SIGKILL detected. #{parent_name} shutting down..."
            shutdown(KILL_TIMEOUT)
            next
          end

          break if @stopped && workers.empty?
          next if @stopped
          options = @options
          options = options.merge(:queues => queues) if queues
          add_worker(options)
        end
      rescue Errno::ECHILD
        logger.warn 'No worker processes found'
      end

      def schedule_kill(timeout)
        Thread.new do
          sleep(timeout)
          kill(1, "after #{timeout} second timeout")
        end
      end

      def signal_workers(signal)
        workers.each do |pid, (worker_name, _)|
          logger.info "Sent SIG#{signal} to worker #{worker_name}"
          Process.kill(signal, pid)
        end
      end

      def before_graceful_exit
        logger.info "#{parent_name} exited gracefully - pid #{$$}"
      end

      def parent_name
        "#{get_name(process_identifier)}#{' (parent)' if worker_count > 1}"
      end

      def set_process_name(name) # rubocop:disable AccessorMethodName
        $0 = process_prefix ? File.join(process_prefix, name) : name
      end

      def get_name(label)
        "delayed_job#{".#{label}" if label}"
      end

      def exit_with_error_status
        exit(1)
      end

      def setup_logger
        Delayed::Worker.logger ||= Logger.new(File.join(@options[:log_dir], 'delayed_job.log'))
      end

      def logger
        @logger ||= Delayed::Worker.logger || (::Rails.logger if defined?(::Rails.logger)) || Logger.new(STDOUT)
      end
    end
  end
end
