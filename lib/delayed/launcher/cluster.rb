require 'delayed/launcher/runner'

module Delayed
  module Launcher


    # This class is instantiated by the `Puma::Launcher` and used
    # to boot and serve a Ruby application when puma "workers" are needed
    # i.e. when using multi-processes. For example `$ puma -w 5`
    #
    # An instance of this class will spawn the number of processes passed in
    # via the `spawn_workers` method call. Each worker will have it's own
    # instance of a `Puma::Server`.


    # Some code in this class is lovingly borrowed from Puma (puma.io)
    class Cluster < Runner
      attr_accessor :worker_count

      DEFAULT_FORK_WORKER_JOBS = 1000
      DEFAULT_FORK_WORKER_SECONDS = 3600

      def initialize(launcher, options)
        check_fork_supported!

        @started_at = Time.now
        @workers = []
        @worker_index = 0
        @worker_count = options.delete(:worker_count) || raise(':worker_count required')
        @next_check = Time.now

        @phase = 0
        @phased_restart = false
        @last_phased_restart = @started_at
        @fork_after_jobs = (options.delete(:fork_after_jobs) || DEFAULT_FORK_WORKER_JOBS).to_i
        @fork_after_jobs = nil if @fork_after_jobs <= 0
        @fork_after_seconds = (options.delete(:fork_after_seconds) || DEFAULT_FORK_WORKER_SECONDS).to_i
        @fork_after_seconds = nil if @fork_after_seconds <= 0

        super
      end

      # TODO: NOT NEEDED
      # def restart
      #   @restart = true
      #   stop
      #   # TODO: parent needs to restart
      # end

      def phased_restart
        @phased_restart = true
        wakeup!
      end

      def stop(timeout = nil)
        @status = :stop
        wakeup!
        # TODO: add this
        schedule_halt(timeout)
      end

      def halt
        @status = :halt
        wakeup!
      end

      def run
        @status = :run

        output_header(mode)

        # This is aligned with Runner#output_header
        logger.info "*      Workers: #{@worker_count}"
        # logger.info "*     Restarts: (\u2714) hot (\u2714) phased"

        setup_pipes
        setup_signals
        setup_auto_fork_once
        spawn_workers
        run_loop
      end

    private

      def mode
        'cluster'
      end

      def run_loop
        booted = false
        in_phased_restart = false
        workers_not_booted = @worker_count

        while @status == :run
          begin
            if @phased_restart
              start_phased_restart
              @phased_restart = false
              in_phased_restart = true
              workers_not_booted = @worker_count
            end

            check_workers

            if read.wait_readable([0, @next_check - Time.now].max)
              req = read.read_nonblock(1)

              @next_check = Time.now if req == '!'
              next if !req || req == '!'

              result = read.gets
              pid = result.to_i

              if req == 'b' || req == 'f'
                pid, idx = result.split(':').map(&:to_i)
                w = @workers.find {|x| x.index == idx}
                w.pid = pid if w.pid.nil?
              end

              if w = @workers.find { |x| x.pid == pid }
                case req
                when 'b'
                  w.boot!
                  logger.info "- Worker #{w.index} (PID: #{pid}) booted in #{w.uptime.round(2)}s, phase: #{w.phase}"
                  @next_check = Time.now
                  workers_not_booted -= 1
                when 'e'
                  # external term, see worker method, Signal.trap "SIGTERM"
                  w.instance_variable_set(:@term, true)
                when 't'
                  w.term unless w.term?
                when 'p'
                  w.ping!(result.sub(/^\d+/,'').chomp)
                  events.fire(:ping, w)
                  if !booted && @workers.none? {|worker| worker.last_status.empty?}
                    events.fire(:on_booted)
                    booted = true
                  end
                end
              else
                logger.info "! Out-of-sync worker list, no #{pid} worker"
              end
            end

            if in_phased_restart && workers_not_booted.zero?
              events.fire(:on_booted)
              in_phased_restart = false
            end

          rescue Interrupt
            @status = :stop
          end
        end

        stop_workers unless @status == :halt
      ensure
        @check_pipe.close
        @suicide_pipe.close
        @parent_read.close
        @wakeup.close
      end

      def start_phased_restart
        events.fire(:on_restart)
        @phase += 1
        @last_phased_restart = Time.now
        logger.info "- Starting phased worker restart, phase: #{@phase}"

        # Be sure to change the directory again before loading
        # the app. This way we can pick up new code.
        dir = Delayed.root # @launcher.restart_dir
        logger.info "+ Changing to #{dir}"
        Dir.chdir dir
      end

      def stop_workers
        logger.info '- Gracefully shutting down workers...'
        @workers.each { |x| x.term }

        begin
          loop do
            wait_workers
            break if @workers.reject {|w| w.pid.nil?}.empty?
            sleep 0.2
          end
        rescue Interrupt
          logger.warn '! Cancelled waiting for workers'
        end
      end

      def wakeup!
        return if !@wakeup || @wakeup.closed?
        @wakeup.write('!')
      rescue SystemCallError, IOError
        Delayed.purge_interrupt_queue
      end

      def fork_worker!
        if (worker = @workers.find { |w| w.index == 0 })
          worker.phase += 1
        end
        phased_restart
      end

      def setup_pipes
        @parent_read, @wakeup = IO.pipe

        # Used by the workers to detect if the parent process dies.
        # If select says that @check_pipe is ready, it's because the
        # parent has exited and @suicide_pipe has been automatically closed.
        @check_pipe, @suicide_pipe = IO.pipe

        # Separate pipe used by worker 0 to receive commands to
        # fork new worker processes.
        @fork_pipe, @fork_writer = IO.pipe
      end

      def setup_signals
        setup_signal_shutdown('SIGINT')
        setup_signal_shutdown('SIGTERM')
        setup_signal_wakeup
        setup_signal_increment
        setup_signal_decrement
        setup_signal_fork_worker
        logger.info 'Use Ctrl-C to stop'
      end

      def setup_signal_wakeup
        Signal.trap('SIGCHLD') { wakeup! }
      end

      def setup_signal_increment
        Signal.trap('TTIN') do
          increment_worker_count
          wakeup!
        end
      end

      def setup_signal_decrement
        Signal.trap('TTOU') do
          decrement_worker_count
          wakeup!
        end
      end

      def setup_signal_fork_worker
        Signal.trap('SIGURG') { fork_worker! }
      end

      # Trapped signals are forwarded worker processes.
      # Hence it is not necessary to explicitly shutdown workers;
      # we only need to stop the run loop.
      def setup_signal_shutdown(signal)
        parent_pid = Process.pid

        Signal.trap(signal) do
          # The worker installs their own SIGTERM when booted.
          # Until then, this is run by the worker and the worker
          # should just exit if they get it.
          if Process.pid != parent_pid
            logger.info 'Early termination of worker'
            exit! 0
          else
            stop_workers
            stop
            events.fire(:on_stopped)
            raise(SignalException, signal) if (signal == 'SIGTERM' ? raise_sigterm : raise_sigint)
            exit 0 # Clean exit, workers were stopped
          end
        end
      end

      def increment_worker_count
        @worker_count += 1
      end

      def decrement_worker_count
        @worker_count -= 1 if @worker_count >= 2
      end

      def setup_auto_fork_once
        return unless @fork_after_seconds # || @fork_after_jobs
        events.register(:ping) do |w|
          break unless w.index == 0 && w.phase == 0
          time_exceeded = @fork_after_seconds && Time.now.to_i > @last_phased_restart + @fork_after_seconds
          # jobs_exceeded = @fork_after_jobs && w.last_status[:jobs_count] >= @fork_after_jobs
          break unless time_exceeded # || jobs_exceeded
          fork_worker!
        end
      end

      # TODO: add this
      def schedule_halt(timeout)
        return unless timeout
        Thread.new do
          sleep(timeout)
          halt(1, "after #{timeout} second timeout")
        end
      end

      def all_workers_booted?
        @workers.count { |w| !w.booted? } == 0
      end

      def check_workers
        return if @next_check >= Time.now

        @next_check = Time.now + @options[:worker_check_interval]

        timeout_workers
        wait_workers
        cull_workers
        spawn_workers
        phase_out_workers

        @next_check = [
          @workers.reject(&:term?).map(&:ping_timeout).min,
          @next_check
        ].compact.min
      end

      def timeout_workers
        @workers.each do |w|
          next unless !w.term? && w.ping_timeout <= Time.now
          details = if w.booted?
                      "(worker failed to check in within #{@options[:worker_timeout]} seconds)"
                    else
                      "(worker failed to boot within #{@options[:worker_boot_timeout]} seconds)"
                    end
          logger.info "! Terminating timed out worker #{details}: #{w.pid}"
          w.kill
        end
      end

      # loops thru @workers, removing workers that exited,
      # and calling `#term` if needed
      def wait_workers
        @workers.reject! do |w|
          begin
            next false if w.pid.nil?
            if Process.wait(w.pid, Process::WNOHANG)
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

        logger.debug "Culling #{diff.inspect} workers"

        workers_to_cull = @workers[-diff, diff]
        logger.debug "Workers to cull: #{workers_to_cull.inspect}"

        workers_to_cull.each do |worker|
          logger.info "- Worker #{worker.index} (PID: #{worker.pid}) terminating"
          worker.term
        end
      end

      def spawn_workers
        diff = @worker_count - @workers.size
        return if diff < 1

        parent = Process.pid
        @fork_writer << "-1\n"

        diff.times do
          idx = next_worker_index

          if idx != 0
            @fork_writer << "#{idx}\n"
            pid = nil
          else
            pid = spawn_worker(idx, parent)
          end

          logger.debug "Spawned worker: #{pid}"
          @workers << WorkerHandle.new(idx, pid, @phase, @options)
        end

        if @workers.all? { |x| x.phase == @phase }
          @fork_writer << "0\n"
        end
      end

      def next_worker_index
        all_positions = 0...@worker_count
        occupied_positions = @workers.map { |w| w.index }
        available_positions = all_positions.to_a - occupied_positions
        available_positions.first
      end

      def spawn_worker(idx, parent)
        Delayed::Worker.before_fork

        pid = fork { worker(idx, parent) }
        unless pid
          logger.info '! Complete inability to spawn new child processses detected'
          logger.info '! Seppuku is the only choice.'
          exit! 1
        end

        Delayed::Worker.after_fork
        pid
      end

      def worker(index, parent)
        @workers = []

        @parent_read.close
        @suicide_pipe.close
        @fork_writer.close

        pipes = { check_pipe: @check_pipe,
                  child_write: @wakeup,
                  fork_pipe: @fork_pipe,
                  wakeup: @wakeup }

        new_worker = ChildProcess.new(index,
                                      parent,
                                      @options,
                                      pipes,
                                      nil)
        new_worker.run
      end

      # If we're running at proper capacity, check to see if
      # we need to phase any workers out (which will restart
      # in the right phase).
      def phase_out_workers
        return unless all_workers_booted?

        w = @workers.find { |x| x.phase != @phase }
        return unless w

        logger.info "- Stopping #{w.pid} for phased upgrade..."

        return if w.term?
        w.term
        logger.info "- #{w.signal} sent to #{w.pid}..."
      end
    end
  end
end


# OLD
# def run
#   @stopped = !!@options[:exit_on_complete]
#   @killed = false
#   setup_logger
#   setup_signals
#   setup_auto_fork_worker
#   Delayed::Worker.before_fork if worker_count > 1
#   setup_workers
#   run_loop if worker_count > 1
#   before_graceful_exit
# end


# OLD
# def stop(timeout = nil)
#   @stopped = true
#   message = " with #{timeout} second grace period" if timeout
#   logger.info "Shutdown invoked#{message}"
#   @workers.reject(&:term?).each do |worker|
#     logger.info "Sending SIGTERM to worker #{worker.name}"
#     worker.term
#   end
#   schedule_kill(timeout) if timeout
# end
#
# OLD
# def halt(exit_status = 0, message = nil)
#   @stopped = true
#   @killed = true
#   message = " #{message}" if message
#   logger.warn "Kill invoked#{message}"
#   @workers.each do |worker|
#     logger.info "Sending SIGKILL to worker #{worker.name}"
#     worker.kill
#   end
#   logger.warn "#{parent_name} exited forcefully#{message} - pid #{$$}"
#   exit(exit_status)
# end

# def before_graceful_exit
#   logger.info "#{parent_name} exited gracefully - pid #{$$}"
# end
#
# def parent_name
#   "#{get_name(process_identifier)}#{' (parent)' if worker_count > 1}"
# end


# TODO: is this needed?
# def stop_blocked
#   @status = :stop if @status == :run
#   wakeup!
#   Process.waitall
# end

# def reload_worker_directory
#   dir = @launcher.restart_dir
#   logger.info "+ Changing to #{dir}"
#   Dir.chdir dir
# end

# Inside of a child process, this will return all zeroes, as @workers is only populated in
# the parent process.
# @!attribute [r] stats
# def stats
#   old_worker_count = @workers.count { |w| w.phase != @phase }
#   worker_status = @workers.map do |w|
#     {
#       started_at: w.started_at.utc.iso8601,
#       pid: w.pid,
#       index: w.index,
#       phase: w.phase,
#       booted: w.booted?,
#       last_checkin: w.last_checkin.utc.iso8601,
#       last_status: w.last_status,
#     }
#   end
#
#   {
#     started_at: @started_at.utc.iso8601,
#     workers: @workers.size,
#     phase: @phase,
#     booted_workers: worker_status.count { |w| w[:booted] },
#     old_workers: old_worker_count,
#     worker_status: worker_status,
#   }
# end



# OLD
# def add_worker(options)
#   worker_name = get_name(@worker_index)
#   worker_pid = spawn_worker(worker_name, options)
#
#   queues = options[:queues]
#   queue_msg = " queues=#{queues.empty? ? '*' : queues.join(',')}" if queues
#   logger.info "Worker #{worker_name} started - pid #{worker_pid}#{queue_msg}"
#
#   @workers << WorkerHandle.new(@worker_index, worker_pid, worker_name, queues)
#   @worker_index += 1
# end
#
# OLD
# def run_worker(worker_name, options)
#   Dir.chdir(Delayed.root)
#   set_process_name(worker_name)
#   Delayed::Worker.after_fork
#   setup_logger
#   worker = Delayed::Worker.new(options)
#   worker.name_prefix = "#{worker_name} "
#   worker.start
# rescue => e
#   STDERR.puts e.message
#   STDERR.puts e.backtrace
#   logger.fatal(e)
#   exit_with_error_status
# end
#
#
# def exit_with_error_status
#   exit(1)
# end
