require 'set'

module Delayed
  # Runs a worker process: owns one or more Delayed::Workers, each on its own
  # thread, and feeds them jobs. Every worker process (forked, daemonized,
  # rake, or Worker#start) runs exactly one Dispatcher, whatever its thread count.
  #
  # Each poll reserves only as many jobs as there are idle workers (via
  # Delayed::Job.reserve_batch) and hands one job to each, so the database is
  # polled once per cycle regardless of the thread count, and a job is never
  # locked while it waits for a free thread.
  #
  # With Worker.prefetch N, each worker also holds up to N jobs queued behind
  # the one it runs, and starts the next one as soon as it finishes; each
  # poll tops the queues up. Each job a worker holds is locked under one of
  # its slot names (see Worker.slot_name). With Worker.prefetch_dynamic, the
  # queue depth adapts (see #adjust_depth). On shutdown, queued jobs are
  # released unstarted.
  #
  # Lifecycle callbacks:
  # * :loop wraps each poll and yields the Dispatcher.
  # * :execute wraps each worker thread's lifetime and yields the Worker
  #   (so the ClearLocks plugin releases every worker's locks on exit).
  # * :perform, :error and :failure yield the Worker running the job.
  #
  # Queue and priority settings are process-wide (class-level settings of
  # Delayed::Worker), so all threads of a process work the same queues.
  class Dispatcher # rubocop:disable Metrics/ClassLength
    include Logging

    # Exceptions raised into worker threads to interrupt their jobs on
    # shutdown (see #work).
    SHUTDOWN_INTERRUPTS = [ShutdownInterrupt, SignalException].freeze

    # Stops one run's lock heartbeat thread (see #start_lock_heartbeat).
    HeartbeatControl = Struct.new(:mutex, :cond, :stopped)
    DEFER_SHUTDOWN_INTERRUPTS = SHUTDOWN_INTERRUPTS.to_h { |klass| [klass, :never] }.freeze
    ALLOW_SHUTDOWN_INTERRUPTS = SHUTDOWN_INTERRUPTS.to_h { |klass| [klass, :immediate] }.freeze

    # Give up (raising FatalBackendError) after this many consecutive
    # failures to reserve jobs.
    MAX_FAILED_RESERVATIONS = 10

    # The lock heartbeat gives up after this many consecutive heartbeats
    # ended by an error other than a StandardError (e.g. NoMemoryError).
    MAX_HEARTBEAT_CRASHES = 5

    # Seconds a stopping dispatcher waits for the lock heartbeat thread to
    # finish (e.g. a lock refresh under way) before leaving it behind.
    HEARTBEAT_STOP_TIMEOUT = 5

    # Log throughput at least this often while the queue stays busy.
    REPORT_EVERY = 100

    # Seconds to wait for interrupted jobs to stop before giving up on them.
    INTERRUPT_GRACE = 5

    # How often (in seconds) a supervised worker checks that its parent
    # process is still alive, even while all its threads are busy.
    SUPERVISOR_CHECK_INTERVAL = 1

    # Runs the block with shutdown interrupts let in: they are deferred
    # everywhere else in worker threads (see #work). Backend::Base#invoke_job
    # wraps a job's #perform in it. Outside of worker threads (e.g. Worker#work_off), where
    # nothing defers them, it changes nothing.
    def self.interruptible(&block)
      return yield unless interrupt_masking?
      Thread.handle_interrupt(ALLOW_SHUTDOWN_INTERRUPTS, &block)
    end

    # Whether the current thread is a dispatcher's worker thread (see #work).
    def self.worker_thread?
      !!Thread.current[:delayed_job_worker_thread]
    end

    # Runs the block with shutdown interrupts deferred (see #work).
    def self.deferring_interrupts(&block)
      return yield unless interrupt_masking?
      Thread.handle_interrupt(DEFER_SHUTDOWN_INTERRUPTS, &block)
    end

    # Whether this Ruby can defer interrupts (Thread.handle_interrupt and
    # Thread.pending_interrupt?). Without, shutdown interrupts are let into
    # worker threads at any time, as they were before deferring them.
    def self.interrupt_masking?
      Thread.respond_to?(:handle_interrupt) && Thread.respond_to?(:pending_interrupt?)
    end

    attr_reader :workers, :name_prefix

    # Pid of the parent process supervising this one (the forking launcher),
    # or nil. A supervised dispatcher stops when its parent goes away, e.g.
    # when the launcher is SIGKILLed, instead of running on as an orphan.
    attr_accessor :supervisor_pid

    # Options are those of Delayed::Worker, plus:
    # * :threads - number of workers (threads) to run (default 1)
    # * :workers - run these workers instead of building new ones
    # * :supervisor_pid - see #supervisor_pid
    # * :procline - the process' name, e.g. "delayed_job.0": while running,
    #   the dispatcher keeps the process title ($0) up to date with it, e.g.
    #   "delayed_job.0: 3/4 busy, queues=*" (see #procline). Set by the
    #   launchers, which run each dispatcher in a process of its own.
    def initialize(options = {})
      @quiet = options.key?(:quiet) ? options[:quiet] : true
      @workers = options[:workers] || build_workers(options)
      raise ArgumentError, 'threads must be 1 or greater' if @workers.empty?
      @workers.each { |worker| worker.dispatcher = self }
      @supervisor_pid = options[:supervisor_pid]
      @procline_name = options[:procline]
      @stopped = false
      @quit = false
      @stop_requested_at = nil

      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @inboxes = {}
      @slots = {} # worker => the names (Workers) it locks its jobs under
      @slot_owner = {} # slot => worker
      @slot_jobs = {} # slot => job it holds (queued or running)
      @slot_refreshed = {} # slot => when the heartbeat last refreshed its job's lock (monotonic)
      @running_slot = {} # worker => slot of the job it is running
      @dead = [] # workers whose thread crashed: no more jobs for them
      @prefetch = 0
      # The queue depth (see #adjust_depth). Only the dispatcher's thread
      # writes it; others (the jobs_reserved event, procline) just read it.
      @depth = 0
      @threads = []
      @running = {} # thread => job it is running
      # worker => [job it is running, when it started, its time limit, its
      # log label, whether it was reported as overrun (see #report_overrun)]
      @jobs_started = {}
      @events = 0
      @thread_error = nil
      @failed_reserve_count = 0
      reset_stats
    end

    def thread_count
      workers.size
    end

    def name
      Worker.default_name(name_prefix)
    end

    def name_prefix=(prefix)
      @name_prefix = prefix
      workers.each { |worker| worker.name_prefix = prefix }
    end

    # Installs signal traps and runs until stopped. `pending_signals` are
    # signals the process received before it could install them (see
    # Launcher::Forking#fork_worker); they are handled first.
    def start(pending_signals = [])
      trap_signals
      pending_signals.each { |signal| handle_pending_signal(signal) }
      run
    end

    # Runs until stopped, or with Worker.exit_on_complete until no job is
    # left, without installing signal traps. Running jobs are allowed to
    # finish before returning.
    def run
      say thread_count > 1 ? "Starting job worker with #{thread_count} threads" : 'Starting job worker'
      warn_if_connection_pool_too_small
      Delayed.instrument(:process_started, process_payload)
      error = nil
      begin
        with_lock_heartbeat do
          start_threads
          poll_loop
        rescue Exception => error # rubocop:disable Lint/RescueException
          # A worker thread's crash was reported by the thread itself.
          thread_error(error, 'Dispatcher') unless stopping_error?(error)
          raise
        ensure
          stop_threads(error)
        end
      ensure
        Delayed.instrument(:process_stopped, process_payload.merge(:error => error || @thread_error))
      end
    end

    # Runs up to `num` jobs inline on the calling thread with the given worker
    # (no threads, no :loop callbacks), stopping early when no job is
    # available or the worker is stopped. Returns [succeeded, failed] counts.
    def work_off(num = 100, worker = workers.first)
      success = 0
      failure = 0
      with_lock_heartbeat do
        num.times do
          _, job = reserve([worker]).first
          break unless job
          untrack_job_after(worker) { worker.perform_job(job) } ? success += 1 : failure += 1
          break if worker.stop?
        end
      end
      [success, failure]
    end

    # Stops polling. Running jobs are allowed to finish, for at most
    # Worker.shutdown_timeout seconds if set; then they are interrupted and
    # released (see #quit). Safe to call from a signal trap.
    def stop
      @stop_requested_at ||= monotonic_now
      @stopped = true
      wake_up
    end

    def stop?
      @stopped
    end

    # Stops at once: interrupts running jobs with Delayed::ShutdownInterrupt
    # and releases them, unlocked and with their attempts unchanged, for
    # another worker to run. Safe to call from a signal trap.
    def quit
      @quit = true
      stop
    end

    def quit?
      @quit
    end

    # The process title while running: the :procline name, the state (busy
    # threads, or stopping/quitting) and the queues, e.g.
    # "delayed_job.0: 3/4 busy, queues=mail,sms".
    def procline
      state = if quit? then 'quitting, '
      elsif stop? then 'stopping, '
      end
      busy, held = synchronize { [busy_count, @slot_jobs.size] }
      "#{@procline_name}: #{state}#{busy}/#{thread_count} busy#{prefetch_state(held - busy)}, queues=#{queue_names}"
    end

    # Jobs queued behind running ones, and the queue depth if it adapts.
    def prefetch_state(queued)
      return '' unless @prefetch > 0
      depth = ", depth #{@depth}/#{@prefetch}" if Worker.prefetch_dynamic
      ", #{queued} queued#{depth}"
    end

    # Called by Worker#run as the job's own code starts, with its time limit
    # in seconds (as Worker#run times it out): records them for the lock
    # heartbeat (see #heartbeat_names), with the job's log label. Worker#run
    # works them out on the worker's thread, inside the job's :perform
    # callbacks (which may set up what deserializing it needs), so the
    # heartbeat thread never calls into the job.
    def job_timed(worker, job, limit)
      limit = nil unless limit > 0 # No timeout under a second.
      label = limit && job_label(job)
      synchronize { @jobs_started[worker] = [job, monotonic_now, limit, label] }
    end

  private

    def build_workers(options)
      # nil means the default, as in Launcher::Base#threads.
      count = Integer(options[:threads] || 1)
      Array.new([count, 0].max) do |index|
        # Worker.new resets the global lifecycle, so all workers are built
        # here, before any thread starts.
        Worker.new(options).tap { |worker| worker.thread_index = index if count > 1 }
      end
    end

    # Signals INT and TERM stop the dispatcher once running jobs finish (or
    # Worker.shutdown_timeout passes), or raise a SignalException, see
    # Worker.raise_signal_exceptions. QUIT stops it at once, see #quit.
    def trap_signals
      trap('TERM') do
        first = !stop?
        Thread.new { say 'Exiting...' } if first
        stop
        raise_signal('TERM') if first && Worker.raise_signal_exceptions
      end

      trap('INT') do
        first = !stop?
        Thread.new { say 'Exiting...' } if first
        stop
        raise_signal('INT') if first && Worker.raise_signal_exceptions && Worker.raise_signal_exceptions != :term
      end

      trap_quit
    end

    # Raises the signal (see Worker.raise_signal_exceptions) in the main
    # thread, where the process runs: CRuby runs traps there, but JRuby runs
    # them on a thread of their own.
    def raise_signal(signal)
      raise SignalException, signal if Thread.current == Thread.main
      Thread.main.raise(SignalException, signal)
    end

    # QUIT can't be trapped everywhere: the JVM (JRuby) reserves it for
    # thread dumps. Without it, TERM and INT still stop the dispatcher.
    def trap_quit
      return unless Signal.list.key?('QUIT')
      Delayed.check_trappable!('QUIT')
      trap('QUIT') do
        Thread.new { say 'Received SIGQUIT: interrupting running jobs and exiting...' }
        quit
      end
    rescue ArgumentError => error
      say "WARNING: cannot trap SIGQUIT on this platform (#{error.message}); use TERM or INT to stop", 'warn'
    end

    # Acts on a signal received before the traps were installed, as its trap
    # would, except that no SignalException is raised: nothing is running yet.
    def handle_pending_signal(signal)
      say "Received SIG#{signal} while starting", 'warn'
      signal == 'QUIT' ? quit : stop
    end

    def poll_loop
      until stop?
        update_procline
        raise_thread_error
        break if supervisor_gone?
        free, seen = snapshot
        polled_at = monotonic_now # No later than the jobs' locks were taken.
        reserved = free.empty? ? [] : poll(free)
        # A signal exception (see Worker.raise_signal_exceptions) may stop
        # this part way: jobs not handed over yet stay locked under their
        # worker's names, which are cleared as its thread exits (see
        # Plugins::ClearLocks and #clear_slot_locks).
        reserved.each { |slot, job| dispatch(slot, job, polled_at) }
        deeper = adjust_depth(free.size, reserved.size)

        if reserved.empty? && in_flight.zero?
          report
          # A job that finished during the poll may have enqueued another
          # after the poll looked: then poll again (at once, see
          # #wait_before_next_poll) before concluding no job is left.
          if Worker.exit_on_complete && !finished_since?(seen)
            say 'No more jobs available. Exiting'
            break
          end
        elsif completed >= REPORT_EVERY
          report
        end

        update_procline
        # Fewer jobs than idle workers may not mean the queue ran dry, with
        # a backend whose batch reservation can lose candidates to other
        # processes: poll again at once then.
        # Likewise after the queue depth grew: there are free slots to fill.
        next if deeper || repoll_after?(reserved, free)

        # Fewer jobs than free slots: the queue ran dry, so idle workers
        # wait at most sleep_delay for new jobs (not until a busy one frees up).
        wait_before_next_poll(seen, !free.empty? && reserved.size < free.size)
      end
      raise_thread_error
    end

    # Whether to poll again at once: after a partial batch (some jobs, but
    # fewer than free slots), if the backend says jobs may be left (see
    # Delayed::Job.partial_batch_may_leave_jobs?).
    def repoll_after?(reserved, free)
      return false if reserved.empty? || reserved.size >= free.size
      Delayed::Job.respond_to?(:partial_batch_may_leave_jobs?) && Delayed::Job.partial_batch_may_leave_jobs?
    end

    # Waits until a worker frees up (or dies) or the dispatcher is stopped,
    # and, if the queue ran dry, at most sleep_delay seconds so that newly
    # enqueued jobs get picked up. A supervised dispatcher also checks on its
    # parent every SUPERVISOR_CHECK_INTERVAL seconds meanwhile - without
    # polling for jobs, so the database is still polled every sleep_delay.
    def wait_before_next_poll(seen, queue_dry)
      deadline = monotonic_now + sleep_delay if queue_dry
      loop do
        remaining = deadline && deadline - monotonic_now
        return if remaining && remaining <= 0
        timeout = [remaining, (SUPERVISOR_CHECK_INTERVAL if supervisor_pid)].compact.min
        return if wait_for_event(seen, timeout)
        return if supervisor_gone?
      end
    end

    # Worker.sleep_delay, or the default if it isn't set (e.g. nil, from
    # an option that failed to parse).
    def sleep_delay
      Worker.sleep_delay || Worker::DEFAULT_SLEEP_DELAY
    end

    # Whether the parent process went away (this process was re-parented).
    # Stops the dispatcher gracefully if so: running jobs finish (or are
    # interrupted after Worker.shutdown_timeout), then the process exits.
    def supervisor_gone?
      return false unless supervisor_pid && Process.ppid != supervisor_pid
      say "Parent process #{supervisor_pid} is gone; stopping", 'warn'
      stop
      true
    end

    def poll(free)
      reserved = []
      Worker.lifecycle.run_callbacks(:loop, self) { reserved = reserve(free) }
      reserved
    end

    # With Worker.prefetch_dynamic, after a poll that asked for jobs: one
    # level deeper (up to Worker.prefetch) if it got all it asked for, back
    # to 0 (only idle workers) if it got fewer, as the queue ran dry. Jobs
    # already queued stay queued. Returns whether the depth grew.
    def adjust_depth(requested, reserved)
      return false unless Worker.prefetch_dynamic && requested > 0
      synchronize do
        previous = @depth
        @depth = reserved < requested ? 0 : [@depth + 1, @prefetch].min
        @depth > previous
      end
    end

    # Reserves up to one job per given worker. On error, lets the backend
    # recover and returns no jobs, until too many consecutive failures.
    def reserve(workers)
      reserved = Delayed.instrument(:jobs_reserved, :dispatcher => name, :requested => workers.size, :depth => @depth) do |payload|
        payload[:reserved] = 0
        polling { Delayed::Job.reserve_batch(workers, Worker.lock_expiry) }.tap { |r| payload[:reserved] = r.size }
      end
      @failed_reserve_count = 0
      reserved
    rescue SignalException, SystemExit
      # Stopping (see Worker.raise_signal_exceptions), not a failed reservation.
      raise
    rescue ::Exception => error # rubocop:disable Lint/RescueException
      say "Error while reserving job: #{error}"
      thread_error(error, 'Reservation')
      Delayed::Job.recover_from(error)
      @failed_reserve_count += 1
      raise FatalBackendError if @failed_reserve_count >= MAX_FAILED_RESERVATIONS
      []
    end

    # Runs the block while a heartbeat thread refreshes the locks of this
    # dispatcher's workers every Worker.lock_heartbeat_interval seconds (see
    # Worker.lock_heartbeat_interval), if enabled and supported.
    def with_lock_heartbeat
      return yield unless start_lock_heartbeat
      begin
        yield
      ensure
        stop_lock_heartbeat
      end
    end

    def start_lock_heartbeat
      return false if Worker.lock_heartbeat_interval.nil?
      Worker.validate_lock_heartbeats!
      unless Delayed::Job.lock_heartbeats?
        say "WARNING: lock heartbeats are enabled, but #{Delayed::Job.name} does not support them; " \
            'locks expire after max_run_time', 'warn'
        return false
      end
      @last_beat_at = monotonic_now
      # Its own, not shared with a later run's heartbeat: one left behind
      # (see #stop_lock_heartbeat) must not come back to life.
      control = @heartbeat_control = HeartbeatControl.new(Mutex.new, ConditionVariable.new, false)
      @heartbeat = spawn_thread('delayed_job heartbeat') { lock_heartbeat_loop(Worker.lock_heartbeat_interval, control) }
      true
    end

    # Stops the heartbeat thread. One stuck in a lock refresh (e.g. a
    # database call that hangs) is left behind after HEARTBEAT_STOP_TIMEOUT
    # seconds rather than keeping the process from exiting; it stops at its
    # next beat if it ever returns.
    def stop_lock_heartbeat
      control = @heartbeat_control
      control.mutex.synchronize do
        control.stopped = true
        control.cond.broadcast
      end
      return if @heartbeat.join(HEARTBEAT_STOP_TIMEOUT)
      say "Lock heartbeat did not stop within #{HEARTBEAT_STOP_TIMEOUT}s (a lock refresh may be stuck); " \
          'not waiting for it', 'warn'
    end

    # #heartbeat handles StandardErrors. Anything else (e.g. NoMemoryError)
    # is reported and the heartbeat carries on at the next interval, so the
    # locks of running jobs stay alive - until MAX_HEARTBEAT_CRASHES in a
    # row, when it gives up: the locks then expire after lock_timeout, and
    # other workers may take those jobs over. Signals and exits end it at once.
    def lock_heartbeat_loop(interval, control = @heartbeat_control)
      crashes = 0
      loop do
        stopped = control.mutex.synchronize do
          control.cond.wait(control.mutex, interval) unless control.stopped
          control.stopped
        end
        break if stopped
        begin
          heartbeat
          crashes = 0
        rescue SignalException, SystemExit
          raise
        rescue Exception => error # rubocop:disable Lint/RescueException
          crashes += 1
          thread_error(error, 'Lock heartbeat')
          if crashes >= MAX_HEARTBEAT_CRASHES
            say "Lock heartbeat stopped after #{crashes} consecutive failures (last: #{error.class}: #{error.message}); " \
                "the locks of running jobs are no longer refreshed and expire after lock_timeout (#{Worker.lock_timeout}s)", 'error'
            break
          end
          say "Lock heartbeat failed with #{error.class}: #{error.message}; retrying in #{interval}s " \
              "(#{crashes}/#{MAX_HEARTBEAT_CRASHES})", 'error'
        end
      end
    end

    # The workers whose locks the heartbeat refreshes: all of them, except
    # those running a job for longer than its max_run_time. Such a job
    # should have been interrupted by its timeout; one that wasn't (e.g.
    # blocked in native code) would otherwise hold its lock for as long as
    # the process lives. Its lock now expires after lock_timeout, and
    # another worker can run the job - as without heartbeats, where locks
    # expire after max_run_time.
    def heartbeat_names
      now = monotonic_now
      overrun = synchronize do
        @jobs_started.select { |_worker, (_job, started, limit)| limit && now - started > limit }
      end
      overrun.each { |worker, (job, _, limit, label)| report_overrun(worker, job, limit, label) }
      return (workers - overrun.keys).map(&:name) if @prefetch.zero?
      # The jobs queued behind a stuck one would wait as long as it runs,
      # their locks refreshed all along: release them for other workers (no
      # more are queued behind it, see #free_slots).
      release_queued(overrun.keys.map { |worker| @inboxes[worker] }.compact, :stuck)
      # With prefetch, jobs are only locked under slot names: those holding
      # a job (running or queued), but an overrun one.
      synchronize do
        stuck = overrun.keys.map { |worker| @running_slot[worker] }
        (@slot_jobs.keys - stuck).map(&:name)
      end
    end

    # Records that the locks of the `held` jobs were refreshed at `beat_at`,
    # for those still in the same slot (see #lock_time_left).
    def beaten(held, beat_at)
      synchronize do
        @last_beat_at = beat_at
        held.each { |slot, job| @slot_refreshed[slot] = beat_at if @slot_jobs[slot].equal?(job) }
      end
    end

    # Logs, once per job, that its lock is no longer refreshed: marks its
    # #job_timed entry, if the job still runs (it may have ended since the
    # heartbeat looked).
    def report_overrun(worker, job, limit, label)
      first = synchronize do
        started = @jobs_started[worker]
        next false unless started && started[0].equal?(job) && !started[4]
        started[4] = true
      end
      return unless first
      # Published on the lock heartbeat thread: :job_name was worked out on
      # the job's own thread. Read only plain fields (id, queue) of :job.
      Delayed.instrument(:job_stuck, :job => job, :job_name => label, :worker => worker.name,
                                     :max_run_time => limit, :lock_timeout => Worker.lock_timeout)
      worker.say(format('%s has run for longer than its max_run_time (%ds) without stopping; no longer ' \
                        'refreshing its lock, so another worker may run it after lock_timeout (%gs)',
                        label, limit, Worker.lock_timeout), 'error')
    end

    # Runs the block (the worker's job), then forgets when the job started,
    # its time limit and any overrun report (see #job_timed).
    def untrack_job_after(worker)
      yield
    ensure
      synchronize { @jobs_started.delete(worker) }
    end

    # How Worker#job_say names the job.
    def job_label(job)
      "Job #{job.name} (id=#{job.id})#{" (queue=#{job.queue})" if job.queue}"
    rescue StandardError
      "Job (id=#{job.id})"
    end

    # Refreshes the locks of the workers that need it. Errors are logged and
    # the next heartbeat tries again; the locks only expire if heartbeats
    # keep failing for lock_timeout seconds.
    def heartbeat
      beat_at = monotonic_now # No later than the locks are refreshed.
      names = heartbeat_names
      return if names.empty?
      # The jobs held under those names now: their locks were taken, so the
      # refresh below reaches them.
      wanted = names.to_set
      held = synchronize { @slot_jobs.select { |slot, _job| wanted.include?(slot.name) } }
      polling { Delayed::Job.touch_locks(names) }
      beaten(held, beat_at)
    rescue StandardError => error
      say "Error while refreshing job locks: #{error.class}: #{error.message}", 'error'
      thread_error(error, 'Lock heartbeat')
    end

    # Recorded one by one: if starting one fails, those already started are
    # still stopped (see #run).
    def start_threads
      build_slots
      @threads = []
      workers.each_with_index do |worker, index|
        inbox = @inboxes[worker] = Inbox.new
        @threads << spawn_thread("delayed_job worker:#{index}") { work(worker, inbox) }
      end
    end

    # A thread that reports its own errors (see #thread_error).
    def spawn_thread(name, &block)
      Thread.new(&block).tap do |thread|
        thread.report_on_exception = false
        thread.name = name
      end
    end

    # Each worker's slots (see Worker.slot_name): with prefetch, one per job
    # it may hold; else just the worker, locking under its own name.
    def build_slots
      Worker.validate_prefetch!
      @prefetch = Worker.prefetch
      @depth = Worker.prefetch_dynamic ? 0 : @prefetch
      workers.each do |worker|
        slots = if @prefetch.zero? then [worker]
        else Array.new(@prefetch + 1) { |index| Worker.named(Worker.slot_name(worker.name, index)) }
        end
        @slots[worker] = slots
        slots.each { |slot| @slot_owner[slot] = worker }
      end
    end

    # Body of each worker thread: runs the jobs it is handed until told to stop.
    #
    # Shutdown raises Delayed::ShutdownInterrupt (and, with
    # Worker.raise_signal_exceptions, the signal) into the threads running
    # jobs. They are only let in while a job's own code runs (see
    # Worker#run and .interruptible): elsewhere they would interrupt the
    # thread's bookkeeping, its :execute callbacks (e.g. ClearLocks), or a
    # job being finished (deleted) - which would then be released and run
    # again.
    def work(worker, inbox)
      Thread.current[:delayed_job_worker_thread] = true
      self.class.deferring_interrupts do
        Worker.lifecycle.run_callbacks(:execute, worker) do
          work_jobs(worker, inbox)
        ensure
          clear_slot_locks(worker)
        end
      end
    rescue *SHUTDOWN_INTERRUPTS
      # Deferred while the thread was exiting and delivered as it left the
      # block above (no job left to interrupt), or a signal raised into a
      # job (see #stop_threads) that escaped it: the process is stopping
      # anyway, so this is no thread crash to report.
      synchronize { @running.delete(Thread.current) }
    rescue Exception => error # rubocop:disable Lint/RescueException
      thread_error(error, 'Worker thread', worker.name)
      synchronize do
        @running.delete(Thread.current)
        retire(worker)
        @thread_error ||= error
        signal_event
      end
    end

    # Runs the jobs handed to the worker until told to stop (see #work).
    def work_jobs(worker, inbox)
      until (item = inbox.pop).equal?(Inbox::EOQ)
        slot, job, reserved_at = item
        discard_stale_interrupts
        next release_unstarted(worker, slot, job) if past_shutdown_deadline? || (@prefetch > 0 && stop?)
        lock_left = lock_time_left(slot, reserved_at)
        next release_unstarted(worker, slot, job, :lock_expired) if lock_left && lock_left <= 0
        run_job(worker, slot, job, lock_left)
      end
    end

    # Runs a job handed to the worker. One interrupted by shutdown (see
    # Worker#run) is released; the thread then carries on with what is
    # left in its inbox (released too, as the dispatcher is stopping).
    def run_job(worker, slot, job, lock_left)
      synchronize do
        @running[Thread.current] = job
        @running_slot[worker] = slot
      end
      result = with_reloader { untrack_job_after(worker) { worker.perform_job(job, lock_left) } }
      synchronize { @running.delete(Thread.current) }
      job_finished(worker, slot, result)
    rescue *SHUTDOWN_INTERRUPTS => error
      synchronize do
        @running.delete(Thread.current)
        @running_slot.delete(worker)
      end
      release_interrupted(worker, job, error, slot)
    end

    # Seconds left (whole, unless under one) before the lock of the job in `slot`, reserved at
    # `reserved_at`, expires - the job must stop by then, or another worker
    # could take it over while it still runs (see Worker#run) - or nil for
    # no limit. The lock was taken as the job was reserved, or last
    # refreshed by the lock heartbeat (see #beaten); it lasts
    # Worker.lock_expiry. No limit:
    # - while the lock heartbeat keeps refreshing locks (see
    #   #heartbeat_alive?), unless the lock already expired;
    # - without heartbeats, for a job that waited less than a second: its
    #   lock lasts as long as it may run.
    def lock_time_left(slot, reserved_at)
      refreshed = synchronize { @slot_refreshed[slot] } || reserved_at
      waited = monotonic_now - refreshed
      left = Worker.lock_expiry - waited
      return left if left <= 0 # Expired.
      return nil if heartbeat_alive?
      return nil if waited < 1 && !Worker.lock_heartbeats?
      left >= 1 ? left.floor : left
    end

    # Whether the lock heartbeat is running and refreshed locks within the
    # last lock_timeout seconds, so it may be relied on to keep a job's lock
    # alive while it runs: not after it gave up (see #lock_heartbeat_loop),
    # nor while a refresh has hung for that long.
    def heartbeat_alive?
      return false unless Worker.lock_heartbeats? && @heartbeat && @heartbeat.alive?
      synchronize { @last_beat_at && monotonic_now - @last_beat_at < Worker.lock_timeout }
    end

    # As the worker's thread exits (also on a crash), with prefetch: clears
    # the locks of its slots, as Plugins::ClearLocks does for its own name,
    # under which it locks no job then. Its queued jobs were released
    # already (see #release_queued); any job still locked under them is
    # left over, e.g. from a release that failed. A thread stuck in a job
    # never gets here, so that job stays locked (see #interrupt_threads).
    def clear_slot_locks(worker)
      return if @prefetch.zero?
      names = @slots[worker].map(&:name)
      with_executor { Delayed::Job.clear_locks_of!(names) }
    rescue StandardError => error
      say "Could not release the jobs of #{worker.name}: #{error.class}: #{error.message}", 'error'
      thread_error(error, 'Releasing interrupted jobs', worker.name)
    end

    # Under the mutex: the worker's thread crashed. Frees its slots (its
    # jobs' locks were cleared as it exited, see #clear_slot_locks) and
    # reserves no more jobs for it.
    def retire(worker)
      @dead << worker
      @running_slot.delete(worker)
      (@slots[worker] || [worker]).each { |slot| free_slot(slot) }
    end

    # Drops shutdown interrupts that arrived after the previous job finished:
    # they were meant for that job, not for the next one. Stops as soon as a
    # pass delivers none, so it can't spin if one stays pending.
    def discard_stale_interrupts
      while stale_interrupt_pending?
        begin
          self.class.interruptible { Thread.pass }
          return # Still pending, yet not delivered: leave it.
        rescue ShutdownInterrupt, SignalException
          nil
        end
      end
    end

    def stale_interrupt_pending?
      return false unless self.class.interrupt_masking? # Nothing is deferred.
      SHUTDOWN_INTERRUPTS.any? { |klass| Thread.pending_interrupt?(klass) }
    end

    # Reports an error outside of a job's own handling (see
    # Worker.on_thread_error); job errors go through the :error lifecycle.
    def thread_error(error, context, worker_name = nil)
      Worker.thread_error(error, :context => context, :dispatcher => name, :worker => worker_name)
    end

    # Runs a polling query (reservation, lock refresh) in the Rails executor,
    # with the backend's query log silenced if Worker.silence_polling.
    def polling(&block)
      return with_executor(&block) unless Worker.silence_polling
      with_executor { Delayed::Job.silence_polling(&block) }
    end

    # Errors that stop a dispatcher without being failures: signals and
    # exits, and a worker thread's crash re-raised here.
    def stopping_error?(error)
      error.is_a?(SignalException) || error.is_a?(SystemExit) || error.equal?(@thread_error)
    end

    # Sets the process title (see #procline) if it changed. Only with the
    # :procline option, and only from the dispatcher's thread.
    def update_procline
      return unless @procline_name
      title = procline
      return if title == @procline_title
      @procline_title = title
      $0 = title
    end

    def queue_names
      queues = Worker.queues
      queues.nil? || queues.empty? ? '*' : queues.join(',')
    end

    def process_payload
      {:dispatcher => name, :pid => Process.pid, :threads => thread_count, :queues => Worker.queues,
       :prefetch => Worker.prefetch, :prefetch_dynamic => !!Worker.prefetch_dynamic}
    end

    # Lets running jobs finish, then waits for every thread to exit. Jobs
    # still running at the shutdown deadline (see #shutdown_deadline) are
    # interrupted and released. If the dispatcher is exiting because of a
    # signal exception (see Worker.raise_signal_exceptions), it is raised in
    # running jobs as well.
    def stop_threads(error)
      # Also when the poll loop ended without #stop (exit_on_complete, a
      # crashed thread): jobs handed over are then released past the
      # shutdown deadline (see #work_jobs), and the procline says stopping.
      @stop_requested_at ||= monotonic_now
      @stopped = true
      update_procline
      late_signal = nil
      begin
        # A late signal exception (see below) is deferred until the threads
        # have all been told to stop: on JRuby, one raised in Queue#push
        # comes out as a ThreadError, and an inbox would be left open.
        self.class.deferring_interrupts do
          release_queued if @prefetch > 0
          @inboxes.each_value(&:close)
        end
        raise_in_threads(error) if error.is_a?(SignalException)
        wait_for_threads
      rescue SignalException => late_signal # rubocop:disable Naming/RescuedExceptionsVariableName -- `error` is the parameter
        # Raised while waiting: on JRuby, signal traps run on a thread of
        # their own, so the trap's stop can end the poll loop before the
        # signal exception reaches this thread (see #raise_signal). Raise
        # it in the running jobs too, as if it had arrived first; then
        # finish stopping (below) and let it propagate.
        raise_in_threads(late_signal)
        wait_for_threads
      end
      if shutdown_deadline
        interrupt_threads(synchronize { @running.keys.select(&:alive?) })
        # Also wait for the threads that weren't running a job: they may
        # still be releasing one handed to them too late (see
        # #release_unstarted), and must run their :execute callbacks (e.g.
        # ClearLocks) before the process exits - which would kill them.
        join_threads(monotonic_now + INTERRUPT_GRACE)
      end
      raise late_signal if late_signal
    end

    # Releases the jobs still queued for workers (with prefetch), unstarted:
    # unlocked, their attempts unchanged, for another worker to run. A job a
    # worker already took is released by the worker itself (see #work).
    QUEUED_RELEASE_REASONS = {
      :shutdown => ['on shutdown', 'shutdown'],
      :stuck => ['queued behind a job that overran its max_run_time', 'stuck job']
    }.freeze

    # Releases the jobs queued in the given inboxes (all of them by
    # default): unlocked, their attempts unchanged, for other workers.
    def release_queued(inboxes = @inboxes.values, reason = :shutdown)
      queued = inboxes.flat_map(&:drain)
      return if queued.empty?
      message, event_reason = QUEUED_RELEASE_REASONS.fetch(reason)
      names = queued.map { |slot, _job| slot.name }
      with_executor { Delayed::Job.clear_locks_of!(names) }
      say "Released #{queued.size} queued job(s) #{message}", reason == :shutdown ? 'info' : 'warn'
      Delayed.instrument(:jobs_released, :workers => names, :count => queued.size, :reason => event_reason)
    rescue StandardError => error
      say "Could not release the queued jobs: #{error.class}: #{error.message}", 'error'
      thread_error(error, 'Releasing interrupted jobs')
    ensure
      slots_done((queued || []).map(&:first))
    end

    def join_threads(deadline)
      @threads.each { |thread| thread.join([deadline - monotonic_now, 0].max) }
    end

    # Raises the signal exception in the threads running a job, to interrupt
    # it. Not in the others: they stop once their inbox is closed, and one that
    # has only just started could be killed before it can run its :execute
    # callbacks (e.g. ClearLocks), leaving its locks behind.
    def raise_in_threads(signal_exception)
      busy = synchronize { @running.keys }
      busy.each { |thread| thread.raise(signal_exception.class, signal_exception.message) if thread.alive? }
    end

    # Waits until every thread exits or the shutdown deadline passes. The
    # deadline is checked again on each wait, so #quit takes effect at once.
    def wait_for_threads
      loop do
        update_procline
        busy = @threads.find(&:alive?)
        break unless busy
        deadline = shutdown_deadline
        remaining = deadline && deadline - monotonic_now
        break if remaining && remaining <= 0
        busy.join(remaining ? [remaining, 0.1].min : 0.1)
      end
    end

    def interrupt_threads(busy)
      return if busy.empty?
      reason = quit? ? 'Quitting' : format('Shutdown timeout of %gs exceeded', Worker.shutdown_timeout)
      say "#{reason}: interrupting #{busy.size} running job(s)", 'warn'
      Delayed.instrument(:jobs_interrupted, :dispatcher => name, :jobs => busy.size, :reason => reason)
      busy.each { |thread| thread.raise(ShutdownInterrupt, reason) }
      deadline = monotonic_now + INTERRUPT_GRACE
      busy.each { |thread| thread.join([deadline - monotonic_now, 0].max) }
      stuck = busy.count(&:alive?)
      return if stuck.zero?
      say format('%<stuck>d job(s) did not stop within %<grace>gs of being interrupted; ' \
                 'leaving them locked until max_run_time expires', :stuck => stuck, :grace => INTERRUPT_GRACE), 'error'
    end

    # When running jobs are interrupted: at once after #quit, else
    # Worker.shutdown_timeout seconds after #stop, else never (nil).
    def shutdown_deadline
      return monotonic_now if quit?
      timeout = Worker.shutdown_timeout
      @stop_requested_at + timeout if timeout
    end

    # Releases a job interrupted by shutdown for another worker to run: its
    # lock is cleared, its attempts and run_at are left as they were - or,
    # with Worker.count_shutdown_interrupts, it is recorded as a failed
    # attempt (rescheduled with back-off, or failed after max_attempts).
    def release_interrupted(worker, job, interrupt, slot)
      release_slot(worker, slot, 'shutdown') do
        if Worker.count_shutdown_interrupts
          worker.job_say(job, 'interrupted by shutdown; counted as a failed attempt', 'warn')
          worker.fail_attempt(job, interrupt)
        else
          worker.job_say(job, 'interrupted by shutdown; released for another worker', 'warn')
        end
      end
    end

    # Runs the block (logging, or counting a failed attempt), then clears
    # the lock of the worker's job in `slot` and publishes jobs_released.
    # An error is reported; the slot is freed whatever happens.
    def release_slot(worker, slot, event_reason)
      yield
      Delayed::Job.clear_locks!(slot.name)
      Delayed.instrument(:jobs_released, :workers => [slot.name], :count => 1, :reason => event_reason)
    rescue StandardError => error
      say "Could not release the jobs of #{slot.name}: #{error.class}: #{error.message}", 'error'
      thread_error(error, 'Releasing interrupted jobs', worker.name)
    ensure
      slots_done([slot])
    end

    def dispatch(slot, job, reserved_at = monotonic_now)
      synchronize { @slot_jobs[slot] = job }
      @inboxes[@slot_owner.fetch(slot, slot)].push(slot, job, reserved_at)
    end

    UNSTARTED_REASONS = {
      :shutdown => ['not started before shutdown', 'shutdown'],
      :lock_expired => ['waited in its queue until its lock expired', 'lock expired in queue']
    }.freeze

    # Releases a job handed to the worker that it never started: unlocked,
    # its attempts unchanged, for another worker to run. Because the process
    # is stopping, or (:lock_expired) because it waited queued for as long
    # as its lock lasts (see #lock_time_left), so it may already have been
    # taken over.
    def release_unstarted(worker, slot, job, reason = :shutdown)
      message, event_reason = UNSTARTED_REASONS.fetch(reason)
      release_slot(worker, slot, event_reason) { worker.job_say(job, "#{message}; released for another worker", 'warn') }
    end

    # Whether the shutdown deadline (see #shutdown_deadline) has passed: jobs
    # are then interrupted, and none is started any more.
    def past_shutdown_deadline?
      deadline = stop? && shutdown_deadline
      deadline ? monotonic_now >= deadline : false
    end

    def job_finished(worker, slot, result)
      synchronize do
        result ? @success += 1 : @failure += 1
        @running_slot.delete(worker)
      end
      slots_done([slot])
    end

    # Under the mutex: the slot's job finished or was released.
    def free_slot(slot)
      @slot_refreshed.delete(slot)
      @slot_jobs.delete(slot)
    end

    # The slots' jobs finished or were released: frees them, and wakes the
    # dispatcher to refill them.
    def slots_done(slots)
      synchronize do
        slots.each { |slot| free_slot(slot) }
        signal_event
      end
    end

    # Waits until a worker finishes a job (or dies), the dispatcher is stopped, or
    # the timeout (if any) expires. `seen` is the event count observed before
    # deciding to wait, so no event can be missed. Returns whether an event
    # happened or the dispatcher was stopped (false if the timeout expired).
    def wait_for_event(seen, timeout)
      synchronize do
        @cond.wait(@mutex, timeout) if @events == seen && !stop?
        @events != seen || stop?
      end
    end

    def signal_event
      @events += 1
      @cond.broadcast
    end

    def wake_up
      synchronize { @cond.broadcast }
    rescue ThreadError
      # A Mutex cannot be locked from within a signal trap, so deliver the
      # wake-up from a separate thread instead.
      Thread.new { wake_up }
    end

    # The free slots to reserve jobs into, and the event count. Slots are
    # taken in rounds: one for each idle worker first (so the first, most
    # urgent jobs start at once), then one more for each worker holding one
    # job, and so on, until each holds up to the queue depth plus the job
    # it runs.
    def snapshot
      synchronize { [free_slots, @events] }
    end

    def free_slots
      # Not behind a job that overran its max_run_time (see #heartbeat_names).
      plan = (workers - @dead - overrun_workers).map do |worker|
        slots = @slots[worker] || [worker]
        held = slots.count { |slot| @slot_jobs.key?(slot) }
        [slots.reject { |slot| @slot_jobs.key?(slot) }, held]
      end
      (0..@depth).each_with_object([]) do |round, free|
        plan.each do |open, held|
          slot = round >= held && open[round - held]
          free << slot if slot
        end
      end
    end

    # Under the mutex: workers running a job reported as overrun.
    def overrun_workers
      @jobs_started.select { |_worker, started| started[4] }.keys
    end

    # Under the mutex: workers holding a job (running it or about to).
    def busy_count
      workers.count { |worker| (@slots[worker] || [worker]).any? { |slot| @slot_jobs.key?(slot) } }
    end

    # Whether a worker finished a job (or died) since the snapshot that
    # observed `seen` events.
    def finished_since?(seen)
      synchronize { @events != seen }
    end

    # Jobs handed to workers and not finished or released yet (running or
    # queued).
    def in_flight
      synchronize { @slot_jobs.size }
    end

    def completed
      synchronize { @success + @failure }
    end

    def report
      success, failure, elapsed = synchronize do
        stats = [@success, @failure, monotonic_now - @stats_started]
        reset_stats
        stats
      end
      count = success + failure
      return if count.zero?
      say format("#{count} jobs processed at %.4f j/s, %d failed", count / elapsed, failure)
    end

    def reset_stats
      @success = 0
      @failure = 0
      @stats_started = monotonic_now
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def raise_thread_error
      error = synchronize { @thread_error }
      raise error if error
    end

    def synchronize(&block)
      @mutex.synchronize(&block)
    end

    # Each job runs inside the Rails reloader, which reloads code in
    # development and manages database connections safely across threads.
    def with_reloader(&block)
      app = rails_application
      app && app.respond_to?(:reloader) ? app.reloader.wrap(&block) : yield
    end

    def with_executor(&block)
      app = rails_application
      app && app.respond_to?(:executor) ? app.executor.wrap(&block) : yield
    end

    def rails_application
      ::Rails.application if defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application
    end

    # Warns if the Active Record connection pool can't serve every thread
    # that queries at once: each worker thread, the dispatcher thread, and
    # the lock heartbeat thread when heartbeats are on.
    def warn_if_connection_pool_too_small
      return unless defined?(::ActiveRecord::Base)
      pool_size = ::ActiveRecord::Base.connection_pool.size
      needed = connections_needed
      return if pool_size >= needed
      say "WARNING: database connection pool size (#{pool_size}) is smaller than the #{needed} connections " \
          "this worker process may use at once (#{connection_users}). Increase the pool size in " \
          'config/database.yml.', 'warn'
    rescue StandardError
      nil
    end

    def connections_needed
      thread_count + 1 + (Worker.lock_heartbeats? ? 1 : 0)
    end

    def connection_users
      users = ["#{thread_count} job thread(s)", 'the dispatcher']
      users << 'the lock heartbeat' if Worker.lock_heartbeats?
      users.join(', ')
    end
  end
end
