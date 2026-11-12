require 'helper'

# Records which thread/worker ran it and how many jobs ran at once.
class ConcurrencyJob
  cattr_accessor :mutex, :running, :max_running, :runs, :delay
  self.mutex = Mutex.new

  def self.reset(delay = 0.05)
    self.running = 0
    self.max_running = 0
    self.runs = Hash.new(0)
    self.delay = delay
  end
  reset

  attr_accessor :key

  def initialize(key)
    self.key = key
  end

  def perform
    self.class.mutex.synchronize do
      self.class.running += 1
      self.class.max_running = [self.class.max_running, self.class.running].max
      self.class.runs[key] += 1
    end
    sleep self.class.delay
  ensure
    self.class.mutex.synchronize { self.class.running -= 1 }
  end
end

describe Delayed::Poller do
  let(:thread_count) { 4 }
  let(:poller) { described_class.new(:threads => thread_count, :sleep_delay => 0.1) }

  before do
    Delayed::Job.delete_all
    ConcurrencyJob.reset
    Delayed::Worker.exit_on_complete = true
  end

  after do
    Delayed::Worker.exit_on_complete = false
    Delayed::Worker.sleep_delay = Delayed::Worker::DEFAULT_SLEEP_DELAY
  end

  def enqueue_jobs(count)
    count.times { |i| Delayed::Job.enqueue(ConcurrencyJob.new(i)) }
  end

  describe '#initialize' do
    it 'builds a single unindexed worker by default' do
      poller = described_class.new
      expect(poller.thread_count).to eq 1
      expect(poller.workers.first.thread_index).to be_nil
      expect(poller.workers.first.poller).to eq poller
    end

    it 'runs the given workers' do
      worker = Delayed::Worker.new
      expect(described_class.new(:workers => [worker]).workers).to eq [worker]
    end

    it 'builds one worker per thread with distinct names' do
      poller.name_prefix = 'delayed_job.1 '
      names = poller.workers.map(&:name)
      expect(names.uniq.size).to eq thread_count
      expect(names).to all(start_with('delayed_job.1 '))
      expect(names.last).to end_with('thread:3')
    end

    it 'rejects a thread count below 1' do
      expect { described_class.new(:threads => 0) }.to raise_error(ArgumentError)
    end
  end

  describe '#start' do
    it 'traps signals and runs' do
      expect(poller).to receive(:trap_signals).ordered
      expect(poller).to receive(:run).ordered
      poller.start
    end
  end

  describe '#run' do
    context 'with a single thread' do
      let(:thread_count) { 1 }

      it 'runs every job, one at a time' do
        enqueue_jobs(5)
        Timeout.timeout(10) { poller.run }
        expect(ConcurrencyJob.runs.size).to eq 5
        expect(ConcurrencyJob.max_running).to eq 1
        expect(Delayed::Job.count).to eq 0
      end
    end

    it 'does not install signal traps' do
      expect(poller).not_to receive(:trap)
      Timeout.timeout(5) { poller.run }
    end

    it 'runs :loop callbacks around each poll, with the poller' do
      polled = []
      poller
      Delayed::Worker.lifecycle.around(:loop) do |p, &block|
        polled << p
        block.call(p)
      end
      enqueue_jobs(2)
      Timeout.timeout(5) { poller.run }
      expect(polled).not_to be_empty
      expect(polled).to all(equal(poller))
    end

    it 'logs throughput' do
      enqueue_jobs(3)
      allow(poller).to receive(:say)
      expect(poller).to receive(:say).with(/\A3 jobs processed at [\d.]+ j\/s, 0 failed\z/)
      Timeout.timeout(5) { poller.run }
    end

    it 'runs every job exactly once, concurrently' do
      enqueue_jobs(20)
      Timeout.timeout(10) { poller.run }

      expect(Delayed::Job.count).to eq 0
      expect(ConcurrencyJob.runs.keys.sort).to eq((0...20).to_a)
      expect(ConcurrencyJob.runs.values).to all(eq 1)
      expect(ConcurrencyJob.max_running).to be > 1
      expect(ConcurrencyJob.max_running).to be <= thread_count
    end

    it 'locks each job under the name of the thread that runs it' do
      enqueue_jobs(8)
      lockers = []
      allow_any_instance_of(Delayed::Worker).to receive(:perform_job).and_wrap_original do |m, job|
        lockers << job.locked_by
        m.call(job)
      end
      Timeout.timeout(10) { poller.run }

      expect(lockers.size).to eq 8
      expect(lockers - poller.workers.map(&:name)).to be_empty
      expect(lockers.uniq.size).to be > 1
    end

    it 'only reserves jobs for idle threads' do
      enqueue_jobs(6)
      batch_sizes = []
      allow(Delayed::Job).to receive(:reserve_batch).and_wrap_original do |m, workers|
        expect(workers.size).to be <= thread_count
        m.call(workers).tap { |reserved| batch_sizes << reserved.size }
      end
      Timeout.timeout(10) { poller.run }

      expect(batch_sizes.inject(:+)).to eq 6
      expect(batch_sizes.first).to eq thread_count
    end

    it 'queries the backend once per poll when idle' do
      Delayed::Worker.exit_on_complete = false
      polls = 0
      reserves = 0
      allow(Delayed::Job).to receive(:reserve).and_wrap_original do |m, *args|
        reserves += 1
        m.call(*args)
      end
      allow(Delayed::Job).to receive(:reserve_batch).and_wrap_original do |m, workers|
        expect(workers.size).to eq thread_count
        poller.stop if (polls += 1) == 3
        m.call(workers)
      end
      Timeout.timeout(5) { poller.run }
      expect(polls).to eq 3
      expect(reserves).to eq 3
    end

    it 'lets running jobs finish when stopped' do
      ConcurrencyJob.reset(0.3)
      enqueue_jobs(8)
      Delayed::Worker.exit_on_complete = false
      thread = Thread.new { poller.run }
      sleep 0.1 until ConcurrencyJob.running == thread_count
      poller.stop
      Timeout.timeout(5) { thread.join }

      expect(ConcurrencyJob.running).to eq 0
      expect(ConcurrencyJob.runs.size).to eq thread_count
      expect(Delayed::Job.count).to eq 4
      expect(Delayed::Job.all.map(&:locked_by)).to all(be_nil)
    end

    it 'wakes up from the idle sleep promptly when stopped' do
      Delayed::Worker.exit_on_complete = false
      Delayed::Worker.sleep_delay = 30
      thread = Thread.new { poller.run }
      sleep 0.2
      poller.stop
      expect(Timeout.timeout(2) { thread.join }).to eq thread
    end

    it 'stops and re-raises when a thread dies' do
      enqueue_jobs(4)
      allow_any_instance_of(Delayed::Worker).to receive(:perform_job).and_raise(NoMemoryError, 'boom')
      expect { Timeout.timeout(5) { poller.run } }.to raise_error(NoMemoryError, 'boom')
      expect(poller.instance_variable_get(:@threads)).to all(satisfy { |t| !t.alive? })
    end

    it 'raises FatalBackendError after 10 reservation failures' do
      Delayed::Worker.exit_on_complete = false
      Delayed::Worker.sleep_delay = 0.01
      expect(Delayed::Job).to receive(:reserve).exactly(10).times.and_raise(StandardError)
      expect { Timeout.timeout(5) { poller.run } }.to raise_error(Delayed::FatalBackendError)
    end

    it 'runs :execute callbacks for every thread and clears their locks' do
      poller # Worker.new resets the lifecycle, so build it first
      executed = []
      expect(Delayed::Job).to receive(:clear_locks!).exactly(thread_count).times
      Delayed::Worker.lifecycle.around(:execute) do |w, &block|
        executed << w.name
        block.call(w)
      end
      Timeout.timeout(5) { poller.run }
      expect(executed).to match_array(poller.workers.map(&:name))
    end
  end
end

describe Delayed::Backend::Base do
  describe '.reserve_batch' do
    let(:workers) { Array.new(3) { |i| Delayed::Worker.new.tap { |w| w.thread_index = i } } }

    before { Delayed::Job.delete_all }

    it 'locks a distinct job under each worker name' do
      3.times { Delayed::Job.enqueue(SimpleJob.new) }
      reserved = Delayed::Job.reserve_batch(workers)
      expect(reserved.map(&:first)).to eq workers
      expect(reserved.map(&:last).uniq.size).to eq 3
      reserved.each { |w, job| expect(job.locked_by).to eq w.name }
    end

    it 'stops at the first worker without a job' do
      Delayed::Job.enqueue(SimpleJob.new)
      expect(Delayed::Job).to receive(:reserve).twice.and_call_original
      expect(Delayed::Job.reserve_batch(workers).size).to eq 1
    end

    it 'returns already reserved jobs when a later reservation fails' do
      Delayed::Job.enqueue(SimpleJob.new)
      calls = 0
      allow(Delayed::Job).to receive(:reserve).and_wrap_original do |m, *args|
        (calls += 1) == 1 ? m.call(*args) : raise('db down')
      end
      expect(Delayed::Job.reserve_batch(workers).size).to eq 1
    end

    it 'raises when the first reservation fails' do
      allow(Delayed::Job).to receive(:reserve).and_raise('db down')
      expect { Delayed::Job.reserve_batch(workers) }.to raise_error('db down')
    end
  end
end
