require 'helper'

# Worker.prefetch: each worker thread holds jobs queued behind the one it
# runs, each locked under a slot name of its own (see Worker.slot_name).
describe 'Prefetching jobs (Worker.prefetch)' do
  let(:log) { Concurrent::Array.new }
  let(:reserves) { Concurrent::Array.new }

  before do
    Delayed::Job.delete_all
    SimpleJob.runs = 0
    GateJob.reset
    ConcurrencyJob.reset(0.01)
  end

  let(:running) { Concurrent::Array.new }

  # Stops every dispatcher a failed example left running, so that its
  # threads don't finish jobs during the next example.
  after do
    GateJob.release = true
    running.each do |d, thread|
      d.stop
      thread.join(10)
    end
  end

  def dispatcher(threads, options = {})
    Delayed::Dispatcher.new({:threads => threads, :sleep_delay => 0.05}.merge(options)).tap do |d|
      allow(d).to receive(:say) { |text, level = 'info'| log << [level, text] }
      d.workers.each { |w| allow(w).to receive(:say) { |text, level = 'info'| log << [level, text] } }
    end
  end

  # Records each reservation: [requested names, reserved count, depth].
  def record_reserves
    allow(Delayed::Job).to receive(:reserve_batch).and_wrap_original do |m, slots, *args|
      m.call(slots, *args).tap { |reserved| reserves << [slots.map(&:name), reserved.size] }
    end
  end

  def locked_jobs
    Delayed::Job.all.select(&:locked_by)
  end

  def run_in_thread(dispatcher)
    Thread.new { dispatcher.run }.tap do |thread|
      thread.report_on_exception = false if thread.respond_to?(:report_on_exception=)
      running << [dispatcher, thread]
    end
  end

  # Builds the dispatcher's slots and inboxes, without starting threads.
  def prepare(dispatcher)
    dispatcher.send(:build_slots)
    dispatcher.workers.each { |w| dispatcher.instance_variable_get(:@inboxes)[w] = Queue.new }
    dispatcher
  end

  def wait_until(timeout = 5)
    Timeout.timeout(timeout) { sleep 0.01 until yield }
  end

  def stop_and_join(dispatcher, thread)
    GateJob.release = true
    dispatcher.stop
    Timeout.timeout(10) { thread.join }
  end

  def gate_jobs(count, priority = 0)
    Array.new(count) { |i| Delayed::Job.enqueue(GateJob.new(i), :priority => priority) }
  end

  describe 'Worker settings' do
    it 'defaults to no prefetch, not dynamic' do
      expect(Delayed::Worker.prefetch).to eq 0
      expect(Delayed::Worker.prefetch_dynamic).to be false
    end

    it 'are set by Worker.new options and reset by Worker.reset' do
      Delayed::Worker.new(:prefetch => 2, :prefetch_dynamic => true)
      expect([Delayed::Worker.prefetch, Delayed::Worker.prefetch_dynamic]).to eq [2, true]
      Delayed::Worker.reset
      expect([Delayed::Worker.prefetch, Delayed::Worker.prefetch_dynamic]).to eq [0, false]
    end

    it 'rejects a negative or fractional prefetch' do
      [-1, 1.5, '2', nil].each do |value|
        Delayed::Worker.prefetch = value
        expect { Delayed::Worker.validate_prefetch! }.to raise_error(ArgumentError, /prefetch must be a whole number/)
      end
    end

    it 'names slots after the worker' do
      expect(Delayed::Worker.slot_name('dj host:h pid:1 thread:2', 3)).to eq 'dj host:h pid:1 thread:2 slot:3'
    end

    it 'lists slot names in lock_names only with prefetch' do
      expect(Delayed::Worker.lock_names('dj ', 1, 2)).to eq Delayed::Worker.lock_names('dj ', 1, 2, 0)
      names = Delayed::Worker.lock_names('dj ', 1, 2, 2)
      expect(names.size).to eq 6
      expect(names.first).to eq Delayed::Worker.slot_name(Delayed::Worker.lock_name('dj ', 1, 0), 0)
      expect(names.last).to eq Delayed::Worker.slot_name(Delayed::Worker.lock_name('dj ', 1, 1), 2)
    end

    it 'refuses to run a dispatcher with an invalid prefetch' do
      Delayed::Worker.prefetch = -1
      expect { Timeout.timeout(5) { dispatcher(1).run } }.to raise_error(ArgumentError, /prefetch/)
    end
  end

  context 'with prefetch 0 (the default)' do
    it 'locks jobs under the plain worker names, one per idle worker' do
      gate_jobs(4)
      d = dispatcher(2)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 2 }
      sleep 0.2 # Polls meanwhile must not reserve more.
      expect(locked_jobs.map(&:locked_by)).to match_array d.workers.map(&:name)
      stop_and_join(d, thread)
    end

    it 'still runs a job handed over just before stopping' do
      Delayed::Job.enqueue(SimpleJob.new)
      d = dispatcher(1)
      allow(d).to receive(:dispatch).and_wrap_original do |m, *args|
        d.stop
        m.call(*args)
      end
      Timeout.timeout(5) { d.run }
      expect(Delayed::Job.count).to eq 0
      expect(SimpleJob.runs).to eq 1
    end
  end

  context 'with prefetch 1' do
    before { Delayed::Worker.prefetch = 1 }

    it 'holds a running and a queued job per worker, under distinct slot names' do
      gate_jobs(6)
      d = dispatcher(2)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 2 && locked_jobs.size == 4 }
      sleep 0.2
      expected = d.workers.flat_map { |w| [0, 1].map { |i| Delayed::Worker.slot_name(w.name, i) } }
      expect(locked_jobs.map(&:locked_by)).to match_array expected
      expect(d.procline).to include '2/2 busy, 2 queued'
      stop_and_join(d, thread)
    end

    it 'starts the next job without waiting for a poll' do
      jobs = gate_jobs(2)
      d = dispatcher(1)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 1 && locked_jobs.size == 2 }
      # From now on, polls hang until the test ends.
      blocked = Queue.new
      allow(Delayed::Job).to receive(:reserve_batch) do |*|
        blocked.pop
        []
      end
      GateJob.release = true
      wait_until { (Delayed::Job.all & jobs).empty? }
      expect(GateJob.finished).to eq [0, 1]
      blocked << :done
      d.stop
      Timeout.timeout(10) { thread.join }
    end

    it 'tops up a busy worker as soon as its queued job starts' do
      gate_jobs(5)
      d = dispatcher(1)
      thread = run_in_thread(d)
      wait_until { locked_jobs.size == 2 }
      GateJob.release = true
      wait_until { Delayed::Job.count.zero? }
      expect(GateJob.finished).to match_array (0...5).to_a
      stop_and_join(d, thread)
    end

    it 'never reserves a job a worker already holds' do
      gate_jobs(1)
      record_reserves
      d = dispatcher(1)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 1 }
      sleep 0.3 # Several polls for the free slot while the job runs.
      expect(reserves.size).to be > 1
      expect(reserves.drop(1).map(&:last)).to all(eq 0)
      stop_and_join(d, thread)
      expect(GateJob.finished).to eq [0]
    end

    it 'gives the first jobs to idle workers before queueing any' do
      record_reserves
      d = dispatcher(2)
      slot0 = d.workers.map { |w| Delayed::Worker.slot_name(w.name, 0) }
      slot1 = d.workers.map { |w| Delayed::Worker.slot_name(w.name, 1) }
      gate_jobs(4)
      thread = run_in_thread(d)
      wait_until { locked_jobs.size == 4 }
      expect(reserves.first.first).to eq slot0 + slot1
      stop_and_join(d, thread)
    end

    it 'runs every job exactly once with exit_on_complete' do
      Delayed::Worker.exit_on_complete = true
      50.times { |i| Delayed::Job.enqueue(ConcurrencyJob.new(i)) }
      Timeout.timeout(30) { dispatcher(4).run }
      expect(ConcurrencyJob.runs.keys.sort).to eq((0...50).to_a)
      expect(ConcurrencyJob.runs.values).to all(eq 1)
      expect(Delayed::Job.count).to eq 0
    end

    it 'refreshes the locks of queued jobs too' do
      d = prepare(dispatcher(2))
      slots = d.instance_variable_get(:@slots)
      queued = slots[d.workers.first][1]
      d.send(:dispatch, queued, Delayed::Job.enqueue(SimpleJob.new))
      expect(d.send(:heartbeat_names)).to eq d.workers.map(&:name) + [queued.name]
    end

    it 'stops refreshing the lock of an overrun job, not of queued ones' do
      Delayed::Worker.max_run_time = 10
      d = prepare(dispatcher(1))
      worker = d.workers.first
      running, queued = d.instance_variable_get(:@slots)[worker]
      job = Delayed::Job.enqueue(SimpleJob.new)
      d.send(:dispatch, running, job)
      d.send(:dispatch, queued, Delayed::Job.enqueue(SimpleJob.new))
      d.instance_variable_get(:@running_slot)[worker] = running
      d.instance_variable_get(:@jobs_started)[worker] = [job, Process.clock_gettime(Process::CLOCK_MONOTONIC) - 11, 10, 'Job']
      expect(d.send(:heartbeat_names)).to eq [queued.name]
    end
  end

  context 'with prefetch 2' do
    before { Delayed::Worker.prefetch = 2 }

    it 'reserves 3 for an idle worker, then tops it back up to 3' do
      record_reserves
      gate_jobs(10)
      d = dispatcher(1)
      thread = run_in_thread(d)
      wait_until { locked_jobs.size == 3 }
      expect(reserves.first.last).to eq 3
      GateJob.release = true
      wait_until { Delayed::Job.count.zero? }
      stop_and_join(d, thread)
      expect(GateJob.finished.size).to eq 10
    end

    it 'gives a busy worker with an empty queue 2 more jobs' do
      d = dispatcher(1)
      gate_jobs(1)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 1 }
      record_reserves
      gate_jobs(5)
      wait_until { locked_jobs.size == 3 }
      expect(reserves.find { |_, reserved| reserved > 0 }.last).to eq 2
      stop_and_join(d, thread)
    end
  end

  context 'with prefetch_dynamic' do
    before do
      Delayed::Worker.prefetch = 2
      Delayed::Worker.prefetch_dynamic = true
    end

    let(:depths) { Concurrent::Array.new }

    def record_depths
      subscriber = ActiveSupport::Notifications.subscribe('reserve.delayed_job') do |*, payload|
        depths << [payload[:depth], payload[:requested], payload[:reserved]]
      end
      yield
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it 'starts at depth 0, grows one level per full poll and polls again at once' do
      gate_jobs(20)
      d = dispatcher(2, :sleep_delay => 30)
      thread = nil
      record_depths do
        thread = run_in_thread(d)
        wait_until { locked_jobs.size == 6 }
      end
      # 2 idle workers, then 2 more queued, then 2 more: full each time.
      expect(depths.first(3)).to eq [[0, 2, 2], [1, 2, 2], [2, 2, 2]]
      stop_and_join(d, thread)
    end

    it 'drops back to depth 0 after a partial poll, leaving queued jobs to run' do
      gate_jobs(5)
      d = dispatcher(2)
      thread = nil
      record_depths do
        thread = run_in_thread(d)
        wait_until { locked_jobs.size == 5 }
        sleep 0.2
      end
      # Depth 0: 2 of 2; depth 1: 2 of 2; depth 2: 1 of 2 -> back to 0.
      # Both workers are busy, so at depth 0 there is nothing to poll for.
      expect(depths).to eq [[0, 2, 2], [1, 2, 2], [2, 2, 1]]
      expect(d.procline).to include 'depth 0/2'
      GateJob.release = true
      wait_until { Delayed::Job.count.zero? }
      stop_and_join(d, thread)
      expect(GateJob.finished).to match_array (0...5).to_a
    end

    it 'leaves the depth alone when a poll asks for nothing' do
      d = dispatcher(1)
      d.instance_variable_set(:@prefetch, 2)
      d.instance_variable_set(:@depth, 1)
      expect(d.send(:adjust_depth, 0, 0)).to be false
      expect(d.instance_variable_get(:@depth)).to eq 1
      expect(d.send(:adjust_depth, 2, 2)).to be true
      expect(d.send(:adjust_depth, 2, 2)).to be false # Capped at prefetch.
      expect(d.instance_variable_get(:@depth)).to eq 2
    end

    it 'runs every job exactly once with exit_on_complete' do
      Delayed::Worker.exit_on_complete = true
      50.times { |i| Delayed::Job.enqueue(ConcurrencyJob.new(i)) }
      Timeout.timeout(30) { dispatcher(4).run }
      expect(ConcurrencyJob.runs.keys.sort).to eq((0...50).to_a)
      expect(ConcurrencyJob.runs.values).to all(eq 1)
    end
  end

  describe 'shutdown with queued jobs' do
    before { Delayed::Worker.prefetch = 2 }

    let(:released) { Concurrent::Array.new }

    def track_releases
      subscriber = ActiveSupport::Notifications.subscribe('locks_released.delayed_job') do |*, payload|
        released << payload
      end
      yield
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    def unlocked?(job)
      job.reload
      job.locked_by.nil? && job.locked_at.nil? && job.attempts.zero?
    end

    it 'releases queued jobs unstarted and lets running ones finish' do
      jobs = gate_jobs(6)
      d = dispatcher(2)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 2 && locked_jobs.size == 6 }
      track_releases do
        d.stop
        wait_until { locked_jobs.size == 2 }
        GateJob.release = true
        Timeout.timeout(10) { thread.join }
      end
      expect(GateJob.finished.size).to eq 2
      left = Delayed::Job.all
      expect(left.size).to eq 4
      expect(left).to all(satisfy { |job| unlocked?(job) })
      expect(released.first).to include(:count => 4, :reason => 'shutdown')
      expect(released.first[:workers].size).to eq 4
      expect(log.map(&:last)).to include 'Released 4 queued job(s) on shutdown'
      expect(jobs.size).to eq 6
    end

    it 'releases queued and running jobs on quit' do
      gate_jobs(6)
      d = dispatcher(2)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 2 && locked_jobs.size == 6 }
      d.quit
      Timeout.timeout(10) { thread.join }
      expect(GateJob.interrupted.size).to eq 2
      expect(Delayed::Job.all.size).to eq 6
      expect(Delayed::Job.all).to all(satisfy { |job| unlocked?(job) })
    end

    it 'releases everything once the shutdown timeout passes' do
      Delayed::Worker.shutdown_timeout = 0.2
      gate_jobs(4)
      d = dispatcher(1)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 1 && locked_jobs.size == 3 }
      d.stop
      Timeout.timeout(10) { thread.join }
      expect(GateJob.interrupted).to eq [0]
      expect(Delayed::Job.all).to all(satisfy { |job| unlocked?(job) })
    end

    it 'does not start a job a worker took after stop was requested' do
      Delayed::Job.enqueue(SimpleJob.new)
      d = dispatcher(1)
      allow(d).to receive(:dispatch).and_wrap_original do |m, *args|
        d.stop # As the job is handed over: the worker takes it after stop.
        m.call(*args)
      end
      allow(d).to receive(:release_queued) # Leave it to the worker.
      Timeout.timeout(5) { d.run }
      expect(SimpleJob.runs).to eq 0
      job = Delayed::Job.all.first
      expect([job.locked_by, job.locked_at, job.attempts]).to eq [nil, nil, 0]
      expect(log.map(&:last).grep(/not started before shutdown/).size).to eq 1
    end

    it 'logs and reports a failure to release queued jobs' do
      reported = Concurrent::Array.new
      Delayed::Worker.on_thread_error = ->(error, info) { reported << [error.message, info[:context]] }
      gate_jobs(3)
      d = dispatcher(1)
      thread = run_in_thread(d)
      wait_until { GateJob.started.size == 1 && locked_jobs.size == 3 }
      allow(Delayed::Job).to receive(:clear_locks!).and_raise(IOError, 'down')
      d.stop
      wait_until { reported.any? } # Queued jobs drained before the running one finishes.
      GateJob.release = true
      Timeout.timeout(10) { thread.join }
      expect(reported).to include ['down', 'Releasing interrupted jobs']
      expect(log.map(&:last)).to include 'Could not release the queued jobs: IOError: down'
      expect(d.send(:in_flight)).to eq 0
    end
  end
end
