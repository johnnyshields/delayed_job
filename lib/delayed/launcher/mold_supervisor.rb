require 'active_support/core_ext/class/attribute'

module Delayed
  module Launcher
    # Mold process (experimental), parent side; see Mold. Created by the
    # forking launcher only with Worker.mold.
    #
    # A child process reaching the next threshold (or the busiest one, on
    # SIGURG to the parent) is promoted: it stops gracefully and forks a mold.
    # Once the mold is ready, child processes are reforked from it a few at a
    # time, each replacement booting before the child it replaces is stopped.
    # A mold that dies is replaced by another promotion; until then, the
    # parent forks child processes itself.
    class MoldSupervisor
      # Child process state tracked from status lines. `replaces`: the old
      # child a refork replacement takes over from, until it boots.
      Child = Struct.new(:mold_pid, :generation, :jobs, :busy, :booted, :retiring, :promoted,
                         :started_at, :unsafe, :orphaned, :replaces)

      # Seconds a mold may take to fork a requested child before it counts
      # as hung and is killed.
      MOLD_FORK_TIMEOUT = 30

      # Seconds from the promoted child's exit until its mold must be ready,
      # or (PROMOTION_FORK_TIMEOUT) must have been forked.
      MOLD_READY_TIMEOUT = 120
      PROMOTION_FORK_TIMEOUT = 5

      # Child processes forked by one mold that die before booting, in a row,
      # before that mold counts as broken.
      BOOT_FAILURE_LIMIT = 3

      # A mold living this long resets the promotion retry back-off.
      MOLD_STABLE_UPTIME = 600
      MAX_RETRY_DELAY = 600

      # Share of child processes reforked at once (at least one).
      REFORK_SHARE = 0.1

      # Seconds a child process may take to boot before it is killed.
      class_attribute :boot_timeout, :instance_writer => false, :default => 60
      # First promotion retry delay in seconds, doubling per failure.
      class_attribute :retry_delay_unit, :instance_writer => false, :default => 10
      # Seconds the promoted child may drain before its slot is refilled.
      class_attribute :drain_deadline, :instance_writer => false, :default => 300

      # Status line type => handler (see Mold::Pipes).
      STATUS_HANDLERS = {
        'b' => :child_booted, 'p' => :child_pinged, 'M' => :mold_forked, 'm' => :mold_ready,
        'f' => :mold_forked_child, 'e' => :mold_fork_failed, 'x' => :mold_reaped_child
      }.freeze

      attr_reader :generation

      # `launcher`: the Forking launcher (see its methods used by
      # MoldSupervisor); `reaps_orphans`: whether orphaned descendants are
      # reparented to it (child subreaper, or PID 1).
      def initialize(launcher, thresholds, pipes, reaps_orphans)
        @launcher = launcher
        @thresholds = thresholds
        @pipes = pipes
        @reaps_orphans = reaps_orphans
        @molds = {} # pid => :promoted, :active, :retired or :abandoned
        @generation = 0
        @threshold_index = 0
        @children = {} # pid => Child
        @early_boots = {} # pid => when it booted, before the parent recorded it
        @pending_forks = {} # worker index => {:options, :spawn, :at}
        @deferred_slots = [] # [options, replaces_pid] of promoted children
        @steps = {} # old pid => replacement pid (nil until forked)
        @failures = 0 # promotions failed (or molds lost) in a row
        @refilled_promotions = [] # promoted pids whose slot was refilled early
      end

      # Signal-trap safe.
      def request_promotion
        @promote_requested = true
      end

      def forking_from_mold?
        !@active_mold.nil?
      end

      # Asks the active mold to fork a child process; its pid is recorded
      # when the mold reports it.
      def request_fork(index, options, spawn)
        @pending_forks[index] = {:options => options, :spawn => spawn, :at => monotonic_now}
        @pipes.request_fork(index, Mold.pool_index(@launcher.pools, options), spawn[:generation])
        nil
      end

      def child_started(pid, spawn)
        info = Child.new(spawn[:mold_pid], spawn.fetch(:generation, @generation), 0, 0, false, false, false, monotonic_now, false, false, nil)
        replaced = spawn[:replaces_pid]
        if replaced && @steps.key?(replaced)
          info.replaces = replaced
          @steps[replaced] = pid
        end
        @children[pid] = info
        mark_booted(pid, info) if @early_boots.delete(pid)
      end

      # How an exited child process's slot is filled: :retiring (another
      # process holds it), :promoted (from its mold, once ready), or nil (as
      # usual).
      def child_exited(pid, status)
        info = @children.delete(pid)
        @early_boots.delete(pid)
        return unless info
        role = promoted_exited(pid, status) if info.promoted
        step_failed = refork_step_failed(info)
        @steps.delete(pid) # An old child exiting mid-step: its replacement takes over.
        count_boot_failure(pid) if failed_to_boot?(info, status)
        info.retiring || step_failed ? :retiring : role
      end

      def failed_to_boot?(info, status)
        info.mold_pid && !info.booted && !status.success?
      end

      def defer_slot(options, replaces_pid)
        @deferred_slots << [options, replaces_pid]
        refill_deferred_slots unless @promotion
      end

      # Returns whether `pid` was a mold (reaped as this process's child).
      def reaped(pid)
        return false unless @molds.key?(pid)
        mold_exited(pid)
        true
      end

      # One pass of the launcher's run loop.
      def tick
        @pipes.each_status(0.1) { |type, *args| handle_status(type, *args) }
        unless @reaps_orphans # Otherwise reaped as this process's children.
          check_molds
          check_orphans
        end
        check_timeouts
        handle_promotion_requests
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

      # A child forked by a mold may not be this process's to wait for.
      def wait_until_gone(pid, timeout = 5)
        deadline = monotonic_now + timeout
        sleep 0.05 while ProcessUtil.alive?(pid) && monotonic_now < deadline
        !ProcessUtil.alive?(pid)
      end

    private

      def logger
        @launcher.logger
      end

      def handle_status(type, *args)
        handler = STATUS_HANDLERS[type]
        send(handler, *args) if handler
      end

      def child_booted(pid)
        info = @children[pid]
        info ? mark_booted(pid, info) : @early_boots[pid] = monotonic_now
      end

      def child_pinged(pid, jobs, busy, unsafe = 0)
        info = @children[pid]
        return unless info
        mark_booted(pid, info)
        info.jobs = jobs
        info.busy = busy
        info.unsafe = unsafe == 1
        threshold = @thresholds[@threshold_index]
        promote(:threshold) if threshold && jobs >= threshold && settled? && !held?
      end

      # A refork replacement booting completes its step: the old child stops.
      def mark_booted(_pid, info)
        return if info.booted
        info.booted = true
        @boot_failures = 0 if info.mold_pid
        old = info.replaces
        return unless old && @steps.delete(old)
        info.replaces = nil
        signal(old, 'TERM')
      end

      # Every child process runs and is of the current generation: no
      # promotion, retry or refork in progress.
      def settled?
        !@launcher.stopped? && @promotion.nil? && @retry_trigger.nil? && refork_idle?
      end

      def refork_idle?
        @steps.empty? && @pending_forks.empty? && @deferred_slots.empty? &&
          @children.values.all? { |info| current?(info) && !info.retiring }
      end

      def current?(info)
        info.generation == @generation
      end

      def held?
        @hold_until && monotonic_now < @hold_until
      end

      # Promotes the child process with the most jobs performed, preferring
      # idle ones so promotion doesn't wait for long jobs.
      def promote(trigger)
        return if @launcher.stopped? || @promotion
        pid, info = promotion_candidate
        return logger.warn('No child process to promote to mold') unless pid || trigger != :signal
        return unless pid
        info.promoted = true
        @retry_trigger = nil
        @promotion = {:pid => pid, :trigger => trigger, :at => monotonic_now}
        worker_name, = @launcher.workers[pid]
        logger.info "Promoting child process #{worker_name} (pid #{pid}) to mold after #{info.jobs} job(s) (#{trigger})"
        Delayed.instrument(:mold_promoted, :worker => worker_name, :pid => pid, :jobs => info.jobs, :trigger => trigger)
        signal(pid, 'URG')
      end

      def promotion_candidate
        @children.select { |_, info| promotable?(info) }.max_by { |_, info| [info.busy.zero? ? 1 : 0, info.jobs] }
      end

      def promotable?(info)
        info.booted && !(info.retiring || info.promoted || info.unsafe || info.orphaned)
      end

      # SIGURG is ignored while a promotion or refork is in progress, so
      # retired molds don't pile up; a pending retry runs once due.
      def handle_promotion_requests
        requested = @promote_requested
        @promote_requested = false
        if requested
          return logger.warn('Received SIGURG while a promotion or refork is in progress; ignoring it') if @promotion || !refork_idle?
          return promote(:signal)
        end
        promote(@retry_trigger) if @retry_trigger && !held?
      end

      # Exited cleanly: it forked its mold (which may be ready already), and
      # its slot is filled from the mold. Otherwise the promotion failed.
      def promoted_exited(pid, status)
        refilled = @refilled_promotions.delete(pid)
        current_promotion_exited(pid, status) if @promotion && @promotion[:pid] == pid
        return :retiring if refilled
        :promoted if status.success?
      end

      def current_promotion_exited(pid, status)
        return @promotion[:exited_at] = monotonic_now if status.success?
        promotion_failed("Child process (pid #{pid}) promoted to mold exited with #{status}, forking no mold")
      end

      def mold_forked(child_pid, mold_pid)
        return if @molds[mold_pid] == :active # Its "m" came first.
        if promoting?(child_pid)
          @promotion[:mold_pid] = mold_pid
          @molds[mold_pid] ||= :promoted
        else
          abandon(mold_pid)
        end
      end

      def mold_ready(mold_pid, child_pid)
        return if @molds[mold_pid] == :active
        return abandon(mold_pid) unless promoting?(child_pid) && [nil, :promoted].include?(@molds[mold_pid])
        activate(mold_pid)
      end

      def promoting?(child_pid)
        !@launcher.stopped? && @promotion && @promotion[:pid] == child_pid
      end

      # A mold that isn't the current promotion's: it has forked no child.
      def abandon(mold_pid)
        @molds[mold_pid] = :abandoned
        signal(mold_pid, 'KILL')
      end

      def activate(mold_pid)
        trigger = @promotion[:trigger]
        @refilled_promotions.delete(@promotion[:pid]) unless @promotion[:refilled]
        @promotion = nil
        @threshold_index += 1 if trigger == :threshold
        @hold_until = nil
        retire(@active_mold) if @active_mold
        @molds[mold_pid] = :active
        @active_mold = mold_pid
        @active_since = monotonic_now
        @boot_failures = 0
        @generation += 1
        @pss_before = total_pss_mb
        logger.info "Mold (pid #{mold_pid}) ready; reforking child processes from it (generation #{@generation}#{pss_note(@pss_before)})"
        Delayed.instrument(:mold_activated, :pid => mold_pid, :generation => @generation, :pss_mb => @pss_before)
      end

      def retire(mold_pid)
        @molds[mold_pid] = :retired
        logger.info "Retired mold (pid #{mold_pid}); #{@reaps_orphans ? 'its child processes carry on' : 'it exits once its child processes have'}"
        Delayed.instrument(:mold_retired, :pid => mold_pid)
        signal(mold_pid, 'URG')
      end

      def promotion_failed(reason)
        trigger = @promotion[:trigger]
        mold = @promotion[:mold_pid]
        @promotion = nil
        abandon(mold) if mold && @molds[mold] == :promoted
        retry_promotion(trigger, reason)
        refill_deferred_slots
      end

      # Back-off doubling per failure in a row. A threshold promotion is
      # retried by the next ping past it; others are retried as such.
      def retry_promotion(trigger, reason)
        @failures += 1
        delay = [retry_delay_unit * 2**(@failures - 1), MAX_RETRY_DELAY].min
        @hold_until = monotonic_now + delay
        @retry_trigger = trigger unless trigger == :threshold
        logger.warn "#{reason}; promoting a new mold in #{delay}s"
      end

      def mold_forked_child(mold_pid, pid, index)
        entry = @pending_forks.delete(index)
        unless entry
          @early_boots.delete(pid)
          logger.warn "Stopping child process (pid #{pid}) forked by mold (pid #{mold_pid}) after the parent gave up on it"
          return signal(pid, 'TERM')
        end
        @launcher.child_started(@launcher.child_name(index), pid, entry[:options], entry[:spawn].merge(:mold_pid => mold_pid))
      end

      def mold_fork_failed(mold_pid, index, errno)
        entry = @pending_forks.delete(index)
        return unless entry
        logger.warn "Mold (pid #{mold_pid}) could not fork child process #{index} (errno #{errno}); forking it from the parent"
        count_boot_failure(nil)
        @launcher.start_child_safely(index, entry[:options], entry[:spawn])
      end

      def mold_reaped_child(mold_pid, pid, exitstatus, termsig)
        info = @children[pid]
        return @early_boots.delete(pid) unless info # Never recorded (e.g. given up on).
        return unless info.mold_pid == mold_pid # Not that mold's (pid reused).
        @launcher.handle_exit(pid, ReportedStatus.new(pid, exitstatus, termsig))
      end

      # Without a subreaper, molds aren't this process's children: poll them.
      def check_molds
        @molds.dup.each_key { |pid| mold_exited(pid) unless ProcessUtil.alive?(pid) }
      end

      def mold_exited(pid)
        role = @molds.delete(pid)
        @children.each_value { |info| info.orphaned = true if info.mold_pid == pid } unless @reaps_orphans
        case role
        when :active then lose_active_mold(pid, 'exited')
        when :promoted then promoted_mold_exited(pid)
        when :retired then logger.info "Retired mold (pid #{pid}) exited"
        end
      end

      def promoted_mold_exited(pid)
        promotion_failed("Mold (pid #{pid}) exited before it was ready") if @promotion && @promotion[:mold_pid] == pid
      end

      # Pending forks are forked here, and another promotion replaces it.
      def lose_active_mold(pid, reason)
        @active_mold = nil
        abort_refork
        return fork_pending_from_parent if @launcher.stopped?
        logger.warn "Mold (pid #{pid}) #{reason}; forking child processes from the parent until a new mold is ready"
        fork_pending_from_parent
        retry_promotion(:mold_lost, "Lost mold (pid #{pid})")
      end

      def fork_pending_from_parent
        @pipes.drain_fork_requests
        pending = @pending_forks.sort_by(&:first)
        @pending_forks.clear
        pending.each { |index, entry| @launcher.start_child_safely(index, entry[:options], entry[:spawn]) }
      end

      # Old children keep their slots; replacements are dropped or stopped.
      def abort_refork
        @steps.each_key { |old| @children[old]&.retiring = false }
        @pending_forks.delete_if { |_, entry| @steps.key?(entry[:spawn][:replaces_pid]) }
        @steps.each_value do |replacement|
          next unless replacement && @children[replacement]
          @children[replacement].retiring = true # Not replaced.
          signal(replacement, 'TERM')
        end
        @steps.clear
      end

      # A replacement that died before booting: the old child keeps its slot.
      def refork_step_failed(info)
        old = info.replaces
        return false unless old && @steps.delete(old)
        @children[old]&.retiring = false
        logger.warn "Child process replacing pid #{old} died before booting; keeping pid #{old}"
        true
      end

      def count_boot_failure(pid)
        @boot_failures = @boot_failures.to_i + 1
        return unless @active_mold && @boot_failures >= BOOT_FAILURE_LIMIT
        mold = @active_mold
        logger.error "#{@boot_failures} child processes forked by mold (pid #{mold}) failed to start in a row" \
                     "#{" (last: pid #{pid})" if pid}; stopping it"
        @boot_failures = 0
        abandon(mold)
        lose_active_mold(mold, 'is broken')
      end

      # Without a subreaper, children of a dead mold stop by themselves
      # (Process.ppid changes); the parent can't wait for them, so it polls.
      def check_orphans
        gone = @children.select { |pid, info| info.mold_pid && !@molds.key?(info.mold_pid) && !ProcessUtil.alive?(pid) }.keys
        gone.each { |pid| @launcher.handle_exit(pid, ReportedStatus.new(pid, nil, nil)) }
      end

      def check_timeouts
        check_pending_forks
        check_boot_timeouts
        check_promotion
        abandon_pending_forks if @launcher.stopped?
        @early_boots.delete_if { |_, at| monotonic_now - at > boot_timeout }
        @failures = 0 if @failures > 0 && @active_mold && monotonic_now - @active_since >= MOLD_STABLE_UPTIME
      end

      # A hung mold is killed (it runs no jobs).
      def check_pending_forks
        return if @pending_forks.empty? || !@active_mold
        oldest = @pending_forks.values.map { |entry| entry[:at] }.min
        return if monotonic_now - oldest < MOLD_FORK_TIMEOUT
        mold = @active_mold
        abandon(mold)
        lose_active_mold(mold, "did not fork a child process within #{MOLD_FORK_TIMEOUT}s; killed it")
      end

      def check_boot_timeouts
        @children.each do |pid, info|
          next if info.booted || monotonic_now - info.started_at < boot_timeout
          logger.warn "Child process (pid #{pid}) did not start within #{boot_timeout}s; killing it"
          info.started_at = monotonic_now # Killed once.
          signal(pid, 'KILL')
        end
      end

      def check_promotion
        return unless @promotion
        return refill_draining_slot if !@promotion[:exited_at] && !@promotion[:refilled] && monotonic_now - @promotion[:at] >= drain_deadline
        return unless promotion_overdue?
        promotion_failed("Child process (pid #{@promotion[:pid]}) promoted to mold, but no mold became ready")
      end

      def promotion_overdue?
        exited_at = @promotion[:exited_at]
        return false unless exited_at
        waited = monotonic_now - exited_at
        waited >= MOLD_READY_TIMEOUT || (waited >= PROMOTION_FORK_TIMEOUT && !@promotion[:mold_pid])
      end

      # A promoted child stuck behind a long job: its slot is refilled now.
      def refill_draining_slot
        pid = @promotion[:pid]
        @promotion[:refilled] = true
        @refilled_promotions << pid
        _, options = @launcher.workers[pid]
        logger.warn "Child process (pid #{pid}) promoted to mold is still finishing its jobs after #{drain_deadline}s; refilling its slot"
        @launcher.add_worker_safely(options, pid) if options
      end

      # A stopping mold forks nothing more.
      def abandon_pending_forks
        return if @pending_forks.empty?
        @pipes.drain_fork_requests
        @pending_forks.clear
      end

      # Up to REFORK_SHARE of the child processes at once, idle ones first:
      # each replacement is forked from the active mold, and the child it
      # replaces is stopped once it boots (see #mark_booted).
      def advance_refork
        return if @launcher.stopped? || @promotion || !@active_mold
        refill_deferred_slots
        start_refork_steps
        refork_completed if @refork_generation != @generation && refork_idle?
      end

      def start_refork_steps
        while @steps.size < refork_batch && (old_pid = next_to_refork)
          refork(old_pid)
        end
      end

      def refork_batch
        [(@children.size * REFORK_SHARE).ceil, 1].max
      end

      def next_to_refork
        @children.select { |_, info| !current?(info) && !info.retiring && !info.promoted && info.booted }.
          min_by { |_, info| [info.busy, info.generation] }&.first
      end

      def refork(old_pid)
        worker_name, options = @launcher.workers[old_pid]
        return unless options
        @children[old_pid].retiring = true
        @steps[old_pid] = nil
        logger.info "Reforking child process #{worker_name} (pid #{old_pid}) from mold (pid #{@active_mold})"
        @launcher.add_worker_safely(options, old_pid)
      end

      def refork_completed
        @refork_generation = @generation
        pss = total_pss_mb
        logger.info "Reforked every child process from mold (pid #{@active_mold}), generation #{@generation}#{pss_note(pss, @pss_before)}"
        Delayed.instrument(:mold_refork_completed, :pid => @active_mold, :generation => @generation, :pss_mb => pss, :pss_mb_before => @pss_before)
      end

      def refill_deferred_slots
        until @deferred_slots.empty? || @launcher.stopping?
          options, replaces_pid = @deferred_slots.shift
          @launcher.add_worker_safely(options, replaces_pid)
        end
      end

      # Total PSS of the child processes and molds, in MB (Linux), or nil.
      def total_pss_mb
        sizes = (@launcher.workers.keys + @molds.keys).map { |pid| ProcessUtil.pss_kb(pid) }.compact
        (sizes.sum / 1024.0).round if sizes.any?
      end

      def pss_note(pss, before = nil)
        return '' unless pss
        before ? "; PSS #{before} MB -> #{pss} MB" : "; PSS #{pss} MB"
      end

      def signal(pid, signal)
        Process.kill(signal, pid)
      rescue Errno::ESRCH
        nil
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
