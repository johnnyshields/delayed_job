module Delayed
  module Launcher

    # Parent launcher class which spawns DelayedJob worker processes
    # in the foreground.
    #
    # Some code in this class is lovingly borrowed from Puma (puma.io)
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
        @phase = 0
        @workers = []
        @next_check = Time.now
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
        @workers.reject(&:term?).each do |worker|
          logger.info "Sending SIGTERM to worker #{worker.name}"
          worker.term
        end
        schedule_kill(timeout) if timeout
      end

      def kill(exit_status = 0, message = nil)
        @stopped = true
        @killed = true
        message = " #{message}" if message
        logger.warn "Kill invoked#{message}"
        @workers.each do |worker|
          logger.info "Sending SIGKILL to worker #{worker.name}"
          worker.kill
        end
        logger.warn "#{parent_name} exited forcefully#{message} - pid #{$$}"
        exit(exit_status)
      end

    private

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
        worker_pid = spawn_worker(worker_name, options)

        queues = options[:queues]
        queue_msg = " queues=#{queues.empty? ? '*' : queues.join(',')}" if queues
        logger.info "Worker #{worker_name} started - pid #{worker_pid}#{queue_msg}"

        @workers << WorkerHandle.new(@worker_index, worker_pid, worker_name, queues)
        @worker_index += 1
      end

      def fork_worker!
        if (worker = @workers.find { |w| w.index == 0 })
          worker.phase += 1
        end
        phased_restart
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

      def trap_signals
        trap_shutdown_signal('INT')
        trap_shutdown_signal('TERM')
        trap_fork_signals

        # Signal.trap "SIGCHLD" do
        #   wakeup!
        # end
        #
        # TODO: pool mode
        # Signal.trap "TTIN" do
        #   @worker_count += 1
        #   wakeup!
        # end
        #
        # Signal.trap "TTOU" do
        #   @worker_count -= 1 if @worker_count >= 2
        #   wakeup!
        # end
      end

      def trap_fork_signals
        return unless @options[:fork_worker]

        Signal.trap('SIGURG') do
          fork_worker!
        end

        # Auto-fork after the specified number of requests.
        if (fork_requests = @options[:fork_worker].to_i) > 0
          @launcher.events.register(:ping!) do |w|
            fork_worker! if w.index == 0 &&
              w.phase == 0 &&
              w.last_status[:requests_count] >= fork_requests
            # TODO: last_status appears to be some way the handle
            # can get the log of the process to know number of requests.
            # this could maybe be a pipe...
          end
        end
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

      def run_loop # rubocop:disable CyclomaticComplexity, PerceivedComplexity
        loop do
          check_workers

          # # If any child was SIGKILL'ed, we must shutdown all children.
          # # This first will attempt a graceful SIGTERM of the children,
          # # followed by a SIGKILL after a timeout period.
          # if child_status.termsig == 9 && !@killed
          #   @killed = true
          #   logger.warn "Worker #{worker.name} SIGKILL detected. #{parent_name} shutting down..."
          #   shutdown(KILL_TIMEOUT)
          #   next
          # end
          #
          # in puma this is moved to the worker??

          # TODO: this should be status logic
          break if @stopped && @workers.empty?
          next if @stopped
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

      def before_graceful_exit
        logger.info "#{parent_name} exited gracefully - pid #{$$}"
      end

      def parent_name
        "#{get_name(process_identifier)}#{' (parent)' if worker_count > 1}"
      end

      def all_workers_booted?
        @workers.count { |w| !w.booted? } == 0
      end

      def check_workers
        return if @next_check >= Time.now

        @next_check = Time.now + @options[:worker_check_interval]

        # timeout_workers
        wait_workers
        cull_workers
        spawn_workers
        phase_out_workers

        @next_check = [
          @workers.reject(&:term?).map(&:ping_timeout).min,
          @next_check
        ].compact.min
      end

      # def timeout_workers
      #   @workers.each do |w|
      #     if !w.term? && w.ping_timeout <= Time.now
      #       details = if w.booted?
      #                   "(worker failed to check in within #{@options[:worker_timeout]} seconds)"
      #                 else
      #                   "(worker failed to boot within #{@options[:worker_boot_timeout]} seconds)"
      #                 end
      #       log "! Terminating timed out worker #{details}: #{w.pid}"
      #       w.kill
      #     end
      #   end
      # end

      # loops thru @workers, removing workers that exited, and calling
      # `#term` if needed
      def wait_workers
        # TODO: this needs ot wait all workers - see code below
        # worker_pid = Process.wait
        # next unless workers.key?(worker_pid)
        # worker = workers.delete(worker_pid)
        # child_status = $?
        # logger.info "Worker #{worker.name} exited - #{child_status}"
        #
        #
        #
        #
        # if child_status.termsig == 9 && !@killed
        #   @killed = true
        #   logger.warn "Worker #{worker.name} SIGKILL detected. #{parent_name} shutting down..."
        #   shutdown(KILL_TIMEOUT)
        #   next
        # end

        @workers.reject! do |w|
          next false if w.pid.nil?
          begin
            if Process.wait(w.pid, Process::WNOHANG)
              child_status = $?
              logger.info "Worker #{worker.name} exited - #{child_status}"

              # If any child was SIGKILL'ed, we must shutdown all children.
              # This first will attempt a graceful SIGTERM of the children,
              # followed by a SIGKILL after a timeout period.
              if child_status.termsig == 9 && !@killed
                @killed = true
                logger.warn "Worker #{w.name} SIGKILL detected. #{parent_name} shutting down..."
                shutdown(KILL_TIMEOUT)
              end

              true
            else
              w.term if w.term?
              nil
            end
          rescue Errno::ECHILD
            begin
              Process.kill(0, w.pid)
              # child still alive but has another parent (e.g., using fork_worker)
              w.term if w.term?
              false
            rescue Errno::ESRCH, Errno::EPERM
              true # child is already terminated
            end
          end
        end
      end

      def cull_workers
        diff = @workers.size - @worker_count
        return if diff < 1

        debug "Culling #{diff.inspect} workers"

        workers_to_cull = @workers[-diff, diff]
        debug "Workers to cull: #{workers_to_cull.inspect}"

        workers_to_cull.each do |worker|
          log "- Worker #{worker.index} (PID: #{worker.pid}) terminating"
          worker.term
        end
      end

      def spawn_workers


        options = @options
        options = options.merge(:queues => worker.queues) if worker.queues
        add_worker(options)



        diff = @worker_count - @workers.size
        return if diff < 1

        master = Process.pid
        if @options[:fork_worker]
          @fork_writer << "-1\n"
        end

        diff.times do
          idx = next_worker_index

          if @options[:fork_worker] && idx != 0
            @fork_writer << "#{idx}\n"
            pid = nil
          else
            pid = spawn_worker(idx, master)
          end

          debug "Spawned worker: #{pid}"
          @workers << WorkerHandle.new(idx, pid, @phase, @options)
        end

        if @options[:fork_worker] &&
          @workers.all? {|x| x.phase == @phase}

          @fork_writer << "0\n"
        end
      end

      def next_worker_index
        all_positions = 0...@worker_count
        occupied_positions = @workers.map { |w| w.index }
        available_positions = all_positions.to_a - occupied_positions
        available_positions.first
      end

      def spawn_worker(worker_name, options)
        # @launcher.config.run_hooks :before_worker_fork, idx, @launcher.events

        pid = fork { run_worker(worker_name, options) }
        unless pid
          log "! Complete inability to spawn new workers detected"
          log "! Seppuku is the only choice."
          exit! 1
        end

        # @launcher.config.run_hooks :after_worker_fork, idx, @launcher.events
        pid
      end

      # If we're running at proper capacity, check to see if
      # we need to phase any workers out (which will restart
      # in the right phase).
      def phase_out_workers
        return unless all_workers_booted?

        w = @workers.find { |x| x.phase != @phase }

        if w
          log "- Stopping #{w.pid} for phased upgrade..."
          unless w.term?
            w.term
            log "- #{w.signal} sent to #{w.pid}..."
          end
        end
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
