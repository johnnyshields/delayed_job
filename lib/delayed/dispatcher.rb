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
  # Lifecycle callbacks:
  # * :loop wraps each poll and yields the Dispatcher.
  # * :execute wraps each worker thread's lifetime and yields the Worker
  #   (so the ClearLocks plugin releases every worker's locks on exit).
  # * :perform, :error and :failure yield the Worker running the job.
  #
  # Queue and priority settings are process-wide (class-level settings of
  # Delayed::Worker), so all threads of a process work the same queues.
  class Dispatcher # rubocop:disable ClassLength
    include Logging

    STOP = Object.new.freeze

    # Exceptions raised into worker threads to interrupt their jobs on
    # shutdown (see #work).
    SHUTDOWN_INTERRUPTS = [ShutdownInterrupt, SignalException].freeze
    DEFER_SHUTDOWN_INTERRUPTS = Hash[SHUTDOWN_INTERRUPTS.map { |klass| [klass, :never] }].freeze
    ALLOW_SHUTDOWN_INTERRUPTS = Hash[SHUTDOWN_INTERRUPTS.map { |klass| [klass, :immediate] }].freeze

    # Give up (raising FatalBackendError) after this many consecutive
    # failures to reserve jobs.
    MAX_FAILED_RESERVATIONS = 10

    # Log throughput at least this often while the queue stays busy.
    REPORT_EVERY = 100

    # Seconds to wait for interrupted jobs to stop before giving up on them.
    INTERRUPT_GRACE = 5

    # How often (in seconds) a supervised worker checks that its parent
    # process is still alive, even while all its threads are busy.
    SUPERVISOR_CHECK_INTERVAL = 1

    # Runs the block with shutdown interrupts let in: they are deferred
    # everywhere else in worker threads (see #work). Worker#run wraps a job's
    # own code in it. Outside of worker threads (e.g. Worker#work_off), where
    # nothing defers them, it changes nothing.
    def self.interruptible(&block)
      return yield unless interrupt_masking?
      Thread.handle_interrupt(ALLOW_SHUTDOWN_INTERRUPTS, &block)
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
      @idle = []
      @inboxes = {}
      @threads = []
      @running = {} # thread => job it is running
      @jobs_started = {} # worker => [job it is running, when it started, its time limit, its log label]
      @overrun_reported = {} # worker => its job reported as overrun
      @in_flight = 0
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
      Delayed.instrument(:start_process, process_payload)
      error = nil
      begin
        with_lock_heartbeat do
          start_threads
          begin
            poll_loop
          rescue Exception => error # rubocop:disable RescueException
            # A worker thread's crash was reported by the thread itself.
            thread_error(error, 'Dispatcher') unless stopping_error?(error)
            raise
          ensure
            stop_threads(error)
          end
        end
      ensure
        Delayed.instrument(:stop_process, process_payload.merge(:error => error || @thread_error))
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
          track_job(worker, job) { worker.perform_job(job) } ? success += 1 : failure += 1
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
      "#{@procline_name}: #{state}#{in_flight}/#{thread_count} busy, queues=#{queue_names}"
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
        raise SignalException, 'TERM' if first && Worker.raise_signal_exceptions
      end

      trap('INT') do
        first = !stop?
        Thread.new { say 'Exiting...' } if first
        stop
        raise SignalException, 'INT' if first && Worker.raise_signal_exceptions && Worker.raise_signal_exceptions != :term
      end

      trap_quit
    end

    # QUIT can't be trapped everywhere: the JVM (JRuby) reserves it for
    # thread dumps. Without it, TERM and INT still stop the dispatcher.
    def trap_quit
      return unless Signal.list.key?('QUIT')
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

    def poll_loop # rubocop:disable CyclomaticComplexity, PerceivedComplexity
      until stop?
        update_procline
        raise_thread_error
        break if supervisor_gone?
        idle, seen = snapshot
        reserved = idle.empty? ? [] : poll(idle)
        reserved.each { |worker, job| dispatch(worker, job) }

        if reserved.empty? && in_flight.zero?
          report
          if Worker.exit_on_complete
            say 'No more jobs available. Exiting'
            break
          end
        elsif completed >= REPORT_EVERY
          report
        end

        update_procline
        # Fewer jobs than idle workers doesn't prove the queue ran dry: a
        # batch reservation may have lost some to other processes. Poll
        # again at once; only a poll that reserves nothing waits.
        next if !reserved.empty? && reserved.size < idle.size

        wait_before_next_poll(seen, !idle.empty? && reserved.empty?)
      end
      raise_thread_error
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

    def poll(idle)
      reserved = []
      Worker.lifecycle.run_callbacks(:loop, self) { reserved = reserve(idle) }
      reserved
    end

    # Reserves up to one job per given worker. On error, lets the backend
    # recover and returns no jobs, until too many consecutive failures.
    def reserve(workers)
      reserved = Delayed.instrument(:reserve, :dispatcher => name, :requested => workers.size) do |payload|
        payload[:reserved] = 0
        polling { Delayed::Job.reserve_batch(workers, Worker.lock_expiry) }.tap { |r| payload[:reserved] = r.size }
      end
      @failed_reserve_count = 0
      reserved
    rescue SignalException, SystemExit
      # Stopping (see Worker.raise_signal_exceptions), not a failed reservation.
      raise
    rescue ::Exception => error # rubocop:disable RescueException
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
      @heartbeat_stopped = false
      @heartbeat_mutex = Mutex.new
      @heartbeat_cond = ConditionVariable.new
      @heartbeat = Thread.new { lock_heartbeat_loop(Worker.lock_heartbeat_interval) }
      @heartbeat.report_on_exception = false if @heartbeat.respond_to?(:report_on_exception=)
      @heartbeat.name = 'delayed_job heartbeat' if @heartbeat.respond_to?(:name=)
      true
    end

    def stop_lock_heartbeat
      @heartbeat_mutex.synchronize do
        @heartbeat_stopped = true
        @heartbeat_cond.broadcast
      end
      @heartbeat.join
    end

    def lock_heartbeat_loop(interval)
      loop do
        @heartbeat_mutex.synchronize do
          @heartbeat_cond.wait(@heartbeat_mutex, interval) unless @heartbeat_stopped
        end
        break if @heartbeat_mutex.synchronize { @heartbeat_stopped }
        heartbeat
      end
    rescue Exception => error # rubocop:disable RescueException
      # #heartbeat handles StandardErrors; anything else ends the heartbeat.
      # Say so loudly: the locks of running jobs now expire after
      # lock_timeout, and other workers may take those jobs over.
      say "Lock heartbeat stopped by #{error.class}: #{error.message}; the locks of running jobs are no longer " \
          "refreshed and expire after lock_timeout (#{Worker.lock_timeout}s)", 'error'
      thread_error(error, 'Lock heartbeat')
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
      (workers - overrun.keys).map(&:name)
    end

    # Logs, once per job, that its lock is no longer refreshed.
    def report_overrun(worker, job, limit, label)
      first = synchronize do
        next false if @overrun_reported[worker].equal?(job)
        @overrun_reported[worker] = job
        true
      end
      return unless first
      worker.say(format('%s has run for longer than its max_run_time (%ds) without stopping; no longer ' \
                        'refreshing its lock, so another worker may run it after lock_timeout (%gs)',
                        label, limit, Worker.lock_timeout), 'error')
    end

    # Records which job the worker runs, since when, and for how long it may
    # run (see #heartbeat_names). The limit (and the job's log label) are
    # worked out here, on the worker's thread, so the heartbeat thread
    # never calls into the job.
    def track_job(worker, job)
      limit = run_time_limit(worker, job)
      label = limit && job_label(job)
      synchronize { @jobs_started[worker] = [job, monotonic_now, limit, label] }
      yield
    ensure
      synchronize do
        @jobs_started.delete(worker)
        @overrun_reported.delete(worker)
      end
    end

    # The job's max_run_time in whole seconds, as Worker#run times jobs out,
    # or nil for no limit: when it is under a second (no timeout), or when
    # working it out fails (Worker#run will then fail the job).
    def run_time_limit(worker, job)
      limit = worker.max_run_time(job).to_i
      limit if limit > 0
    rescue StandardError
      nil
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
      names = heartbeat_names
      polling { Delayed::Job.touch_locks(names) } unless names.empty?
    rescue StandardError => error
      say "Error while refreshing job locks: #{error.class}: #{error.message}", 'error'
      thread_error(error, 'Lock heartbeat')
    end

    def start_threads
      @idle = workers.dup
      @threads = workers.each_with_index.map do |worker, index|
        inbox = @inboxes[worker] = Queue.new
        Thread.new { work(worker, inbox) }.tap do |thread|
          thread.report_on_exception = false if thread.respond_to?(:report_on_exception=)
          thread.name = "delayed_job worker:#{index}" if thread.respond_to?(:name=)
        end
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
      self.class.deferring_interrupts do
        Worker.lifecycle.run_callbacks(:execute, worker) do
          begin
            until (job = inbox.pop).equal?(STOP)
              discard_stale_interrupts
              synchronize { @running[Thread.current] = job }
              result = with_reloader { track_job(worker, job) { worker.perform_job(job) } }
              synchronize { @running.delete(Thread.current) }
              job_finished(worker, result)
            end
          rescue ShutdownInterrupt
            release_interrupted(worker, synchronize { @running.delete(Thread.current) })
          end
        end
      end
    rescue *SHUTDOWN_INTERRUPTS
      # Deferred while the thread was exiting and delivered as it left the
      # block above (no job left to interrupt), or a signal raised into a
      # job (see #stop_threads) that escaped it: the process is stopping
      # anyway, so this is no thread crash to report.
      synchronize { @running.delete(Thread.current) }
    rescue Exception => error # rubocop:disable RescueException
      thread_error(error, 'Worker thread', worker.name)
      synchronize do
        @running.delete(Thread.current)
        @thread_error ||= error
        signal_event
      end
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
      {:dispatcher => name, :pid => Process.pid, :threads => thread_count, :queues => Worker.queues}
    end

    # Lets running jobs finish, then waits for every thread to exit. Jobs
    # still running at the shutdown deadline (see #shutdown_deadline) are
    # interrupted and released. If the dispatcher is exiting because of a
    # signal exception (see Worker.raise_signal_exceptions), it is raised in
    # running jobs as well.
    def stop_threads(error)
      @stop_requested_at ||= monotonic_now
      update_procline
      @inboxes.each_value { |inbox| inbox << STOP }
      if error.is_a?(SignalException)
        @threads.each { |thread| thread.raise(error.class, error.message) if thread.alive? }
      end
      wait_for_threads
      interrupt_threads(synchronize { @running.keys.select(&:alive?) }) if shutdown_deadline
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
      Delayed.instrument(:interrupt, :dispatcher => name, :jobs => busy.size, :reason => reason)
      busy.each { |thread| thread.raise(ShutdownInterrupt, reason) }
      deadline = monotonic_now + INTERRUPT_GRACE
      busy.each { |thread| thread.join([deadline - monotonic_now, 0].max) }
      stuck = busy.count(&:alive?)
      return if stuck.zero?
      say format('%d job(s) did not stop within %gs of being interrupted; ', stuck, INTERRUPT_GRACE) +
          'leaving them locked until max_run_time expires', 'error'
    end

    # When running jobs are interrupted: at once after #quit, else
    # Worker.shutdown_timeout seconds after #stop, else never (nil).
    def shutdown_deadline
      return monotonic_now if quit?
      timeout = Worker.shutdown_timeout
      @stop_requested_at + timeout if timeout
    end

    # Releases a job interrupted by shutdown for another worker to run: its
    # lock is cleared, its attempts and run_at are left as they were.
    def release_interrupted(worker, job)
      worker.job_say(job, 'interrupted by shutdown; released for another worker', 'warn') if job
      Delayed::Job.clear_locks!(worker.name)
      Delayed.instrument(:locks_released, :workers => [worker.name], :count => job ? 1 : 0, :reason => 'shutdown') if job
    rescue StandardError => error
      say "Could not release the jobs of #{worker.name}: #{error.class}: #{error.message}", 'error'
      thread_error(error, 'Releasing interrupted jobs', worker.name)
    end

    def dispatch(worker, job)
      synchronize do
        @idle.delete(worker)
        @in_flight += 1
      end
      @inboxes[worker] << job
    end

    def job_finished(worker, result)
      synchronize do
        result ? @success += 1 : @failure += 1
        @in_flight -= 1
        @idle << worker
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

    def snapshot
      synchronize { [@idle.dup, @events] }
    end

    def in_flight
      synchronize { @in_flight }
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
