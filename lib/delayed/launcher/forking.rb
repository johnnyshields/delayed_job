require 'active_support/core_ext/class/attribute'
require 'concurrent/array'

module Delayed
  module Launcher
    class Forking < Base
      # Extra seconds the parent gives workers past their shutdown timeout
      # (or after QUIT) before it SIGKILLs them: they need time to interrupt
      # and release their jobs (see Delayed::Dispatcher::INTERRUPT_GRACE).
      SHUTDOWN_GRACE = Delayed::Dispatcher::INTERRUPT_GRACE + 5

      # A child process that dies within this many seconds of starting (e.g.
      # running out of memory as it boots) is replaced only after a delay,
      # which doubles with each such death in a row - 1s, 2s, 4s... up to
      # RESPAWN_MAX_DELAY - so a crash loop doesn't spin. A replacement that
      # stays up longer resets it.
      RESPAWN_MIN_UPTIME = 10
      RESPAWN_MAX_DELAY = 60

      # The first respawn delay, in seconds (doubled with each quick death
      # in a row, up to RESPAWN_MAX_DELAY). A setting for tests, which wait
      # through crash loops: lower it to keep them fast.
      class_attribute :respawn_delay_unit, :instance_writer => false, :default => 1

      # options[:pid_file]: true writes a pidfile named after this process
      # in options[:pid_dir]; a String is the pidfile's path. Off by default.
      def initialize(options)
        pid_file = options.delete(:pid_file)
        super
        @pid_file = pid_file
        @workers_lock = Mutex.new # Before any thread uses it (see #workers_lock).
        # Before any signal trap uses them (see #child_signals).
        @stop_signals = Concurrent::Array.new
        @child_signals = Concurrent::Array.new
      end

      def launch
        @stopped = !!@options[:exit_on_complete]
        @killed = false
        stop_signals.clear
        Delayed::Worker.validate_settings!(@options)
        setup_logger
        setup_pidfile
        begin
          if forking? && !fork_available?
            raise NotImplementedError, 'running several worker processes needs fork, which this platform (e.g. JRuby) ' \
                                       'lacks: run one process per launcher, with --threads'
          end
          @launcher_pid = Process.pid
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

      # Whether this platform can fork (JRuby can't).
      def fork_available?
        Process.respond_to?(:fork)
      end

      # The pidfile's path, or nil without the :pid_file option.
      def pid_file
        return unless @pid_file
        return @pid_file.to_s unless @pid_file == true
        File.join(@options[:pid_dir], "#{get_name(process_identifier)}.pid")
      end

      def shutdown(timeout = nil)
        @stopped = true
        stop_signals << 'TERM' if stop_signals.empty?
        message = " with #{timeout} second grace period" if timeout
        logger.info "Shutdown invoked#{message}"
        signal_workers('TERM')
        schedule_kill(timeout) if timeout
      end

      def kill(exit_status = 0, message = nil)
        @stopped = true
        @killed = true
        stop_signals << 'KILL'
        message = " #{message}" if message
        logger.warn "Kill invoked#{message}"
        killed = workers_lock.synchronize { workers.dup }
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
        trap_hangup_signal if forking? && Signal.list.key?('HUP')
      end

      # SIGHUP (e.g. the terminal closed) stops the worker processes
      # gracefully, as TERM does: by default it would end the parent at once,
      # deleting its pidfile while they still run, so that a second launcher
      # could start beside them. Forwarded to them as TERM; they ignore HUP
      # itself (see #capture_signals). A single worker process (not forked)
      # keeps the default.
      def trap_hangup_signal
        Signal.trap('HUP') do
          next if forked_child?
          Thread.new { logger.info('Received SIGHUP. Waiting for workers to finish current job...') }
          stop_from_trap('TERM', kill_after_shutdown_timeout)
        end
      rescue ArgumentError => error
        logger.warn "Cannot trap SIGHUP on this platform (#{error.message})"
      end

      # Stops the run loop and forwards the signal to the worker processes:
      # a signal sent to the parent alone (docker stop, Kubernetes, systemd
      # with KillMode=process) must still reach them. Workers stop after
      # their current jobs, or after shutdown_timeout; the parent SIGKILLs
      # any still running SHUTDOWN_GRACE seconds after that.
      def trap_shutdown_signal(signal)
        Signal.trap(signal) do
          next child_signal(signal) if forked_child?
          Thread.new { logger.info("Received SIG#{signal}. Waiting for workers to finish current job...") }
          stop_from_trap(signal, kill_after_shutdown_timeout)
        end
      end

      # Workers interrupt and release their running jobs, then exit; the
      # parent SIGKILLs any still running after SHUTDOWN_GRACE seconds.
      # QUIT can't be trapped everywhere: the JVM (JRuby) reserves it for
      # thread dumps. Without it, TERM and INT still stop the workers.
      def trap_quit_signal
        Signal.trap('QUIT') do
          next child_signal('QUIT') if forked_child?
          Thread.new { logger.info('Received SIGQUIT. Interrupting running jobs...') }
          stop_from_trap('QUIT', SHUTDOWN_GRACE)
        end
      rescue ArgumentError => error
        logger.warn "Cannot trap SIGQUIT on this platform (#{error.message}); use TERM or INT to stop"
      end

      # Stops the launcher on `signal`, forwarding it to the worker processes
      # and SIGKILLing any left after `kill_after` seconds (if any).
      # Signal-trap safe: takes no lock and doesn't log.
      def stop_from_trap(signal, kill_after)
        @stopped = true
        stop_signals << signal unless stop_signals.include?(signal)
        forward_signal(signal)
        schedule_kill(kill_after) if kill_after
      end

      # SHUTDOWN_GRACE seconds past the shutdown timeout, if one is set.
      def kill_after_shutdown_timeout
        timeout = shutdown_timeout
        timeout + SHUTDOWN_GRACE if timeout
      end

      # Signal-trap safe: doesn't log.
      def forward_signal(signal)
        # A copy: the kill timer thread may remove workers meanwhile.
        workers.dup.each_key do |pid|
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          nil
        end
      end

      def shutdown_timeout
        @options.fetch(:shutdown_timeout, Delayed::Worker.shutdown_timeout)
      end

      def workers
        @workers ||= {}
      end

      # Guards changes to #workers, made by the main thread (the run loop)
      # and the kill timer thread (#kill). Signal traps only read a copy of
      # its keys, as a Mutex can't be locked in a trap.
      attr_reader :workers_lock

      # Signals that stopped the launcher (a signal, #shutdown or #kill), in
      # the order received. Signal-trap safe: appended to, never replaced.
      attr_reader :stop_signals

      # A signal that arrived while booting (before the dispatcher's traps
      # replace the launcher's) is passed on - the same list, so that one
      # arriving until then isn't lost either.
      def setup_single_worker
        set_process_name(get_name(process_identifier))
        Delayed::Dispatcher.new(@options.merge(:procline => $0)).start(stop_signals)
      end

      # Forks a child process. `replaces_pid` and `delay`: the pid of the child
      # process it replaces and the seconds waited before forking it, if any.
      # Once stopped by a signal (e.g. one that arrived while booting, before
      # any child existed to forward it to), forks none and returns nil; a
      # child forked as the signal arrived is sent it (see #catch_up_on_stop).
      def add_worker(options, replaces_pid: nil, delay: 0)
        return if stop_signals.any?
        worker_name = get_name(@worker_index)
        worker_pid = fork_worker(worker_name, options)

        queues = options[:queues]
        queue_msg = " queues=#{queues.empty? ? '*' : queues.join(',')}" if queues
        thread_msg = " threads=#{threads(options)}" if threads(options) > 1
        logger.info "Child process #{worker_name} (pid #{worker_pid}) started#{queue_msg}#{thread_msg}"

        workers_lock.synchronize { workers[worker_pid] = [worker_name, options] }
        started_at[worker_pid] = monotonic_now
        @worker_index += 1
        Delayed.instrument(:process_spawned, :worker => worker_name, :pid => worker_pid, :replaces_pid => replaces_pid, :delay => delay)
        catch_up_on_stop(worker_pid)
        worker_pid
      end

      # Sends a child just recorded in #workers the signal that stopped the
      # launcher, if one arrived after the check in #add_worker: the trap
      # forwarded it only to the children recorded at the time.
      def catch_up_on_stop(pid)
        signal = stop_signals.last
        return unless signal
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        nil
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
        # Signals that arrived while the inherited traps were installed (see
        # #child_signal) - the same list, not a copy: one can still arrive
        # through an inherited trap until it is replaced below.
        pending = child_signals
        %w[TERM INT QUIT].each do |signal|
          next unless Signal.list.key?(signal)
          # A signal can arrive twice: sent to the process group, and
          # forwarded by the parent.
          begin
            Signal.trap(signal) { pending << signal unless pending.include?(signal) }
          rescue ArgumentError
            nil # Can't be trapped here (QUIT on the JVM); the dispatcher warns.
          end
        end
        # The parent stops this process on SIGHUP (sent to the whole process
        # group when the terminal closes) with a TERM: see #trap_hangup_signal.
        Signal.trap('HUP', 'IGNORE') if Signal.list.key?('HUP')
        pending
      end

      # Whether this process is a child forked by the launcher that still runs
      # the launcher's (inherited) signal traps, before #capture_signals
      # replaces them. Signal-trap safe.
      def forked_child?
        @launcher_pid && Process.pid != @launcher_pid
      end

      # A launcher trap that ran in a freshly forked child process: only
      # records the signal, for the child to act on once it has started (see
      # #capture_signals) - it must not stop the child's copy of the
      # launcher, forward the signal to siblings, or schedule a kill.
      def child_signal(signal)
        child_signals << signal unless child_signals.include?(signal)
      end

      # A Concurrent::Array, as are #stop_signals: on JRuby, signal traps run
      # on threads of their own, in parallel, and Array#<< could lose one.
      # On CRuby it is a plain Array, safe in a trap (where a Mutex isn't).
      attr_reader :child_signals

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

      def run_loop
        loop do
          worker_pid, child_status = wait_for_child
          handle_exit(worker_pid, child_status) if worker_pid
          replace_due_workers
          break if @stopped && workers.empty?
        end
      rescue Errno::ECHILD
        logger.warn 'No child processes found'
      end

      # Waits for a child process to exit: returns [pid, status]. While a
      # replacement is pending (see #replace_worker), only until it falls due
      # or the launcher is stopped: returns nil then.
      def wait_for_child
        return Process.wait2 if pending_replacements.empty?
        loop do
          begin
            exited = Process.wait2(-1, Process::WNOHANG)
            return exited if exited
          rescue Errno::ECHILD
            nil # All children are waiting to be replaced.
          end
          remaining = pending_replacements.map(&:first).min - monotonic_now
          return if @stopped || remaining <= 0
          sleep([remaining, 0.1].min)
        end
      end

      # Recovers the jobs of a child process that exited, then replaces it
      # unless the launcher is stopping.
      def handle_exit(worker_pid, child_status)
        worker_name, options = workers_lock.synchronize { workers.delete(worker_pid) }
        return unless worker_name
        logger.info "Child process #{worker_name} (pid #{worker_pid}) exited: #{child_status}"
        recover_jobs_of_worker(worker_name, worker_pid, options, child_status)
        publish_child_exited(worker_name, worker_pid, child_status)

        # A child process SIGKILLed by someone else (e.g. the OOM killer)
        # is replaced like any other that died, its jobs recovered (above);
        # the other worker processes carry on.
        if child_status.termsig == 9 && !@killed
          logger.warn "Child process #{worker_name} (pid #{worker_pid}) was SIGKILLed (e.g. by the OOM killer)" \
                      "#{'; replacing it' unless @stopped}"
        end
        replace_worker(worker_name, worker_pid, options, child_status) unless @stopped
      ensure
        @plans&.delete(worker_pid)
      end

      # Replaces a child process that exited: at once, or - if it died soon
      # after starting (see RESPAWN_MIN_UPTIME) - after a delay, during which
      # other children are still reaped and replaced. Returns the new pid,
      # or nil if the replacement is delayed.
      def replace_worker(worker_name, pid, options, status)
        uptime, streak, delay = respawn_plan(pid)
        @plans.delete(pid)
        started_at.delete(pid)
        respawn_streaks.delete(pid)
        return respawn(worker_name, pid, options, status, streak, 0) unless delay
        logger.warn format('Child process %<name>s (pid %<pid>d) died %<uptime>.1fs after starting (%<streak>d time(s) in a row); ' \
                           'waiting %<delay>gs before replacing it',
                           :name => worker_name, :pid => pid, :uptime => uptime.to_f, :streak => streak, :delay => delay)
        pending_replacements << [monotonic_now + delay, [worker_name, pid, options, status, streak, delay]]
        nil
      end

      def publish_child_exited(worker_name, pid, status)
        uptime, _streak, delay = respawn_plan(pid)
        respawn_in = @stopped ? nil : delay || 0
        Delayed.instrument(:process_exited, :worker => worker_name, :pid => pid, :status => status, :uptime => uptime, :respawn_in => respawn_in)
      end

      # How long the child process `pid` ran (nil if its start wasn't
      # recorded), its quick deaths in a row, and the seconds to wait before
      # replacing it (nil for none). Worked out once per exit (until
      # #handle_exit is done), so its event and its replacement agree.
      def respawn_plan(pid)
        (@plans ||= {})[pid] ||= begin
          started = started_at[pid]
          uptime = started && monotonic_now - started
          streak = uptime && uptime < RESPAWN_MIN_UPTIME ? respawn_streaks[pid].to_i + 1 : 0
          [uptime, streak, respawn_delay(streak)]
        end
      end

      # Forks the replacements that fell due, unless the launcher is stopping.
      def replace_due_workers
        return if pending_replacements.empty?
        return pending_replacements.clear if @stopped
        now = monotonic_now
        due, pending = pending_replacements.partition { |at, _| at <= now }
        @pending_replacements = pending
        due.sort_by(&:first).each { |_, replacement| respawn(*replacement) }
      end

      # Forks the replacement. If forking fails (e.g. EAGAIN or ENOMEM, out
      # of processes or memory), retries later with the back-off of a child
      # that died at once, instead of crashing the launcher.
      def respawn(worker_name, pid, options, status, streak, delay) # rubocop:disable Metrics/ParameterLists
        new_pid = add_worker(options, :replaces_pid => pid, :delay => delay)
        respawn_streaks[new_pid] = streak if new_pid
        new_pid
      rescue SystemCallError => error
        retry_delay = respawn_delay(streak + 1)
        logger.error "Could not fork a replacement for child process #{worker_name} (pid #{pid}): " \
                     "#{error.class}: #{error.message}; retrying in #{retry_delay}s"
        Delayed::Worker.thread_error(error, :context => 'Forking', :worker => worker_name, :pid => pid)
        pending_replacements << [monotonic_now + retry_delay, [worker_name, pid, options, status, streak + 1, retry_delay]]
        nil
      end

      # Seconds to wait before replacing a child process after `streak`
      # quick deaths in a row, or nil for none.
      def respawn_delay(streak)
        return if streak.zero?
        [respawn_delay_unit * 2**(streak - 1), RESPAWN_MAX_DELAY].min
      end

      # [[due time, replacement], ...] of child processes waiting to be
      # replaced (see #replace_worker).
      def pending_replacements
        @pending_replacements ||= []
      end

      def started_at
        @started_at ||= {}
      end

      def respawn_streaks
        @respawn_streaks ||= {}
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
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
          workers_lock.synchronize { workers.delete(pid) }
          recover_jobs_of_worker(worker_name, pid, options, status)
        end
      end

      # A worker process that didn't exit cleanly may have died while running
      # jobs (OOM killer, SIGKILL, crash), leaving them locked until
      # max_run_time expires. Recover them now: each counts as a failed
      # attempt (see Delayed::Worker.recover_jobs_of). If the database can't
      # be reached, the locks are left to expire.
      def recover_jobs_of_worker(worker_name, pid, options, status)
        lock_names = Delayed::Worker.lock_names("#{worker_name} ", pid, threads(options), prefetch(options))
        # A child process that exited cleanly released its jobs' locks
        # itself; any left (a job that ignored its shutdown interrupt) are
        # stale now that it is gone: release them, attempts unchanged.
        return Delayed::Job.clear_locks_of!(lock_names) if status.success?
        count = Delayed::Worker.recover_jobs_of(lock_names, ProcessExitError.new(worker_name, pid, status))
        logger.warn "Recovered #{count} job(s) left locked by child process #{worker_name} (pid #{pid})" if count > 0
      rescue StandardError => error
        logger.error "Could not recover the jobs of child process #{worker_name} (pid #{pid}): #{error.class}: #{error.message}. " \
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

      # Workers that already exited (not reaped yet, or reaped meanwhile by
      # the run loop) are skipped: signalling them must not abort a kill.
      def signal_workers(signal)
        workers.dup.each do |pid, (worker_name, _)|
          Process.kill(signal, pid)
          logger.info "Sent SIG#{signal} to child process #{worker_name} (pid #{pid})"
        rescue Errno::ESRCH
          logger.info "Child process #{worker_name} (pid #{pid}) already exited; not sent SIG#{signal}"
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
