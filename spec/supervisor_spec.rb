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

    describe '#wait_for_event' do
      it 'returns false when the timeout expires without an event' do
        d = dispatcher
        _, seen = d.send(:snapshot)
        expect(d.send(:wait_for_event, seen, 0.01)).to be false
      end

      it 'returns true at once when an event happened since the snapshot' do
        d = dispatcher
        _, seen = d.send(:snapshot)
        d.send(:synchronize) { d.send(:signal_event) }
        expect(d.send(:wait_for_event, seen, 5)).to be true
      end

      it 'returns true at once when stopped' do
        d = dispatcher
        _, seen = d.send(:snapshot)
        d.stop
        expect(d.send(:wait_for_event, seen, 5)).to be true
      end

      it 'returns true when woken up by an event' do
        d = dispatcher
        _, seen = d.send(:snapshot)
        Thread.new { sleep 0.05; d.send(:synchronize) { d.send(:signal_event) } }
        expect(Timeout.timeout(5) { d.send(:wait_for_event, seen, nil) }).to be true
      end
    end

    describe '#wait_before_next_poll' do
      after { Delayed::Worker.reset }

      def timed
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        yield
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end

      def waits_of(d)
        timeouts = []
        allow(d).to receive(:wait_for_event).and_wrap_original do |m, seen, timeout|
          timeouts << timeout
          m.call(seen, timeout)
        end
        timeouts
      end

      it 'waits sleep_delay when the queue ran dry, in one wait when not supervised' do
        Delayed::Worker.sleep_delay = 0.2
        d = dispatcher
        timeouts = waits_of(d)
        _, seen = d.send(:snapshot)
        expect(timed { d.send(:wait_before_next_poll, seen, true) }).to be_within(0.15).of(0.2)
        expect(timeouts.size).to eq 1
        expect(timeouts.first).to be_within(0.01).of(0.2)
      end

      it 'waits for an event (no timeout) while workers are busy, when not supervised' do
        d = dispatcher
        timeouts = waits_of(d)
        _, seen = d.send(:snapshot)
        Thread.new { sleep 0.1; d.send(:synchronize) { d.send(:signal_event) } }
        Timeout.timeout(5) { d.send(:wait_before_next_poll, seen, false) }
        expect(timeouts).to eq [nil]
      end

      it 'checks on the supervisor every SUPERVISOR_CHECK_INTERVAL while the queue is dry, still waiting sleep_delay in all' do
        stub_const('Delayed::Dispatcher::SUPERVISOR_CHECK_INTERVAL', 0.05)
        Delayed::Worker.sleep_delay = 0.3
        d = dispatcher(:supervisor_pid => Process.ppid)
        timeouts = waits_of(d)
        allow(d).to receive(:supervisor_gone?).and_call_original
        _, seen = d.send(:snapshot)
        expect(timed { d.send(:wait_before_next_poll, seen, true) }).to be_within(0.15).of(0.3)
        expect(timeouts.size).to be >= 5
        expect(timeouts).to all(be <= 0.05)
        expect(d).to have_received(:supervisor_gone?).at_least(4).times
      end

      it 'checks on the supervisor every SUPERVISOR_CHECK_INTERVAL while workers are busy' do
        stub_const('Delayed::Dispatcher::SUPERVISOR_CHECK_INTERVAL', 0.05)
        d = dispatcher(:supervisor_pid => Process.ppid)
        timeouts = waits_of(d)
        _, seen = d.send(:snapshot)
        Thread.new { sleep 0.3; d.send(:synchronize) { d.send(:signal_event) } }
        Timeout.timeout(5) { d.send(:wait_before_next_poll, seen, false) }
        expect(timeouts.size).to be >= 3
        expect(timeouts).to all(eq 0.05)
      end

      it 'stops waiting, and stops the dispatcher, as soon as the supervisor is gone' do
        stub_const('Delayed::Dispatcher::SUPERVISOR_CHECK_INTERVAL', 0.05)
        Delayed::Worker.sleep_delay = 30
        d = dispatcher(:supervisor_pid => Process.ppid)
        _, seen = d.send(:snapshot)
        Thread.new { sleep 0.1; allow(Process).to receive(:ppid).and_return(1) }
        expect(timed { Timeout.timeout(5) { d.send(:wait_before_next_poll, seen, true) } }).to be < 1
        expect(d).to be_stop
      end

      it 'returns early when a worker frees up' do
        Delayed::Worker.sleep_delay = 30
        d = dispatcher(:supervisor_pid => Process.ppid)
        _, seen = d.send(:snapshot)
        Thread.new { sleep 0.1; d.send(:synchronize) { d.send(:signal_event) } }
        expect(timed { Timeout.timeout(5) { d.send(:wait_before_next_poll, seen, true) } }).to be < 1
      end

      it 'returns early when stopped' do
        Delayed::Worker.sleep_delay = 30
        d = dispatcher(:supervisor_pid => Process.ppid)
        _, seen = d.send(:snapshot)
        Thread.new { sleep 0.1; d.stop }
        expect(timed { Timeout.timeout(5) { d.send(:wait_before_next_poll, seen, true) } }).to be < 1
      end
    end

    describe 'idle polling' do
      before { Delayed::Job.delete_all }
      after { Delayed::Worker.reset }

      # Runs an idle dispatcher for `seconds` and returns how often it polled.
      def polls_in(seconds, options)
        stub_const('Delayed::Dispatcher::SUPERVISOR_CHECK_INTERVAL', 0.05)
        polls = 0
        allow(Delayed::Job).to receive(:reserve_batch).and_wrap_original { |m, *args| polls += 1; m.call(*args) }
        d = dispatcher(options.merge(:threads => 2, :sleep_delay => 0.4))
        thread = Thread.new { d.run }
        sleep seconds
        d.stop
        Timeout.timeout(5) { thread.join }
        polls
      end

      it 'polls every sleep_delay when supervised, not every SUPERVISOR_CHECK_INTERVAL' do
        # At 0, 0.4 and 0.8s (8 polls per interval would be 20).
        expect(polls_in(1.0, :supervisor_pid => Process.ppid)).to be_between(2, 4)
      end

      it 'polls as often when supervised as when not' do
        supervised = polls_in(1.0, :supervisor_pid => Process.ppid)
        unsupervised = polls_in(1.0, {})
        expect((supervised - unsupervised).abs).to be <= 1
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
