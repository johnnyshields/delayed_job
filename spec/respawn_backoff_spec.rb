require 'helper'

# A child process that dies soon after starting is replaced after a delay
# that doubles with each such death in a row (see Launcher::Forking).
describe Delayed::Launcher::Forking, 'replacing child processes that keep dying' do
  subject(:launcher) { described_class.new(:processes => 2) }

  let(:logger) { instance_double(Logger, :info => nil, :warn => nil, :error => nil) }
  let(:crashed) { double('Process::Status', :signaled? => false, :termsig => nil, :exitstatus => 3, :success? => false, :to_s => 'exit 3') }
  let(:now) { [1000.0] }
  let(:waits) { [] }
  let(:pids) { (200..300).to_a }

  before do
    allow(launcher).to receive(:logger).and_return(logger)
    allow(launcher).to receive(:recover_jobs_of_worker)
    allow(launcher).to receive(:monotonic_now) { now.first }
    allow(launcher).to receive(:fork_worker) { pids.shift }
    allow(launcher).to receive(:sleep) { |seconds|
      waits << seconds
      now[0] += seconds
    }
    launcher.instance_variable_set(:@stopped, false)
  end

  def start_child
    launcher.send(:add_worker, {})
  end

  # Child `pid` exits after `uptime` seconds; returns its replacement's pid.
  def dies_after(pid, uptime)
    now[0] += uptime
    launcher.send(:workers).delete(pid)
    launcher.send(:replace_worker, 'delayed_job.x', pid, {}, crashed)
  end

  def warnings
    messages = []
    allow(logger).to receive(:warn) { |m| messages << m }
    messages
  end

  it 'replaces a child process that ran long enough at once' do
    pid = start_child
    expect(dies_after(pid, 30)).to eq 201
    expect(waits).to be_empty
  end

  it 'waits 1s before replacing a child process that died within RESPAWN_MIN_UPTIME of starting' do
    logged = warnings
    pid = start_child
    expect(dies_after(pid, 2)).to eq 201
    expect(waits.sum).to be_within(0.01).of(1)
    expect(logged).to eq ['Child process delayed_job.x (pid 200) died 2.0s after starting (1 time(s) in a row); waiting 1s before replacing it']
  end

  it 'doubles the wait with each quick death in a row, up to RESPAWN_MAX_DELAY' do
    pid = start_child
    delays = Array.new(9) do
      before = waits.sum
      pid = dies_after(pid, 1)
      (waits.sum - before).round
    end
    expect(delays).to eq [1, 2, 4, 8, 16, 32, 60, 60, 60]
  end

  it 'resets the wait once a replacement stays up' do
    pid = start_child
    3.times { pid = dies_after(pid, 1) } # Waits 1, 2, 4.
    pid = dies_after(pid, 60) # Healthy: replaced at once.
    before = waits.sum
    dies_after(pid, 1)
    expect((waits.sum - before).round).to eq 1
  end

  it 'counts the uptime from the start, not including the wait before it' do
    pid = start_child
    pid = dies_after(pid, 1) # Waited 1s; the replacement starts after that.
    before = waits.sum
    dies_after(pid, described_class::RESPAWN_MIN_UPTIME + 1)
    expect(waits.sum).to eq before
  end

  it 'keeps a separate streak for each line of replacements' do
    healthy = start_child
    now[0] += 100 # Up for a while before its sibling starts crash looping.
    crashing = start_child
    crashing = dies_after(crashing, 1)
    crashing = dies_after(crashing, 1) # 2s.
    before = waits.sum
    dies_after(healthy, 0)
    expect(waits.sum).to eq before # Its sibling's crash loop doesn't delay it.
    before = waits.sum
    dies_after(crashing, 1)
    expect((waits.sum - before).round).to eq 4
  end

  it 'does not replace it when stopped while waiting' do
    pid = start_child
    allow(launcher).to receive(:sleep) { |_s| launcher.instance_variable_set(:@stopped, true) }
    expect(launcher).to receive(:add_worker).never
    expect(dies_after(pid, 1)).to be_nil
  end

  it 'publishes the delay in fork_replaced' do
    events = []
    subscription = ActiveSupport::Notifications.subscribe('fork_replaced.delayed_job') { |*args| events << args.last }
    pid = start_child
    pid = dies_after(pid, 1)
    dies_after(pid, 1)
    expect(events.map { |e| e[:delay] }).to eq [1, 2]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end

  it 'treats a child process with no recorded start as long-lived' do
    expect(launcher.send(:replace_worker, 'delayed_job.x', 999, {}, crashed)).to eq 200
    expect(waits).to be_empty
  end

  describe 'in the run loop' do
    it 'stops waiting, and exits, when the launcher is stopped meanwhile' do
      pid = start_child
      launcher.send(:workers).replace(pid => ['delayed_job.0', {}])
      calls = 0
      allow(Process).to receive(:wait2) do
        raise 'waited for children after being stopped' if (calls += 1) > 1
        now[0] += 1
        [pid, crashed]
      end
      allow(launcher).to receive(:sleep) { |_s| launcher.instance_variable_set(:@stopped, true) }
      expect(launcher).not_to receive(:add_worker)
      expect { Timeout.timeout(5) { launcher.send(:run_loop) } }.not_to raise_error
    end
  end

  describe '#wait_unless_stopped' do
    before { allow(launcher).to receive(:sleep).and_call_original }
    before { allow(launcher).to receive(:monotonic_now).and_call_original }

    it 'sleeps for the given time' do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(launcher.send(:wait_unless_stopped, 0.3)).to be true
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.29
    end

    it 'returns false soon after the launcher is stopped' do
      Thread.new do
        sleep 0.2
        launcher.instance_variable_set(:@stopped, true)
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(launcher.send(:wait_unless_stopped, 30)).to be false
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    end
  end
end
