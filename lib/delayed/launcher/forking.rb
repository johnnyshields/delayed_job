require 'active_support/core_ext/class/attribute'
require 'concurrent/array'

module Delayed
  module Launcher
    # The forking launcher without mold support; see Forking.
    class ForkingBase < Base
      # Seconds past the shutdown timeout (or QUIT) before the parent SIGKILLs
      # workers, so they can interrupt and release their jobs.
      SHUTDOWN_GRACE = Delayed::Dispatcher::INTERRUPT_GRACE + 5

      # A child dying within RESPAWN_MIN_UPTIME seconds is replaced after a
      # delay doubling per death in a row (up to RESPAWN_MAX_DELAY), so a
      # crash loop doesn't spin.
      RESPAWN_MIN_UPTIME = 10
      RESPAWN_MAX_DELAY = 60

      # First respawn delay in seconds; tests lower it.
      class_attribute :respawn_delay_unit, :instance_writer => false, :default => 1

      # options[:pid_file]: true for a pidfile named after this process in
      # options[:pid_dir], or a String path.
      def initialize(options)
        pid_file = options.delete(:pid_file)
        super
        @pid_file = pid_file
        @workers_lock = Mutex.new # Created eagerly: lazy init would race.
        # Created eagerly: signal traps can't lazily init safely.
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

      # JRuby can't fork.
      def fork_available?
        Process.respond_to?(:fork)
      end

      # The pidfile's path, or nil.
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

      # HUP stops workers gracefully (forwarded as TERM). By default it would
      # kill the parent and delete its pidfile while workers still run,
      # letting a second launcher start beside them.
      def trap_hangup_signal
        Signal.trap('HUP') do
          next if forked_child?
          Thread.new { logger.info('Received SIGHUP. Waiting for workers to finish current job...') }
          stop_from_trap('TERM', kill_after_shutdown_timeout)
        end
      rescue ArgumentError => error
        logger.warn "Cannot trap SIGHUP on this platform (#{error.message})"
      end

      # Forwards the signal to workers: docker stop, Kubernetes and systemd
      # (KillMode=process) signal only the parent.
      def trap_shutdown_signal(signal)
        Signal.trap(signal) do
          next child_signal(signal) if forked_child?
          Thread.new { logger.info("Received SIG#{signal}. Waiting for workers to finish current job...") }
          stop_from_trap(signal, kill_after_shutdown_timeout)
        end
      end

      # QUIT interrupts running jobs. The JVM reserves QUIT for thread dumps.
      def trap_quit_signal
        Delayed.check_trappable!('QUIT')
        Signal.trap('QUIT') do
          next child_signal('QUIT') if forked_child?
          Thread.new { logger.info('Received SIGQUIT. Interrupting running jobs...') }
          stop_from_trap('QUIT', SHUTDOWN_GRACE)
        end
      rescue ArgumentError => error
        logger.warn "Cannot trap SIGQUIT on this platform (#{error.message}); use TERM or INT to stop"
      end

      # Signal-trap safe: takes no lock and doesn't log.
      def stop_from_trap(signal, kill_after)
        @stopped = true
        stop_signals << signal unless stop_signals.include?(signal)
        forward_signal(signal)
        schedule_kill(kill_after) if kill_after
      end

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

      # Guards writes to #workers by the run loop and the kill timer thread.
      # Traps only read a copy, as a Mutex can't be locked in a trap.
      attr_reader :workers_lock

      # Signals that stopped the launcher, in order. Appended to, never
      # replaced, so traps can use it.
      attr_reader :stop_signals

      # Passes the same list, so a signal arriving before the dispatcher's
      # traps replace the launcher's isn't lost.
      def setup_single_worker
        set_process_name(get_name(process_identifier))
        Delayed::Dispatcher.new(@options.merge(:procline => $0)).start(stop_signals)
      end

      # Forks a child process; returns nil once a stop signal has arrived
      # (e.g. while booting, before any child existed to forward it to).
      def add_worker(options, replaces_pid: nil, delay: 0)
        return if stop_signals.any?
        index = @worker_index
        @worker_index += 1
        worker_name = get_name(index)
        child_started(worker_name, fork_worker(worker_name, options), options, :replaces_pid => replaces_pid, :delay => delay)
      end

      # Records a forked child process. `spawn`: :replaces_pid, :delay, and
      # :mold_pid when a mold forked it.
      def child_started(worker_name, worker_pid, options, spawn)
        queues = options[:queues]
        queue_msg = " queues=#{queues.empty? ? '*' : queues.join(',')}" if queues
        thread_msg = " threads=#{threads(options)}" if threads(options) > 1
        mold_msg = " from mold (pid #{spawn[:mold_pid]})" if spawn[:mold_pid]
        logger.info "Child process #{worker_name} (pid #{worker_pid}) started#{mold_msg}#{queue_msg}#{thread_msg}"

        workers_lock.synchronize { workers[worker_pid] = [worker_name, options] }
        started_at[worker_pid] = monotonic_now
        Delayed.instrument(:process_spawned, {:worker => worker_name, :pid => worker_pid, :replaces_pid => spawn[:replaces_pid],
                                              :delay => spawn[:delay] || 0}.merge(spawn.slice(:mold_pid)))
        catch_up_on_stop(worker_pid)
        worker_pid
      end

      # A stop signal arriving after #add_worker's check was forwarded only
      # to children recorded then; send it to this one too.
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

      # Replaces the parent's inherited traps (which would signal sibling
      # workers) with ones that only record signals, so a signal arriving
      # while the worker boots isn't lost.
      def capture_signals
        # Same list, not a copy: an inherited trap may still fire until
        # replaced below.
        pending = child_signals
        %w[TERM INT QUIT].each do |signal|
          next unless Signal.list.key?(signal)
          # Deduped: may arrive via the process group and the parent.
          begin
            Delayed.check_trappable!(signal)
            Signal.trap(signal) { pending << signal unless pending.include?(signal) }
          rescue ArgumentError
            nil # Can't be trapped here (QUIT on the JVM); the dispatcher warns.
          end
        end
        # The parent forwards HUP as TERM (see #trap_hangup_signal).
        Signal.trap('HUP', 'IGNORE') if Signal.list.key?('HUP')
        pending
      end

      # True in a forked child still running the inherited launcher traps.
      def forked_child?
        @launcher_pid && Process.pid != @launcher_pid
      end

      # An inherited trap in a child only records the signal: it must not
      # stop the child's launcher copy or signal siblings.
      def child_signal(signal)
        child_signals << signal unless child_signals.include?(signal)
      end

      # Concurrent::Array: JRuby runs traps on parallel threads. On CRuby
      # it's a plain Array, safe in a trap (a Mutex isn't).
      attr_reader :child_signals

      # Written first, so a second launcher exits before booting workers.
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

      # Returns [pid, status], or nil when a pending replacement falls due or
      # the launcher stops.
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

      def handle_exit(worker_pid, child_status)
        worker_name, options = workers_lock.synchronize { workers.delete(worker_pid) }
        return unless worker_name
        replace = replace_exited?(worker_pid, options, child_status)
        logger.info "Child process #{worker_name} (pid #{worker_pid}) exited: #{child_status}"
        recover_jobs_of_worker(worker_name, worker_pid, options, child_status)
        publish_child_exited(worker_name, worker_pid, child_status, replace)

        if child_status.termsig == 9 && !@killed
          logger.warn "Child process #{worker_name} (pid #{worker_pid}) was SIGKILLed (e.g. by the OOM killer)" \
                      "#{'; replacing it' if replace}"
        end
        replace_worker(worker_name, worker_pid, options, child_status) if replace
      ensure
        @plans&.delete(worker_pid)
      end

      # Returns the new pid, or nil if delayed (see RESPAWN_MIN_UPTIME).
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

      # Whether an exited child process is replaced (MoldSupervisor overrides).
      def replace_exited?(_pid, _options, _status)
        !@stopped
      end

      def publish_child_exited(worker_name, pid, status, replace = !@stopped)
        uptime, _streak, delay = respawn_plan(pid)
        respawn_in = replace ? delay || 0 : nil
        Delayed.instrument(:process_exited, :worker => worker_name, :pid => pid, :status => status, :uptime => uptime, :respawn_in => respawn_in)
      end

      # [uptime, streak, delay]; memoized per exit so the event and the
      # replacement agree.
      def respawn_plan(pid)
        (@plans ||= {})[pid] ||= begin
          started = started_at[pid]
          uptime = started && monotonic_now - started
          streak = uptime && uptime < RESPAWN_MIN_UPTIME ? respawn_streaks[pid].to_i + 1 : 0
          [uptime, streak, respawn_delay(streak)]
        end
      end

      def replace_due_workers
        return if pending_replacements.empty?
        return pending_replacements.clear if @stopped
        now = monotonic_now
        due, pending = pending_replacements.partition { |at, _| at <= now }
        @pending_replacements = pending
        due.sort_by(&:first).each { |_, replacement| respawn(*replacement) }
      end

      # A failed fork (EAGAIN, ENOMEM) is retried with back-off rather than
      # crashing the launcher.
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

      def respawn_delay(streak)
        return if streak.zero?
        [respawn_delay_unit * 2**(streak - 1), RESPAWN_MAX_DELAY].min
      end

      # [[due_at, replacement_args], ...]
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

      # The run loop may reap some first; it then recovers them itself.
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

      # Unlocks jobs a dead worker held, rather than waiting out max_run_time.
      # A crash counts as a failed attempt.
      def recover_jobs_of_worker(worker_name, pid, options, status)
        lock_names = Delayed::Worker.lock_names("#{worker_name} ", pid, threads(options), prefetch(options))
        # Clean exit: leftover locks are stale; release, attempts unchanged.
        return Delayed::Job.clear_locks!(lock_names) if status.success?
        count = Delayed::Worker.recover_jobs_of(lock_names, ProcessExitError.new(worker_name, pid, status))
        logger.warn "Recovered #{count} job(s) left locked by child process #{worker_name} (pid #{pid})" if count > 0
      rescue StandardError => error
        logger.error "Could not recover the jobs of child process #{worker_name} (pid #{pid}): #{error.class}: #{error.message}. " \
                     'Their locks will expire after max_run_time.'
        Delayed::Worker.thread_error(error, :context => 'Recovering jobs', :worker => worker_name, :pid => pid)
      ensure
        disconnect_backend
      end

      # So the next forked worker doesn't inherit recovery's connections.
      def disconnect_backend
        Delayed::Worker.backend.before_fork
      rescue StandardError => error
        logger.error "Could not disconnect from the database: #{error.class}: #{error.message}"
      end

      # No-op if a kill is already scheduled sooner. Signal-trap safe.
      def schedule_kill(timeout)
        at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        return if @kill_at && @kill_at <= at
        @kill_at = at
        Thread.new do
          sleep(timeout)
          kill(1, "after #{timeout} second timeout")
        end
      end

      # Skips workers that already exited, so a kill isn't aborted.
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

      # Mirrors the branches of #setup_workers.
      def forking?
        return true if pools
        !process_identifier && processes > 1
      end
    end

    # MoldSupervisor overrides ForkingBase only in mold mode (Worker.mold).
    class Forking < ForkingBase
      include Mold
      include MoldSupervisor
    end
  end
end
