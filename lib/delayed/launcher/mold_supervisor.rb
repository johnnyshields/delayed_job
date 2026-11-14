module Delayed
  module Launcher
    # Mold process (experimental), parent side; included in Forking. Without
    # Worker.mold every method defers to ForkingBase. See Mold for the pipes.
    #
    # A child process reaching the next threshold (or the busiest one, on
    # SIGURG to the parent) is promoted: it stops gracefully and forks a mold.
    # Once the mold is ready, every child process is reforked from it one at
    # a time, the replacement first, so capacity doesn't drop. The previous
    # mold exits once its children have.
    module MoldSupervisor
      # Child process state the parent tracks in mold mode.
      Child = Struct.new(:mold_pid, :jobs, :busy, :booted, :retiring, :promoted)

      # Seconds a mold may take to fork a requested child before the parent
      # gives up on it and forks the child itself.
      MOLD_FORK_TIMEOUT = 30

      # Seconds a promotion may take, from the promoted child's exit until its
      # mold is ready, before the parent gives up on it.
      MOLD_READY_TIMEOUT = 120

      def launch
        validate_mold_launch! if molding?
        super
      end

    private

      def validate_mold_launch!
        raise NotImplementedError, 'mold needs fork, which this platform (e.g. JRuby) lacks' unless fork_available?
        raise ArgumentError, 'mold cannot be used with --identifier' if process_identifier
      end

      def forking?
        super || molding?
      end

      def multiple_processes?
        super || molding?
      end

      def trap_signals
        super
        return unless molding?
        # Signal-trap safe: only sets a flag for the run loop.
        Signal.trap('URG') { @promote_requested = true unless forked_child? }
      end

      def setup_workers
        if molding?
          open_mold_pipes
          @molds = {} # pid => :promoted, :active or :retired
          @active_mold = nil
          @generation = 0
          @threshold_index = 0
          @status_buffer = +''
        end
        super
      end

      def run_worker(*)
        close_parent_pipe_ends if molding? && @fork_write
        super
      end

      def child_info
        @child_info ||= {}
      end

      # pending fork index => {:options, :spawn, :at}
      def pending_forks
        @pending_forks ||= {}
      end

      # Options of promoted children's slots, refilled from the new mold.
      def deferred_slots
        @deferred_slots ||= []
      end

      def child_started(worker_name, worker_pid, options, spawn)
        pid = super
        child_info[pid] = Child.new(spawn[:mold_pid], 0, 0, early_boots.delete(pid), false, false) if molding? && pid
        pid
      end

      def early_boots
        @early_boots ||= {}
      end

      def pool_index(options)
        return Mold::NO_POOL unless pools
        pools.index { |queues, _| queues == options[:queues] } || Mold::NO_POOL
      end

      # With an active mold, asks it to fork the child; returns nil (the pid
      # is recorded when the mold reports it).
      def add_worker(options, replaces_pid: nil, delay: 0)
        return super unless molding? && @active_mold
        return if stop_signals.any?
        index = @worker_index
        @worker_index += 1
        spawn = {:replaces_pid => replaces_pid, :delay => delay, :streak => @respawn_streak}
        pending_forks[index] = {:options => options, :spawn => spawn, :at => monotonic_now}
        @fork_write.write([index, pool_index(options)].pack(Mold::FORK_RECORD))
        nil
      end

      def respawn(*args)
        @respawn_streak = args[4]
        super
      ensure
        @respawn_streak = nil
      end

      # A retiring child was already replaced. A promoted one that forked
      # its mold is replaced from that mold, with no crash back-off.
      def replace_exited?(pid, options, status)
        info = molding? && child_info.delete(pid)
        return super unless info
        return false if info.retiring
        promoted_exited(pid, status) if info.promoted
        super
      end

      # Exiting cleanly, it forked its mold; otherwise the promotion failed.
      def promoted_exited(pid, status)
        current = @promoted_pid == pid
        if status.success?
          @promoted_exited_at = monotonic_now if current
          promoted_exits << pid
        elsif current
          @promoted_pid = nil
        end
      end

      def promoted_exits
        @promoted_exits ||= []
      end

      def respawn_plan(pid)
        return super unless promoted_exits.include?(pid)
        (@plans ||= {})[pid] ||= [started_at[pid] && monotonic_now - started_at[pid], 0, nil]
      end

      def replace_worker(worker_name, pid, options, status)
        return super unless promoted_exits.delete(pid)
        started_at.delete(pid)
        deferred_slots << options
        refill_deferred_slots unless @promoted_pid
        nil
      end

      # Gives up on a promotion whose mold isn't ready in time (e.g. the
      # promoted child was stopped by a signal instead, forking no mold).
      def check_promotion
        return unless promotion_overdue?
        logger.warn "Child process (pid #{@promoted_pid}) promoted to mold, but no mold became ready; carrying on without it"
        @molds.select { |_, role| role == :promoted }.each_key { |pid| kill_mold(pid) }
        @promoted_pid = nil
        refill_deferred_slots
      end

      # No mold within MOLD_READY_TIMEOUT, or none forked within 5 seconds.
      def promotion_overdue?
        return false unless @promoted_pid && @promoted_exited_at
        waited = monotonic_now - @promoted_exited_at
        waited >= MOLD_READY_TIMEOUT || (waited >= 5 && !@molds.value?(:promoted))
      end

      # A stopping mold forks nothing more.
      def abandon_pending_forks
        return if pending_forks.empty?
        drain_fork_pipe
        pending_forks.clear
      end

      def run_loop
        return super unless molding?
        loop do
          check_processes
          promote_mold(:signal) if @promote_requested
          @promote_requested = false
          advance_refork
          replace_due_workers
          break if all_stopped?
        end
      end

      def check_processes
        reap_children
        read_status
        check_molds
        check_orphans
        check_pending_forks
        check_promotion
        abandon_pending_forks if @stopped
      end

      def all_stopped?
        @stopped && workers.empty? && pending_forks.empty? && @molds.empty?
      end

      # Direct children, and orphans if this process is PID 1.
      def reap_children
        loop do
          pid, status = Process.wait2(-1, Process::WNOHANG)
          break unless pid
          if @molds.key?(pid)
            mold_exited(pid)
          else
            handle_exit(pid, status)
          end
        end
      rescue Errno::ECHILD
        nil
      end

      def read_status
        return unless @status_read.wait_readable(0.1)
        @status_buffer << @status_read.read_nonblock(65_536)
        while (line = @status_buffer.slice!(/\A[^\n]*\n/))
          handle_status(*line.split)
        end
      rescue IO::WaitReadable
        nil
      end

      # Status line type => handler (see Mold).
      STATUS_HANDLERS = {
        'b' => :child_booted, 'p' => :child_pinged, 'M' => :mold_forked,
        'm' => :activate_mold, 'f' => :mold_forked_child, 'x' => :mold_reaped_child
      }.freeze

      def handle_status(type, *args)
        handler = STATUS_HANDLERS[type]
        send(handler, *args.map { |arg| arg == '-' ? nil : arg.to_i }) if handler
      end

      def mold_reaped_child(pid, exitstatus, termsig)
        handle_exit(pid, ReportedStatus.new(pid, exitstatus, termsig))
      end

      def child_booted(pid)
        info = child_info[pid]
        info ? info.booted = true : early_boots[pid] = true
      end

      def child_pinged(pid, jobs, busy)
        info = child_info[pid]
        return unless info
        info.booted = true
        info.jobs = jobs
        info.busy = busy
        threshold = mold_thresholds[@threshold_index]
        return unless threshold && jobs >= threshold && settled?
        @threshold_index += 1
        promote_mold(:threshold)
      end

      # Every child process runs and comes from the active mold (or the
      # parent, before the first): no promotion or refork in progress.
      def settled?
        !@stopped && promotion_idle? && refork_idle?
      end

      def promotion_idle?
        @promoted_pid.nil? && !@molds.value?(:promoted)
      end

      def refork_idle?
        pending_forks.empty? && deferred_slots.empty? && @refork_step.nil? &&
          child_info.values.all? { |info| current?(info) && !info.retiring }
      end

      def current?(info)
        info.mold_pid == @active_mold
      end

      # The child process with the most jobs performed, preferring idle ones
      # so promotion doesn't wait for long jobs.
      def promote_mold(trigger)
        return if @stopped || @promoted_pid
        pid, info = promotion_candidate
        return logger.warn('No child process to promote to mold') unless pid
        info.promoted = true
        @promoted_pid = pid
        @promoted_exited_at = nil
        worker_name, = workers[pid]
        logger.info "Promoting child process #{worker_name} (pid #{pid}) to mold after #{info.jobs} job(s)"
        Delayed.instrument(:mold_promoted, :worker => worker_name, :pid => pid, :jobs => info.jobs, :trigger => trigger)
        Process.kill('URG', pid)
      rescue Errno::ESRCH
        nil # Exited meanwhile; handled as an exit.
      end

      def promotion_candidate
        child_info.select { |_, info| info.booted && !info.retiring && !info.promoted }.
          max_by { |_, info| [info.busy.zero? ? 1 : 0, info.jobs] }
      end

      def mold_forked(child_pid, mold_pid)
        @molds[mold_pid] ||= :promoted # Tracked so shutdown waits for it.
        kill_mold(mold_pid) if @stopped || child_pid != @promoted_pid
      end

      def activate_mold(mold_pid)
        return kill_mold(mold_pid) if @stopped || @molds.fetch(mold_pid, :promoted) != :promoted || (@promoted_pid.nil? && !@molds.key?(mold_pid))
        @promoted_pid = nil
        retire_mold(@active_mold) if @active_mold
        @molds[mold_pid] = :active
        @active_mold = mold_pid
        @generation += 1
        logger.info "Mold (pid #{mold_pid}) ready; reforking child processes from it (generation #{@generation})"
        Delayed.instrument(:mold_activated, :pid => mold_pid, :generation => @generation)
      end

      def retire_mold(mold_pid)
        @molds[mold_pid] = :retired
        logger.info "Retired mold (pid #{mold_pid}); it exits once its child processes have"
        Delayed.instrument(:mold_retired, :pid => mold_pid)
        Process.kill('URG', mold_pid)
      rescue Errno::ESRCH
        nil
      end

      def kill_mold(mold_pid)
        Process.kill('TERM', mold_pid)
      rescue Errno::ESRCH
        nil
      end

      def mold_forked_child(mold_pid, pid, index)
        entry = pending_forks.delete(index)
        unless entry
          logger.warn "Stopping child process (pid #{pid}) forked by mold (pid #{mold_pid}) after the parent gave up on it"
          return kill_mold(pid)
        end
        spawn = entry[:spawn].merge(:mold_pid => mold_pid)
        child_started(get_name(index), pid, entry[:options], spawn)
        respawn_streaks[pid] = spawn[:streak] if spawn[:streak]
      end

      # Molds aren't this process's children (unless it's PID 1): poll them.
      def check_molds
        @molds.each_key.to_a.each { |pid| mold_exited(pid) unless alive?(pid) }
      end

      def mold_exited(pid)
        role = @molds.delete(pid)
        return unless role
        case role
        when :active
          logger.warn "Mold (pid #{pid}) exited; forking child processes from the parent again" unless @stopped
          @active_mold = nil
          fork_pending_from_parent
        when :promoted
          logger.warn "Mold (pid #{pid}) exited before it was ready"
          @promoted_pid = nil
        end
        refill_deferred_slots unless @promoted_pid
      end

      # Unread requests would be read by the next mold: fork them here.
      def fork_pending_from_parent
        drain_fork_pipe
        pending = pending_forks.sort_by(&:first)
        pending_forks.clear
        pending.each do |index, entry|
          next if stop_signals.any?
          pid = child_started(get_name(index), fork_worker(get_name(index), entry[:options]), entry[:options], entry[:spawn])
          respawn_streaks[pid] = entry[:spawn][:streak] if entry[:spawn][:streak]
        end
      end

      def drain_fork_pipe
        loop { break unless @fork_read.read_nonblock(4096, :exception => false).is_a?(String) }
      end

      # Children of a dead mold stop by themselves (Process.ppid changes);
      # the parent can't wait for them, so it polls.
      def check_orphans
        gone = child_info.select { |pid, info| info.mold_pid && !@molds.key?(info.mold_pid) && !alive?(pid) }.keys
        gone.each { |pid| handle_exit(pid, ReportedStatus.new(pid, nil, nil)) }
      end

      def check_pending_forks
        return if pending_forks.empty? || !@active_mold
        oldest = pending_forks.values.map { |entry| entry[:at] }.min
        return if monotonic_now - oldest < MOLD_FORK_TIMEOUT
        logger.warn "Mold (pid #{@active_mold}) did not fork a child process within #{MOLD_FORK_TIMEOUT}s; stopping it"
        kill_mold(@active_mold)
        mold_exited(@active_mold)
      end

      # One child process at a time: fork its replacement from the active
      # mold, and stop it once the replacement has booted.
      def advance_refork
        return if @stopped || @promoted_pid
        refill_deferred_slots
        return unless refork_ready?
        old_pid = next_to_refork
        refork(old_pid) if old_pid
      ensure
        stop_retiring_child
      end

      # Every child booted, and the last step's child exited.
      def refork_ready?
        pending_forks.empty? && child_info.values.all?(&:booted) && refork_step_done?
      end

      # A child process not from the active mold, not already handled.
      def next_to_refork
        child_info.each { |pid, info| return pid unless current?(info) || info.retiring || info.promoted }
        nil
      end

      # The child process the last step replaced has exited.
      def refork_step_done?
        return true unless @refork_step
        return false if workers.key?(@refork_step)
        @refork_step = nil
        true
      end

      def refork(old_pid)
        worker_name, options = workers[old_pid]
        add_worker(options, :replaces_pid => old_pid)
        child_info[old_pid].retiring = true
        @refork_step = @retire_when_booted = old_pid
        logger.info "Reforking child process #{worker_name} (pid #{old_pid}) from mold (pid #{@active_mold})"
      end

      # The replacement has booted: stop the child it replaces.
      def stop_retiring_child
        pid = @retire_when_booted
        return unless pid && pending_forks.empty? && child_info.values.all? { |info| info.booted || info.retiring }
        @retire_when_booted = nil
        Process.kill('TERM', pid)
      rescue Errno::ESRCH
        nil
      end

      def refill_deferred_slots
        add_worker(deferred_slots.shift) until deferred_slots.empty? || stop_signals.any?
      end

      def alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      # Molds too: a stopping mold exits once its children have.
      def forward_signal(signal)
        super
        return unless @molds
        @molds.dup.each_key do |pid|
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          nil
        end
      end

      def signal_workers(signal)
        super
        return unless @molds
        @molds.dup.each_key do |pid|
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          nil
        end
      end

      # A child forked by a mold can't be waited for: poll until it's gone.
      def reap_killed_workers(killed)
        return super unless molding?
        killed.each do |pid, (worker_name, options)|
          status = begin
            Process.waitpid2(pid).last
          rescue Errno::ECHILD
            wait_until_gone(pid) && ReportedStatus.new(pid, nil, 9)
          end
          next unless status && workers_lock.synchronize { workers.delete(pid) }
          recover_jobs_of_worker(worker_name, pid, options, status)
        end
      end

      def wait_until_gone(pid, timeout = 5)
        deadline = monotonic_now + timeout
        sleep 0.05 while alive?(pid) && monotonic_now < deadline
        !alive?(pid)
      end
    end
  end
end
