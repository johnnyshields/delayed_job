module Delayed
  module Launcher
    class Forking < Base
      KILL_TIMEOUT = 30

      # Extra seconds the parent gives workers past their shutdown timeout
      # (or after QUIT) before it SIGKILLs them: they need time to interrupt
      # and release their jobs (see Delayed::Dispatcher::INTERRUPT_GRACE).
      SHUTDOWN_GRACE = Delayed::Dispatcher::INTERRUPT_GRACE + 5

      # options[:pid_file]: true writes a pidfile named after this process
      # in options[:pid_dir]; a String is the pidfile's path. Off by default.
      def initialize(options)
        pid_file = options.delete(:pid_file)
        super
        @pid_file = pid_file
      end

      def launch
        @stopped = !!@options[:exit_on_complete]
        @killed = false
        setup_logger
        setup_pidfile
        begin
          trap_signals
          if forking?
            supervisor_pid
            prepare_for_fork
            Delayed::Worker.before_fork
          end
          setup_workers
          run_loop if forking?
          before_graceful_exit
        ensure
          delete_pidfile
        end
      end

      # The pidfile's path, or nil without the :pid_file option.
      def pid_file
        return unless @pid_file
        return @pid_file.to_s unless @pid_file == true
        File.join(@options[:pid_dir], "#{get_name(process_identifier)}.pid")
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
        killed = workers.dup
        signal_workers('KILL')
        reap_killed_workers(killed)
        logger.warn "#{parent_name} exited forcefully#{message} - pid #{$$}"
        exit(exit_status)
      end

    private

      def trap_signals
        trap_shutdown_signal('INT')
        trap_shutdown_signal('TERM')
        trap_quit_signal if Signal.list.key?('QUIT')
      end

      # Stops the run loop and forwards the signal to the worker processes:
      # a signal sent to the parent alone (docker stop, Kubernetes, systemd
      # with KillMode=process) must still reach them. Workers stop after
      # their current jobs, or after shutdown_timeout; the parent SIGKILLs
      # any still running SHUTDOWN_GRACE seconds after that.
      def trap_shutdown_signal(signal)
        Signal.trap(signal) do
          Thread.new { logger.info("Received SIG#{signal}. Waiting for workers to finish current job...") }
          @stopped = true
          forward_signal(signal)
          timeout = shutdown_timeout
          schedule_kill(timeout + SHUTDOWN_GRACE) if timeout
        end
      end

      # Workers interrupt and release their running jobs, then exit; the
      # parent SIGKILLs any still running after SHUTDOWN_GRACE seconds.
      def trap_quit_signal
        Signal.trap('QUIT') do
          Thread.new { logger.info('Received SIGQUIT. Interrupting running jobs...') }
          @stopped = true
          forward_signal('QUIT')
          schedule_kill(SHUTDOWN_GRACE)
        end
      end

      # Signal-trap safe: doesn't log.
      def forward_signal(signal)
        workers.each_key do |pid|
          begin
            Process.kill(signal, pid)
          rescue Errno::ESRCH
            nil
          end
        end
      end

      def shutdown_timeout
        @options.fetch(:shutdown_timeout, Delayed::Worker.shutdown_timeout)
      end

      def workers
        @workers ||= {}
      end

      def setup_single_worker
        set_process_name(get_name(process_identifier))
        Delayed::Dispatcher.new(@options.merge(:procline => $0)).start
      end

      def add_worker(options)
        worker_name = get_name(@worker_index)
        worker_pid = fork_worker(worker_name, options)

        queues = options[:queues]
        queue_msg = " queues=#{queues.empty? ? '*' : queues.join(',')}" if queues
        thread_msg = " threads=#{threads(options)}" if threads(options) > 1
        logger.info "Worker #{worker_name} started - pid #{worker_pid}#{queue_msg}#{thread_msg}"

        workers[worker_pid] = [worker_name, options]
        @worker_index += 1
        worker_pid
      end

      def fork_worker(worker_name, options)
        fork do
          pending_signals = capture_signals
          run_worker(worker_name, options, pending_signals)
        end
      end

      # Called first thing in a forked worker process, which inherits this
      # (the parent's) signal traps: they would forward signals to sibling
      # workers and even SIGKILL them. Replaces them with traps that only
      # record the signal; the worker handles the recorded signals once it
      # has installed its own traps (see Delayed::Dispatcher#start), so a
      # signal arriving while the worker starts up isn't lost.
      def capture_signals
        pending = []
        %w[TERM INT QUIT].each do |signal|
          next unless Signal.list.key?(signal)
          # A signal can arrive twice: sent to the process group, and
          # forwarded by the parent.
          Signal.trap(signal) { pending << signal unless pending.include?(signal) }
        end
        pending
      end

      # Writes the pidfile before anything else, so that a second launcher
      # exits (with Delayed::AlreadyRunningError) before booting workers.
      def setup_pidfile
        return unless pid_file
        @pidfile = Delayed::Pidfile.new(pid_file)
        @pidfile.setup
        logger.info "Wrote pidfile #{pid_file} - pid #{$$}"
      end

      def delete_pidfile
        @pidfile.delete if @pidfile
      end

      # Forked workers stop if this process (their parent) goes away.
      def supervisor_pid
        @supervisor_pid ||= Process.pid
      end

      def run_loop # rubocop:disable CyclomaticComplexity, PerceivedComplexity
        loop do
          worker_pid, child_status = Process.wait2
          next unless workers.key?(worker_pid)
          worker_name, options = workers.delete(worker_pid)
          logger.info "Worker #{worker_name} exited - #{child_status}"
          recover_jobs_of_worker(worker_name, worker_pid, options, child_status)

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
          new_pid = add_worker(options)
          Delayed.instrument(:fork_replaced, :worker => worker_name, :pid => worker_pid, :status => child_status, :new_pid => new_pid)
        end
      rescue Errno::ECHILD
        logger.warn 'No worker processes found'
      end

      # Waits for the given SIGKILLed workers and recovers their jobs. The main
      # thread may reap some of them first (it then recovers them itself).
      def reap_killed_workers(killed)
        killed.each do |pid, (worker_name, options)|
          begin
            _, status = Process.waitpid2(pid)
          rescue Errno::ECHILD
            next
          end
          workers.delete(pid)
          recover_jobs_of_worker(worker_name, pid, options, status)
        end
      end

      # A worker process that didn't exit cleanly may have died while running
      # jobs (OOM killer, SIGKILL, crash), leaving them locked until
      # max_run_time expires. Recover them now: each counts as a failed
      # attempt (see Delayed::Worker.recover_jobs_of). If the database can't
      # be reached, the locks are left to expire.
      def recover_jobs_of_worker(worker_name, pid, options, status)
        return if status.success?
        lock_names = Delayed::Worker.lock_names("#{worker_name} ", pid, threads(options))
        count = Delayed::Worker.recover_jobs_of(lock_names, ProcessExitError.new(worker_name, pid, status))
        logger.warn "Recovered #{count} job(s) left locked by worker #{worker_name} (pid #{pid})" if count > 0
      rescue StandardError => error
        logger.error "Could not recover the jobs of worker #{worker_name} (pid #{pid}): #{error.class}: #{error.message}. " \
                     'Their locks will expire after max_run_time.'
        Delayed::Worker.thread_error(error, :context => 'Recovering jobs', :worker => worker_name, :pid => pid)
      ensure
        disconnect_backend
      end

      # Drops the connections opened by recovery, so the next forked worker
      # doesn't inherit them.
      def disconnect_backend
        Delayed::Worker.backend.before_fork
      rescue StandardError => error
        logger.error "Could not disconnect from the database: #{error.class}: #{error.message}"
      end

      # Kills the remaining workers after `timeout` seconds, unless a kill is
      # already scheduled sooner. Signal-trap safe.
      def schedule_kill(timeout)
        at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        return if @kill_at && @kill_at <= at
        @kill_at = at
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
        "#{get_name(process_identifier)}#{' (parent)' if forking?}"
      end

      # Whether worker processes are forked (otherwise the single worker runs
      # in this process). Mirrors the branches of #setup_workers.
      def forking?
        return true if pools
        !process_identifier && processes > 1
      end
    end
  end
end
