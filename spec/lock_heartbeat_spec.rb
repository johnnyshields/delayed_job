require 'helper'
require_relative 'processes/helpers'

# Lock heartbeats (Worker.lock_heartbeat_interval / lock_timeout) and
# owner-guarded writes, on a real Active Record backend (an SQLite file).
describe 'Lock heartbeats' do
  include ProcessHelpers

  around do |example|
    Delayed::Worker.backend = Delayed::Backend::SqliteFile::Job
    example.run
  ensure
    Delayed::Worker.reset
    Delayed::Worker.backend = :test
  end

  describe Delayed::Backend::SqliteFile::Job do
    it_behaves_like 'a delayed_job backend supporting lock heartbeats'
  end

  describe 'settings' do
    it 'is off by default, with a 5 minute lock timeout' do
      expect(Delayed::Worker.lock_heartbeat_interval).to be_nil
      expect(Delayed::Worker.lock_timeout).to eq 5.minutes
      expect(Delayed::Worker.lock_heartbeats?).to be false
    end

    it 'is set by Worker.new options' do
      Delayed::Worker.new(:lock_heartbeat_interval => 10, :lock_timeout => 45)
      expect([Delayed::Worker.lock_heartbeat_interval, Delayed::Worker.lock_timeout]).to eq [10, 45]
    end

    describe '.lock_expiry' do
      it 'is max_run_time without heartbeats' do
        expect(Delayed::Worker.lock_expiry).to eq Delayed::Worker.max_run_time
      end

      it 'is lock_timeout with heartbeats' do
        Delayed::Worker.lock_heartbeat_interval = 10
        Delayed::Worker.lock_timeout = 45
        expect(Delayed::Worker.lock_heartbeats?).to be true
        expect(Delayed::Worker.lock_expiry).to eq 45
      end

      it 'stays max_run_time when the backend does not support heartbeats' do
        Delayed::Worker.backend = :test
        Delayed::Worker.lock_heartbeat_interval = 10
        expect(Delayed::Worker.lock_heartbeats?).to be false
        expect(Delayed::Worker.lock_expiry).to eq Delayed::Worker.max_run_time
      end
    end

    describe '.validate_lock_heartbeats!' do
      it 'accepts no heartbeats' do
        expect { Delayed::Worker.validate_lock_heartbeats! }.not_to raise_error
      end

      it 'accepts a lock timeout of at least twice the interval' do
        Delayed::Worker.lock_heartbeat_interval = 10
        Delayed::Worker.lock_timeout = 20
        expect { Delayed::Worker.validate_lock_heartbeats! }.not_to raise_error
      end

      it 'rejects a lock timeout shorter than twice the interval' do
        Delayed::Worker.lock_heartbeat_interval = 10
        Delayed::Worker.lock_timeout = 19
        expect { Delayed::Worker.validate_lock_heartbeats! }.to raise_error(ArgumentError, /at least twice/)
      end

      it 'rejects a missing lock timeout' do
        Delayed::Worker.lock_heartbeat_interval = 10
        Delayed::Worker.lock_timeout = nil
        expect { Delayed::Worker.validate_lock_heartbeats! }.to raise_error(ArgumentError)
      end

      it 'rejects a non-positive interval' do
        Delayed::Worker.lock_heartbeat_interval = 0
        expect { Delayed::Worker.validate_lock_heartbeats! }.to raise_error(ArgumentError, /greater than 0/)
      end
    end
  end

  describe 'the default backend hooks' do
    it 'do not support heartbeats' do
      expect(Delayed::Backend::Test::Job.lock_heartbeats?).to be false
      expect { Delayed::Backend::Test::Job.touch_locks(['w']) }.to raise_error(NotImplementedError)
    end
  end

  describe Delayed::Dispatcher do
    let(:dispatcher) { described_class.new(:threads => 2, :sleep_delay => 0.05) }
    let(:messages) { [] }
    let(:job_class) { Delayed::Backend::SqliteFile::Job }

    before do
      SimpleJob.runs = 0
      allow(dispatcher).to receive(:say) { |text, level = 'info'| messages << [level, text] }
      Delayed::Worker.lock_heartbeat_interval = 0.1
      Delayed::Worker.lock_timeout = 0.5
    end

    def run_dispatcher
      Thread.new { dispatcher.run }.tap { |t| t.report_on_exception = false }
    end

    it 'refreshes the locks of running jobs while they run' do
      job = job_class.create!(:payload_object => ProcessJobs::SleepJob.new('long', 1.2))
      thread = run_dispatcher
      wait_for { job_class.find(job.id).locked_by }
      first = job_class.find(job.id).locked_at
      sleep 0.6 # longer than lock_timeout
      refreshed = job_class.find(job.id).locked_at
      dispatcher.stop
      Timeout.timeout(5) { thread.join }

      expect(refreshed).to be > first
      expect(job_class.where(:id => job.id)).to be_empty
    end

    it 'refreshes the locks of every worker thread in one call per heartbeat' do
      names = []
      allow(job_class).to receive(:touch_locks) { |n| names << n; 0 }
      thread = run_dispatcher
      sleep 0.35
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
      expect(names.size).to be_between(2, 4)
      expect(names).to all(eq(dispatcher.workers.map(&:name)))
    end

    it 'reserves jobs whose locks are older than lock_timeout' do
      stale = job_class.create!(:payload_object => SimpleJob.new, :locked_by => 'gone', :locked_at => job_class.db_time_now - 1)
      SimpleJob.runs = 0
      Delayed::Worker.exit_on_complete = true
      Timeout.timeout(5) { dispatcher.run }
      expect(job_class.where(:id => stale.id)).to be_empty
      expect(SimpleJob.runs).to eq 1
    ensure
      Delayed::Worker.exit_on_complete = false
    end

    it 'does not reserve jobs whose locks are fresh' do
      fresh = job_class.create!(:payload_object => SimpleJob.new, :locked_by => 'alive', :locked_at => job_class.db_time_now)
      Delayed::Worker.exit_on_complete = true
      Timeout.timeout(5) { dispatcher.run }
      expect(job_class.find(fresh.id).locked_by).to eq 'alive'
    ensure
      Delayed::Worker.exit_on_complete = false
    end

    it 'logs heartbeat errors and keeps beating' do
      calls = 0
      allow(job_class).to receive(:touch_locks) do
        calls += 1
        raise IOError, 'db hiccup' if calls == 1
        0
      end
      thread = run_dispatcher
      sleep 0.35
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
      expect(calls).to be >= 2
      expect(messages).to include(['error', 'Error while refreshing job locks: IOError: db hiccup'])
    end

    it 'stops the heartbeat thread when it stops' do
      thread = run_dispatcher
      sleep 0.15
      heartbeat = dispatcher.instance_variable_get(:@heartbeat)
      expect(heartbeat).to be_alive
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
      expect(heartbeat).not_to be_alive
    end

    it 'does not start a heartbeat when heartbeats are off' do
      Delayed::Worker.lock_heartbeat_interval = nil
      expect(job_class).not_to receive(:touch_locks)
      Delayed::Worker.exit_on_complete = true
      Timeout.timeout(5) { dispatcher.run }
      expect(dispatcher.instance_variable_get(:@heartbeat)).to be_nil
    ensure
      Delayed::Worker.exit_on_complete = false
    end

    it 'warns and runs without heartbeats when the backend does not support them' do
      allow(job_class).to receive(:lock_heartbeats?).and_return(false)
      expect(job_class).not_to receive(:touch_locks)
      Delayed::Worker.exit_on_complete = true
      Timeout.timeout(5) { dispatcher.run }
      expect(messages.map(&:last).grep(/does not support them; locks expire after max_run_time/).size).to eq 1
    ensure
      Delayed::Worker.exit_on_complete = false
    end

    it 'refuses to run with invalid heartbeat settings' do
      Delayed::Worker.lock_timeout = 0.1
      expect { dispatcher.run }.to raise_error(ArgumentError, /at least twice/)
    end

    it 'reserves with the lock timeout as the lock expiry' do
      expect(job_class).to receive(:reserve_batch).with(anything, 0.5).at_least(:once).and_return([])
      Delayed::Worker.exit_on_complete = true
      Timeout.timeout(5) { dispatcher.run }
    ensure
      Delayed::Worker.exit_on_complete = false
    end

    describe '#work_off' do
      it 'refreshes locks while running jobs inline' do
        job = job_class.create!(:payload_object => ProcessJobs::SleepJob.new('inline', 0.5))
        touched = []
        allow(job_class).to receive(:touch_locks).and_wrap_original { |m, n| touched << n; m.call(n) }
        expect(dispatcher.work_off(1, dispatcher.workers.first)).to eq [1, 0]
        expect(touched).not_to be_empty
        expect(job_class.where(:id => job.id)).to be_empty
        expect(dispatcher.instance_variable_get(:@heartbeat)).not_to be_alive
      end
    end
  end

  describe 'a worker whose lock was taken over' do
    let(:job_class) { Delayed::Backend::SqliteFile::Job }
    let(:stale) { Delayed::Worker.new.tap { |w| w.name = 'stale' } }
    let(:logged) { [] }

    before do
      SimpleJob.runs = 0
      allow(stale).to receive(:say) { |text, *| logged << text }
    end

    it 'logs that it left the job to the new owner' do
      job = job_class.create!(:payload_object => SimpleJob.new, :locked_by => 'stale', :locked_at => job_class.db_time_now)
      job_class.find(job.id).lock_exclusively!(0, 'new owner')
      stale.run(job)
      expect(logged.grep(/was finished here, but its lock expired and another worker reserved it; leaving the job to that worker/)).not_to be_empty
      expect(job_class.find(job.id).locked_by).to eq 'new owner'
    end

    it 'writes unlocked jobs without a guard, as before' do
      job = job_class.create!(:payload_object => SimpleJob.new)
      expect(job).not_to receive(:destroy_if_locked_by)
      stale.run(job)
      expect(job_class.where(:id => job.id)).to be_empty
    end

    it "recovering a dead worker's job does not touch it once another worker took it" do
      job = job_class.create!(:payload_object => SimpleJob.new, :locked_by => 'dead', :locked_at => job_class.db_time_now - 3600)
      allow(job_class).to receive(:locked_jobs).and_wrap_original do |m, name|
        m.call(name).tap { job_class.find(job.id).lock_exclusively!(0, 'new owner') }
      end
      status = double(:signaled? => true, :termsig => 9)
      Delayed::Worker.recover_jobs_of(['dead'], Delayed::ProcessExitError.new('dj.1', 1, status))
      saved = job_class.find(job.id)
      expect([saved.locked_by, saved.attempts]).to eq ['new owner', 0]
    end
  end
end
