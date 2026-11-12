require 'helper'

describe 'Worker processes whose parent goes away' do
  describe Delayed::Dispatcher do
    let(:messages) { [] }

    def dispatcher(options = {})
      described_class.new(options).tap do |d|
        allow(d).to receive(:say) { |text, level = 'info'| messages << [level, text] }
      end
    end

    describe '#supervisor_pid' do
      it 'is nil by default' do
        expect(dispatcher.supervisor_pid).to be_nil
      end

      it 'is set from the :supervisor_pid option' do
        expect(dispatcher(:supervisor_pid => 42).supervisor_pid).to eq 42
      end
    end

    describe '#supervisor_gone?' do
      it 'is false when not supervised' do
        d = dispatcher
        expect(d.send(:supervisor_gone?)).to be false
        expect(d).not_to be_stop
      end

      it 'is false while the parent is the supervisor' do
        d = dispatcher(:supervisor_pid => Process.ppid)
        expect(d.send(:supervisor_gone?)).to be false
        expect(d).not_to be_stop
      end

      it 'stops the dispatcher, with a warning, once the process has been re-parented' do
        d = dispatcher(:supervisor_pid => Process.ppid + 1)
        expect(d.send(:supervisor_gone?)).to be true
        expect(d).to be_stop
        expect(d).not_to be_quit
        expect(messages).to include(['warn', "Parent process #{Process.ppid + 1} is gone; stopping"])
      end
    end

    describe '#poll_wait' do
      before { Delayed::Worker.sleep_delay = 5 }
      after { Delayed::Worker.reset }

      it 'waits for a worker to free up, or sleep_delay when the queue ran dry' do
        d = dispatcher
        expect(d.send(:poll_wait, false)).to be_nil
        expect(d.send(:poll_wait, true)).to eq 5
      end

      it 'checks on the supervisor at least every SUPERVISOR_CHECK_INTERVAL seconds' do
        d = dispatcher(:supervisor_pid => Process.ppid)
        interval = described_class::SUPERVISOR_CHECK_INTERVAL
        expect(d.send(:poll_wait, false)).to eq interval
        expect(d.send(:poll_wait, true)).to eq interval
        Delayed::Worker.sleep_delay = 0.1
        expect(d.send(:poll_wait, true)).to eq 0.1
      end
    end

    describe '#run' do
      before { Delayed::Job.delete_all }

      it 'stops when its parent goes away, letting running jobs finish' do
        stub_const('Delayed::Dispatcher::SUPERVISOR_CHECK_INTERVAL', 0.05)
        Delayed::Job.enqueue(ConcurrencyJob.new(1))
        ConcurrencyJob.reset(0.3)
        parent = Process.ppid
        d = dispatcher(:supervisor_pid => parent, :sleep_delay => 30)
        thread = Thread.new { d.run }
        sleep 0.1 until ConcurrencyJob.running == 1
        allow(Process).to receive(:ppid).and_return(1)
        expect(Timeout.timeout(5) { thread.join }).to eq thread

        expect(ConcurrencyJob.runs[1]).to eq 1
        expect(ConcurrencyJob.running).to eq 0
        expect(Delayed::Job.count).to eq 0
        expect(messages.map(&:last)).to include "Parent process #{parent} is gone; stopping"
      end

      it 'does not start when its parent is already gone' do
        d = dispatcher(:supervisor_pid => Process.ppid + 1)
        expect(Delayed::Job).not_to receive(:reserve_batch)
        Timeout.timeout(5) { d.run }
        expect(d).to be_stop
      end
    end
  end

  describe Delayed::Launcher::Forking do
    subject(:launcher) { described_class.new(:processes => 2) }

    it 'supervises the workers it forks with its own pid' do
      expect(launcher.send(:supervisor_pid)).to eq Process.pid
    end

    it 'passes its pid to the dispatchers of the workers it forks' do
      allow(Dir).to receive(:chdir)
      allow(Delayed::Worker).to receive(:after_fork)
      allow(launcher).to receive(:setup_logger)
      expect(Delayed::Dispatcher).to receive(:new).with(hash_including(:supervisor_pid => Process.pid))
                                                  .and_return(double(:name_prefix= => nil, :start => nil))
      launcher.send(:run_worker, 'delayed_job.0', {})
    end

    it 'records its pid before forking, so workers see the right parent' do
      allow(launcher).to receive(:setup_logger)
      allow(launcher).to receive(:prepare_for_fork)
      allow(launcher).to receive(:setup_workers)
      allow(launcher).to receive(:run_loop)
      allow(launcher).to receive(:trap_signals)
      allow(Delayed::Worker).to receive(:before_fork)
      launcher.launch
      expect(launcher.instance_variable_get(:@supervisor_pid)).to eq Process.pid
    end
  end

  describe Delayed::Launcher::Daemonized do
    it 'does not supervise daemonized workers, which are detached from their parent' do
      expect(described_class.new({}).send(:supervisor_pid)).to be_nil
    end
  end
end
