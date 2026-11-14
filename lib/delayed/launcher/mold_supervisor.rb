module Delayed
  module Launcher
    # Mold process (experimental), parent side; see Mold. Created by the
    # forking launcher only with Worker.mold.
    #
    # A child process reaching the next threshold (or the busiest one, on
    # SIGURG to the parent) is promoted: it stops gracefully and forks a mold.
    # Once the mold is ready, every child process is reforked from it one at
    # a time, the replacement first, so capacity doesn't drop. The previous
    # mold exits once its children have.
    class MoldSupervisor
      # Child process state tracked from status lines.
      Child = Struct.new(:mold_pid, :jobs, :busy, :booted, :retiring, :promoted)

      # Seconds a mold may take to fork a requested child before the parent
      # gives up on it and forks the child itself.
      MOLD_FORK_TIMEOUT = 30

      # Seconds from the promoted child's exit until its mold must be ready,
      # or (PROMOTION_FORK_TIMEOUT) must have been forked.
      MOLD_READY_TIMEOUT = 120
      PROMOTION_FORK_TIMEOUT = 5

      # Status line type => handler (see Mold::Pipes).
      STATUS_HANDLERS = {
        'b' => :child_booted, 'p' => :child_pinged, 'M' => :mold_forked,
        'm' => :activate_mold, 'f' => :mold_forked_child, 'x' => :mold_reaped_child
      }.freeze

      # `launcher`: the Forking launcher (see its "used by MoldSupervisor"
      # methods); `thresholds`: Worker.mold_thresholds.
      def initialize(launcher, thresholds, pipes, logger)
        @launcher = launcher
        @thresholds = thresholds
        @pipes = pipes
        @logger = logger
        @molds = {} # pid => :promoted, :active or :retired
        @active_mold = nil
        @generation = 0
        @threshold_index = 0
        @children = {} # pid => Child
        @early_boots = {} # pid => true: booted before the parent recorded it
        @pending_forks = {} # worker index => {:options, :spawn, :at}
        @deferred_slots = [] # options of promoted children's slots
      end

      # Signal-trap safe.
      def request_promotion
        @promote_requested = true
      end

      # Whether new child processes are forked by a mold.
      def forking_from_mold?
        !@active_mold.nil?
      end

      # Asks the active mold to fork a child process; its pid is recorded
      # when the mold reports it.
      def request_fork(index, options, spawn)
        @pending_forks[index] = {:options => options, :spawn => spawn, :at => monotonic_now}
        @pipes.request_fork(index, Mold.pool_index(@launcher.pools, options))
        nil
      end

      def child_started(pid, spawn)
        @children[pid] = Child.new(spawn[:mold_pid], 0, 0, @early_boots.delete(pid), false, false)
      end

      # How an exited child process is replaced: :retiring (it already was),
      # :promoted (from its mold, once ready, with no crash back-off), or nil
      # (as usual).
      def child_exited(pid, status)
        info = @children.delete(pid)
        return unless info
        return :retiring if info.retiring
        promoted_exited(pid, status) if info.promoted
      end

      # Refills a promoted child's slot, from its mold once ready.
      def defer_slot(options)
        @deferred_slots << options
        refill_deferred_slots unless @promoted_pid
      end

      # Returns whether `pid` was a mold (reaped when the parent is PID 1).
      def reaped(pid)
        return false unless @molds.key?(pid)
        mold_exited(pid)
        true
      end

      # One pass of the launcher's run loop.
      def tick
        @pipes.each_status(0.1) { |type, *args| handle_status(type, *args) }
        check_molds
        check_orphans
        check_pending_forks
        check_promotion
        abandon_pending_forks if @launcher.stopped?
        promote_mold(:signal) if @promote_requested
        @promote_requested = false
        advance_refork
      end

      # No mold left and no fork pending.
      def done?
        @molds.empty? && @pending_forks.empty?
      end

      # Signal-trap safe.
      def signal_molds(signal)
        @molds.dup.each_key do |pid|
          Process.kill(signal, pid)
        rescue Errno::ESRCH
          nil
        end
      end

      # A child forked by a mold can't be waited for: polls until it's gone.
      def wait_until_gone(pid, timeout = 5)
        deadline = monotonic_now + timeout
        sleep 0.05 while alive?(pid) && monotonic_now < deadline
        !alive?(pid)
      end

    private

      attr_reader :logger

      def handle_status(type, *args)
        handler = STATUS_HANDLERS[type]
        send(handler, *args) if handler
      end

      def child_booted(pid)
        info = @children[pid]
        info ? info.booted = true : @early_boots[pid] = true
      end

      def child_pinged(pid, jobs, busy)
        info = @children[pid]
        return unless info
        info.booted = true
        info.jobs = jobs
        info.busy = busy
        threshold = @thresholds[@threshold_index]
        return unless threshold && jobs >= threshold && settled?
        @threshold_index += 1
        promote_mold(:threshold)
      end

      def mold_reaped_child(pid, exitstatus, termsig)
        @launcher.handle_exit(pid, ReportedStatus.new(pid, exitstatus, termsig))
      end

      # Exiting cleanly, it forked its mold; otherwise the promotion failed.
      def promoted_exited(pid, status)
        current = @promoted_pid == pid
        unless status.success?
          @promoted_pid = nil if current
          return
        end
        @promoted_exited_at = monotonic_now if current
        :promoted
      end

      # Every child process runs and comes from the active mold (or the
      # parent, before the first): no promotion or refork in progress.
      def settled?
        !@launcher.stopped? && promotion_idle? && refork_idle?
      end

      def promotion_idle?
        @promoted_pid.nil? && !@molds.value?(:promoted)
      end

      def refork_idle?
        @pending_forks.empty? && @deferred_slots.empty? && @refork_step.nil? &&
          @children.values.all? { |info| current?(info) && !info.retiring }
      end

      def current?(info)
        info.mold_pid == @active_mold
      end

      # The child process with the most jobs performed, preferring idle ones
      # so promotion doesn't wait for long jobs.
      def promote_mold(trigger)
        return if @launcher.stopped? || @promoted_pid
        pid, info = promotion_candidate
        return logger.warn('No child process to promote to mold') unless pid
        info.promoted = true
        @promoted_pid = pid
        @promoted_exited_at = nil
        worker_name, = @launcher.workers[pid]
        logger.info "Promoting child process #{worker_name} (pid #{pid}) to mold after #{info.jobs} job(s)"
        Delayed.instrument(:mold_promoted, :worker => worker_name, :pid => pid, :jobs => info.jobs, :trigger => trigger)
        Process.kill('URG', pid)
      rescue Errno::ESRCH
        nil # Exited meanwhile; handled as an exit.
      end

      def promotion_candidate
        @children.select { |_, info| info.booted && !info.retiring && !info.promoted }.
          max_by { |_, info| [info.busy.zero? ? 1 : 0, info.jobs] }
      end

      # Gives up on a promotion whose mold isn't ready in time (e.g. the
      # promoted child was stopped by a signal instead, forking no mold).
      def check_promotion
        return unless promotion_overdue?
        logger.warn "Child process (pid #{@promoted_pid}) promoted to mold, but no mold became ready; carrying on without it"
        @molds.select { |_, role| role == :promoted }.each_key { |pid| kill(pid) }
        @promoted_pid = nil
        refill_deferred_slots
      end

      def promotion_overdue?
        return false unless @promoted_pid && @promoted_exited_at
        waited = monotonic_now - @promoted_exited_at
        waited >= MOLD_READY_TIMEOUT || (waited >= PROMOTION_FORK_TIMEOUT && !@molds.value?(:promoted))
      end

      def mold_forked(child_pid, mold_pid)
        @molds[mold_pid] ||= :promoted # Tracked so shutdown waits for it.
        kill(mold_pid) if @launcher.stopped? || child_pid != @promoted_pid
      end

      def activate_mold(mold_pid)
        return kill(mold_pid) unless activatable?(mold_pid)
        @promoted_pid = nil
        retire_mold(@active_mold) if @active_mold
        @molds[mold_pid] = :active
        @active_mold = mold_pid
        @generation += 1
        logger.info "Mold (pid #{mold_pid}) ready; reforking child processes from it (generation #{@generation})"
        Delayed.instrument(:mold_activated, :pid => mold_pid, :generation => @generation)
      end

      # The mold of the current promotion, while running.
      def activatable?(mold_pid)
        !@launcher.stopped? && @molds.fetch(mold_pid, :promoted) == :promoted && (@promoted_pid || @molds.key?(mold_pid))
      end

      def retire_mold(mold_pid)
        @molds[mold_pid] = :retired
        logger.info "Retired mold (pid #{mold_pid}); it exits once its child processes have"
        Delayed.instrument(:mold_retired, :pid => mold_pid)
        Process.kill('URG', mold_pid)
      rescue Errno::ESRCH
        nil
      end

      def mold_forked_child(mold_pid, pid, index)
        entry = @pending_forks.delete(index)
        unless entry
          logger.warn "Stopping child process (pid #{pid}) forked by mold (pid #{mold_pid}) after the parent gave up on it"
          return kill(pid)
        end
        @launcher.child_started(@launcher.child_name(index), pid, entry[:options], entry[:spawn].merge(:mold_pid => mold_pid))
      end

      # Molds aren't the parent's children (unless it's PID 1): poll them.
      def check_molds
        @molds.dup.each_key { |pid| mold_exited(pid) unless alive?(pid) }
      end

      def mold_exited(pid)
        case @molds.delete(pid)
        when :active
          logger.warn "Mold (pid #{pid}) exited; forking child processes from the parent again" unless @launcher.stopped?
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
        @pipes.drain_fork_requests
        pending = @pending_forks.sort_by(&:first)
        @pending_forks.clear
        pending.each { |index, entry| @launcher.start_child(index, entry[:options], entry[:spawn]) }
      end

      # Children of a dead mold stop by themselves (Process.ppid changes);
      # the parent can't wait for them, so it polls.
      def check_orphans
        gone = @children.select { |pid, info| info.mold_pid && !@molds.key?(info.mold_pid) && !alive?(pid) }.keys
        gone.each { |pid| @launcher.handle_exit(pid, ReportedStatus.new(pid, nil, nil)) }
      end

      def check_pending_forks
        return if @pending_forks.empty? || !@active_mold
        oldest = @pending_forks.values.map { |entry| entry[:at] }.min
        return if monotonic_now - oldest < MOLD_FORK_TIMEOUT
        logger.warn "Mold (pid #{@active_mold}) did not fork a child process within #{MOLD_FORK_TIMEOUT}s; stopping it"
        kill(@active_mold)
        mold_exited(@active_mold)
      end

      # A stopping mold forks nothing more.
      def abandon_pending_forks
        return if @pending_forks.empty?
        @pipes.drain_fork_requests
        @pending_forks.clear
      end

      # One child process at a time: fork its replacement from the active
      # mold, and stop it once the replacement has booted.
      def advance_refork
        return if @launcher.stopped? || @promoted_pid
        refill_deferred_slots
        return unless refork_ready?
        old_pid = next_to_refork
        refork(old_pid) if old_pid
      ensure
        stop_retiring_child
      end

      # Every child booted, and the last step's child exited.
      def refork_ready?
        @pending_forks.empty? && @children.values.all?(&:booted) && refork_step_done?
      end

      def refork_step_done?
        return true unless @refork_step
        return false if @launcher.workers.key?(@refork_step)
        @refork_step = nil
        true
      end

      # A child process not from the active mold, not already handled.
      def next_to_refork
        @children.each { |pid, info| return pid unless current?(info) || info.retiring || info.promoted }
        nil
      end

      def refork(old_pid)
        worker_name, options = @launcher.workers[old_pid]
        @launcher.add_worker(options, :replaces_pid => old_pid)
        @children[old_pid].retiring = true
        @refork_step = @retire_when_booted = old_pid
        logger.info "Reforking child process #{worker_name} (pid #{old_pid}) from mold (pid #{@active_mold})"
      end

      # The replacement has booted: stop the child it replaces.
      def stop_retiring_child
        pid = @retire_when_booted
        return unless pid && @pending_forks.empty? && @children.values.all? { |info| info.booted || info.retiring }
        @retire_when_booted = nil
        Process.kill('TERM', pid)
      rescue Errno::ESRCH
        nil
      end

      def refill_deferred_slots
        @launcher.add_worker(@deferred_slots.shift) until @deferred_slots.empty? || @launcher.stopping?
      end

      def kill(pid)
        Process.kill('TERM', pid)
      rescue Errno::ESRCH
        nil
      end

      def alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
