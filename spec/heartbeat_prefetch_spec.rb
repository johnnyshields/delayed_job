require 'helper'
require_relative 'processes/helpers'
require_relative 'processes/jobs'

# Lock heartbeats with prefetch, end to end: real heartbeat threads refreshing
# locks in a database (SQLite) that supports them, while jobs wait queued.
describe 'Lock heartbeats with prefetch', :processes do
  include ProcessHelpers

  let(:job_class) { Delayed::Backend::SqliteFile::Job }
  let(:log) { Concurrent::Array.new }
  let(:reported) { Concurrent::Array.new }

  around do |example|
    Delayed::Worker.backend = Delayed::Backend::SqliteFile::Job
    example.run
  ensure
    Delayed::Worker.backend = :test
  end

  before do
    GateJob.reset
    FuzzJob.completed.clear
    Delayed::Worker.lock_heartbeat_interval = 0.1
    Delayed::Worker.lock_timeout = 0.5
    Delayed::Worker.on_thread_error = ->(error, info) { reported << [error, info] }
  end

  def dispatcher(threads, prefix = nil)
    Delayed::Dispatcher.new(:threads => threads, :sleep_delay => 0.05).tap do |d|
      d.name_prefix = prefix if prefix
      capture_say(log, *and_workers(d))
    end
  end

  def enqueue(payload, priority = 0)
    job_class.create!(:payload_object => payload, :priority => priority)
  end

  def locked
    job_class.where.not(:locked_by => nil).to_a
  end

  def lost_locks
    log.map(&:last).grep(/lock expired and another worker reserved it/)
  end

  it 'keeps the locks of queued jobs fresh while they wait, so no other worker takes them' do
    Delayed::Worker.prefetch = 2
    3.times { |i| enqueue(GateJob.new(i)) }
    d = dispatcher(1)
    run_in_thread(d)
    wait_until { GateJob.started.size == 1 && locked.size == 3 }
    sleep 3 * Delayed::Worker.lock_timeout # Unrefreshed, the queued locks would have expired twice over.

    now = job_class.db_time_now
    expect(locked.map(&:locked_by)).to all(match(/ slot:\d\z/))
    expect(locked.map(&:locked_at)).to all(be > now - Delayed::Worker.lock_timeout)
    expect(job_class.reserve(Delayed::Worker.named('intruder'), Delayed::Worker.lock_expiry)).to be_nil
    GateJob.release = true
    wait_until(10) { job_class.count.zero? }
    expect(GateJob.finished.sort).to eq [0, 1, 2]
    expect(lost_locks).to be_empty
    expect(reported).to be_empty
  end

  [false, true].each do |dynamic|
    it "runs every job exactly once with two dispatchers competing (prefetch_dynamic #{dynamic})" do
      Delayed::Worker.prefetch = 2
      Delayed::Worker.prefetch_dynamic = dynamic
      Delayed::Worker.exit_on_complete = true
      # Long enough that jobs wait queued for about lock_timeout.
      40.times { |i| enqueue(FuzzJob.new(i, rand * 0.2)) }
      runs = [dispatcher(2, 'a '), dispatcher(2, 'b ')].map { |d| Thread.new { d.run } }
      Timeout.timeout(60) { runs.each(&:join) }

      expect(FuzzJob.completed.size).to eq 40
      expect(FuzzJob.completed.values).to all(eq 1)
      expect(job_class.count).to eq 0
      expect(lost_locks).to be_empty
      expect(reported).to be_empty
    end
  end

  it 'releases the jobs queued behind a stuck job, so another thread runs them while it is stuck' do
    Delayed::Worker.prefetch = 1
    released = payloads_of(:jobs_released)
    # One poll reserves them in priority order into slots in rounds: the
    # stuck job runs on one thread, `behind` is queued behind it.
    stuck = enqueue(StuckJob.new(4, 1), 0) # Ignores its 1s timeout for 4s.
    enqueue(FuzzJob.new(:quick, 0), 1)
    enqueue(FuzzJob.new(:behind, 0), 2)
    enqueue(FuzzJob.new(:other, 0), 3)
    d = dispatcher(2)
    run_in_thread(d)
    wait_until(3) { FuzzJob.completed.key?(:behind) }

    expect(job_class.where(:id => stuck.id)).to exist # Still stuck.
    expect(released.map { |p| p[:reason] }).to include 'stuck job'
    expect(log.map(&:last).grep(/longer than its max_run_time/).size).to eq 1
    expect(FuzzJob.completed.values).to all(eq 1)
  end

  it 'releases queued jobs on shutdown and stops refreshing locks' do
    Delayed::Worker.prefetch = 2
    jobs = Array.new(3) { |i| enqueue(GateJob.new(i)) }
    touches = Concurrent::AtomicFixnum.new
    allow(job_class).to(receive(:touch_locks).and_wrap_original do |m, names|
      touches.increment
      m.call(names)
    end)
    d = dispatcher(1)
    thread = run_in_thread(d)
    wait_until { GateJob.started.size == 1 && locked.size == 3 }
    d.stop
    wait_until { locked.size == 1 } # The queued two, released at once; the running one finishes.
    running = locked.first
    expect(jobs.map(&:id) - [running.id]).to all(satisfy { |id| job_class.find(id).attempts.zero? })
    GateJob.release = true
    Timeout.timeout(10) { thread.join }

    expect(d.instance_variable_get(:@heartbeat)).not_to be_alive
    beats = touches.value
    sleep 3 * Delayed::Worker.lock_heartbeat_interval
    expect(touches.value).to eq beats
    expect(job_class.count).to eq 2
    expect(locked).to be_empty
  end

  it 'limits a job started while the heartbeat keeps failing to what is left of its lock' do
    Delayed::Worker.prefetch = 1
    allow(job_class).to receive(:touch_locks).and_raise(IOError, 'database gone')
    d = dispatcher(1)
    run_in_thread(d)
    sleep 2 * Delayed::Worker.lock_timeout # No refresh gets through: the heartbeat can't be relied on.
    job = enqueue(ProcessJobs::SleepJob.new('slow', 3)) # Reserved now: a fresh lock, of lock_timeout.
    wait_until(10) { job_class.find(job.id).attempts == 1 } # Timed out at its lock expiry, not after 3s.

    expect(job_class.find(job.id).last_error).to match(/execution expired/)
    expect(ProcessHelpers::Run.where(:key => 'slow')).not_to exist
  end

  it 'releases a queued job whose lock expired while the heartbeat was failing, then runs it once' do
    Delayed::Worker.prefetch = 1
    released = payloads_of(:jobs_released)
    enqueue(GateJob.new(:first))
    enqueue(GateJob.new(:queued))
    allow(job_class).to receive(:touch_locks).and_raise(IOError, 'database gone')
    d = dispatcher(1)
    run_in_thread(d)
    wait_until { GateJob.started.size == 1 && locked.size == 2 }
    sleep 2 * Delayed::Worker.lock_timeout # No refresh gets through.
    GateJob.release = true
    wait_until(10) { job_class.count.zero? }

    expect(released.map { |p| p[:reason] }).to include 'lock expired in queue'
    expect(GateJob.finished.sort).to eq %i(first queued)
    expect(reported.map { |_, info| info[:context] }.uniq).to eq ['Lock heartbeat']
  end
end
