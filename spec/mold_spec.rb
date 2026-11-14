require 'helper'

# Worker.mold (see Launcher::Mold and Launcher::MoldSupervisor); the forking
# itself is covered by spec/processes/mold_spec.rb.
describe 'Mold process (Worker.mold)' do
  describe 'the setting' do
    it 'is off by default, set by Worker.new and reset by Worker.reset' do
      expect(Delayed::Worker.mold).to be_nil
      Delayed::Worker.new(:mold => [10, 20])
      expect(Delayed::Worker.mold).to eq [10, 20]
      Delayed::Worker.reset
      expect(Delayed::Worker.mold).to be_nil
    end

    it 'normalises to thresholds' do
      expect(Delayed::Worker.mold_thresholds(nil)).to be_nil
      expect(Delayed::Worker.mold_thresholds(false)).to be_nil
      expect(Delayed::Worker.mold_thresholds(true)).to eq [1000]
      expect(Delayed::Worker.mold_thresholds(50)).to eq [50]
      expect(Delayed::Worker.mold_thresholds([5, 10])).to eq [5, 10]
    end

    [0, -1, 1.5, 'x', []].each do |value|
      it "rejects #{value.inspect}" do
        expect { Delayed::Worker.validate_settings!(:mold => value) }.to raise_error(ArgumentError, /mold must be true or job counts greater than 0/)
      end
    end
  end

  describe 'the command line and rake' do
    it 'parses --mold, with or without thresholds' do
      expect(Delayed::Command.new(%w[--fork --mold]).instance_variable_get(:@options)[:mold]).to be true
      expect(Delayed::Command.new(%w[--fork --mold=100,200]).instance_variable_get(:@options)[:mold]).to eq [100, 200]
      expect { Delayed::Command.new(%w[--fork --mold=0]) }.to raise_error(ArgumentError, '--mold must be job counts greater than 0')
    end

    it 'parses MOLD' do
      expect(Delayed::LaunchOptions.parse_mold(' 30 ', 'MOLD')).to eq 30
      expect { Delayed::LaunchOptions.parse_mold('x', 'MOLD') }.to raise_error(ArgumentError, 'MOLD must be job counts greater than 0')
    end
  end

  describe 'launcher guards' do
    it 'refuses the daemonized launcher' do
      expect { Delayed::Launcher::Daemonized.new(:mold => true) }.to raise_error(ArgumentError, '--mold is for --fork mode')
    end

    it 'refuses --identifier' do
      launcher = Delayed::Launcher::Forking.new(:mold => true, :identifier => '1')
      expect { launcher.launch }.to raise_error(ArgumentError, 'mold cannot be used with --identifier')
    end

    it 'refuses platforms without fork', :fork_guard do
      launcher = Delayed::Launcher::Forking.new(:mold => true)
      allow(launcher).to receive(:fork_available?).and_return(false)
      expect { launcher.launch }.to raise_error(NotImplementedError, /mold needs fork/)
    end

    it 'forks even one process' do
      expect(Delayed::Launcher::Forking.new(:mold => true).send(:forking?)).to be true
      expect(Delayed::Launcher::Forking.new({}).send(:forking?)).to be false
    end
  end

  describe Delayed::Dispatcher do
    let(:log) { Concurrent::Array.new }

    before do
      Delayed::Job.delete_all
      GateJob.reset
    end

    it 'counts jobs performed, never reset by the stats report' do
      Delayed::Worker.exit_on_complete = true
      3.times { |i| Delayed::Job.enqueue(SimpleJob.new, :priority => i) }
      dispatcher = described_class.new(:sleep_delay => 0.01)
      capture_say(log, *and_workers(dispatcher))
      dispatcher.run
      expect(dispatcher.jobs_performed).to eq 3
    ensure
      Delayed::Worker.exit_on_complete = nil
    end

    it 'promotes by stopping: queued jobs are released, running jobs finish' do
      jobs = Array.new(3) { |i| Delayed::Job.enqueue(GateJob.new(i, true)) }
      events = []
      subscriber = ActiveSupport::Notifications.subscribe('jobs_released.delayed_job') { |*, payload| events << payload }
      dispatcher = described_class.new(:threads => 1, :prefetch => 2, :sleep_delay => 0.01)
      capture_say(log, *and_workers(dispatcher))
      thread = Thread.new { dispatcher.run }
      Timeout.timeout(10) { GateJob.started.pop }
      Timeout.timeout(10) { sleep 0.01 until Delayed::Job.where.not(:locked_by => nil).count == 3 } if Delayed::Job.respond_to?(:where)
      dispatcher.promote
      expect(dispatcher).to be_promoted
      GateJob.release = true
      Timeout.timeout(10) { thread.join }

      expect(dispatcher.jobs_performed).to eq 1
      expect(events.map { |e| e[:reason] }).to include 'promotion'
      expect(log.join("\n")).to include 'queued job(s) on promotion to mold'
      expect(jobs.drop(1).map { |job| Delayed::Job.find(job.id).locked_by }).to all(be_nil)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      Delayed::Worker.prefetch = 0
    end

    it 'does not promote once stopping, and a stop signal cancels a promotion' do
      dispatcher = described_class.new
      dispatcher.stop
      dispatcher.promote
      expect(dispatcher).not_to be_promoted

      dispatcher = described_class.new
      dispatcher.promote
      dispatcher.send(:handle_pending_signal, 'TERM')
      expect(dispatcher).not_to be_promoted
    end
  end

  describe Delayed::ReportedStatus do
    it 'reads like Process::Status' do
      exited = described_class.new(10, 3, nil)
      killed = described_class.new(11, nil, 9)
      unknown = described_class.new(12, nil, nil)

      expect([exited.success?, exited.signaled?, exited.exitstatus, exited.to_s]).to eq [false, false, 3, 'pid 10 exit 3']
      expect([killed.success?, killed.signaled?, killed.termsig, killed.to_s]).to eq [false, true, 9, 'pid 11 SIGKILL (signal 9)']
      expect(described_class.new(13, 0, nil)).to be_success
      expect(unknown.to_s).to eq 'pid 12 exit unknown'
    end

    it 'gives ProcessExitError a reason' do
      expect(Delayed::ProcessExitError.new('delayed_job.1', 10, described_class.new(10, 3, nil)).message).
        to eq 'Child process delayed_job.1 (pid 10) exited with status 3'
      expect(Delayed::ProcessExitError.new('delayed_job.1', 11, described_class.new(11, nil, 9)).message).
        to eq 'Child process delayed_job.1 (pid 11) was killed by signal 9'
      expect(Delayed::ProcessExitError.new('delayed_job.1', 12, described_class.new(12, nil, nil)).message).
        to eq 'Child process delayed_job.1 (pid 12) exited (status unknown: its mold died first)'
    end
  end

  it 'encodes fork records in a fixed size' do
    record = [7, Delayed::Launcher::Mold::NO_POOL].pack(Delayed::Launcher::Mold::FORK_RECORD)
    expect(record.bytesize).to eq Delayed::Launcher::Mold::FORK_RECORD_BYTES
    expect(record.unpack(Delayed::Launcher::Mold::FORK_RECORD)).to eq [7, Delayed::Launcher::Mold::NO_POOL]
  end
end
