require 'helper'

# A job that runs until told to finish, recording what happened to it.
class GateJob
  cattr_accessor :started, :finished, :interrupted, :release
  def self.reset
    self.started = Queue.new
    self.finished = []
    self.interrupted = []
    self.release = false
  end
  reset

  attr_accessor :key, :stubborn

  def initialize(key, stubborn = false)
    self.key = key
    self.stubborn = stubborn
  end

  def perform
    self.class.started << key
    if stubborn
      # Ignores interrupts, as a job that rescues Exception would.
      loop do
        begin
          sleep 0.01 until self.class.release
          break
        rescue Exception # rubocop:disable RescueException
          next
        end
      end
    else
      begin
        sleep 0.01 until self.class.release
      rescue StandardError
        raise 'a StandardError rescue must not catch the interrupt'
      rescue Exception # rubocop:disable RescueException
        self.class.interrupted << key
        raise
      end
    end
    self.class.finished << key
  end
end

describe 'Stopping a worker' do
  let(:dispatcher) { Delayed::Dispatcher.new(:threads => 2, :sleep_delay => 0.05) }
  let(:log) { [] }

  before do
    Delayed::Job.delete_all
    GateJob.reset
    allow(dispatcher).to receive(:say) { |text, level = 'info'| log << [level, text] }
    dispatcher.workers.each { |w| allow(w).to receive(:say) { |text, level = 'info'| log << [level, text] } }
  end

  after do
    GateJob.release = true
    Delayed::Worker.reset
  end

  def enqueue(*jobs)
    jobs.map { |job| Delayed::Job.enqueue(job) }
  end

  # Runs the dispatcher on a thread until `count` jobs have started.
  def run_until_started(count)
    thread = Thread.new { dispatcher.run }
    Timeout.timeout(5) { count.times { GateJob.started.pop } }
    thread
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  describe Delayed::ShutdownInterrupt do
    it 'is not a StandardError, so `rescue => e` in jobs does not catch it' do
      expect(described_class.ancestors).not_to include StandardError
      expect(described_class.ancestors).to include Exception
    end
  end

  describe 'Worker#run' do
    it 're-raises the interrupt instead of recording a failed attempt' do
      job = Delayed::Job.enqueue(SimpleJob.new)
      allow(job).to receive(:invoke_job).and_raise(Delayed::ShutdownInterrupt)
      worker = Delayed::Worker.new
      expect(worker).not_to receive(:fail_attempt)
      expect { worker.run(job) }.to raise_error(Delayed::ShutdownInterrupt)
      expect(job.attempts).to eq 0
    end
  end

  context 'without a shutdown timeout (the default)' do
    it 'waits for running jobs to finish' do
      job, = enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      dispatcher.stop
      sleep 0.5
      expect(thread).to be_alive
      GateJob.release = true
      Timeout.timeout(5) { thread.join }

      expect(GateJob.finished).to eq [:a]
      expect(GateJob.interrupted).to be_empty
      expect(Delayed::Job.all).not_to include(job)
    end
  end

  context 'with a shutdown timeout' do
    before { Delayed::Worker.shutdown_timeout = 0.3 }

    it 'lets jobs that finish in time complete' do
      enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      dispatcher.stop
      GateJob.release = true
      Timeout.timeout(5) { thread.join }
      expect(GateJob.finished).to eq [:a]
      expect(GateJob.interrupted).to be_empty
    end

    it 'interrupts jobs still running after it, and releases them for another worker' do
      jobs = enqueue(GateJob.new(:a), GateJob.new(:b))
      run_at = jobs.map(&:run_at)
      thread = run_until_started(2)
      took = elapsed do
        dispatcher.stop
        Timeout.timeout(5) { thread.join }
      end

      expect(took).to be_between(0.25, 2)
      expect(GateJob.interrupted).to contain_exactly(:a, :b)
      expect(GateJob.finished).to be_empty
      expect(Delayed::Job.all).to match_array(jobs)
      expect(jobs.map(&:locked_by)).to eq [nil, nil]
      expect(jobs.map(&:locked_at)).to eq [nil, nil]
      expect(jobs.map(&:attempts)).to eq [0, 0]
      expect(jobs.map(&:run_at)).to eq run_at
      expect(jobs.map(&:last_error)).to eq [nil, nil]
      expect(log).to include(['warn', 'Shutdown timeout of 0.3s exceeded: interrupting 2 running job(s)'])
      expect(log.map(&:last).grep(/interrupted by shutdown; released for another worker/).size).to eq 2
    end

    it 'does not run :error callbacks or count the interruption as a failure' do
      enqueue(GateJob.new(:a))
      errors = []
      dispatcher # Worker.new resets the lifecycle
      Delayed::Worker.lifecycle.before(:error) { |_w, job| errors << job }
      thread = run_until_started(1)
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
      expect(errors).to be_empty
    end

    it 'counts the timeout from when the stop was requested' do
      enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      dispatcher.stop
      sleep 0.4 # past the timeout before the dispatcher even looks
      expect(Timeout.timeout(5) { elapsed { thread.join } }).to be < 0.3
    end

    it 'treats 0 as "interrupt at once"' do
      Delayed::Worker.shutdown_timeout = 0
      enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      took = elapsed do
        dispatcher.stop
        Timeout.timeout(5) { thread.join }
      end
      expect(took).to be < 0.25
      expect(GateJob.interrupted).to eq [:a]
    end

    context 'when a job does not stop when interrupted' do
      before { stub_const('Delayed::Dispatcher::INTERRUPT_GRACE', 0.3) }

      it 'gives up on it after INTERRUPT_GRACE seconds and leaves it locked' do
        job, = enqueue(GateJob.new(:stubborn, true))
        thread = run_until_started(1)
        took = elapsed do
          dispatcher.stop
          Timeout.timeout(5) { thread.join }
        end

        expect(took).to be_between(0.5, 2)
        expect(job.locked_by).not_to be_nil
        expect(log).to include(['error', '1 job(s) did not stop within 0.3s of being interrupted; ' \
                                         'leaving them locked until max_run_time expires'])
      ensure
        GateJob.release = true
        dispatcher.instance_variable_get(:@threads).each { |t| t.join(5) }
      end
    end

    it 'logs and carries on when releasing a job fails' do
      enqueue(GateJob.new(:a))
      allow(Delayed::Job).to receive(:clear_locks!).and_raise(IOError, 'db down')
      thread = run_until_started(1)
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
      expect(log.select { |level, _| level == 'error' }.map(&:last))
        .to include(/\ACould not release the jobs of .+ thread:\d: IOError: db down\z/)
    end
  end

  describe 'interrupts arriving outside of a job' do
    let(:reported) { [] }

    # Runs for 0.2s, recording whether it finished or was interrupted.
    class NapJob
      cattr_accessor :outcomes
      self.outcomes = Queue.new

      def perform
        sleep 0.2
        self.class.outcomes << :finished
      rescue Exception # rubocop:disable RescueException
        self.class.outcomes << :interrupted
        raise
      end
    end

    before do
      NapJob.outcomes = Queue.new
      SimpleJob.runs = 0
      Delayed::Worker.on_thread_error = ->(error, info) { reported << [error, info] }
    end

    def worker_threads
      dispatcher.instance_variable_get(:@threads)
    end

    def start
      @thread = Thread.new { dispatcher.run }
      Timeout.timeout(5) { sleep 0.01 until worker_threads.size == 2 && worker_threads.all? { |t| t.status == 'sleep' } }
      @thread
    end

    def stop_and_join
      dispatcher.stop
      Timeout.timeout(5) { @thread.join }
    end

    after { stop_and_join if @thread && @thread.alive? }

    [Delayed::ShutdownInterrupt.new('late'), SignalException.new('TERM')].each do |interrupt|
      it "ignores a #{interrupt.class} raised into an idle worker thread" do
        start
        worker_threads.each { |t| t.raise(interrupt.class, interrupt.message) }
        sleep 0.1
        expect(worker_threads).to all(be_alive)

        job = Delayed::Job.enqueue(SimpleJob.new)
        Timeout.timeout(5) { sleep 0.01 while Delayed::Job.all.include?(job) }
        stop_and_join
        expect(reported).to be_empty
        expect(dispatcher.instance_variable_get(:@thread_error)).to be_nil
      end

      it "does not carry a #{interrupt.class} that arrived between jobs into the next job" do
        start
        worker_threads.each { |t| t.raise(interrupt.class, interrupt.message) }
        sleep 0.05
        jobs = Array.new(2) { Delayed::Job.enqueue(NapJob.new) }
        outcomes = Timeout.timeout(5) { Array.new(2) { NapJob.outcomes.pop } }
        expect(outcomes).to eq [:finished, :finished]
        Timeout.timeout(5) { sleep 0.01 until (Delayed::Job.all & jobs).empty? }
        expect(reported).to be_empty
      end
    end

    it 'does not interrupt a thread recording the job it just finished' do
      dispatcher.workers.each { |w| allow(w).to receive(:say) }
      recording = Queue.new
      gate = Queue.new
      allow(dispatcher).to receive(:job_finished).and_wrap_original do |m, *args|
        recording << Thread.current
        gate.pop
        m.call(*args)
      end
      job = Delayed::Job.enqueue(SimpleJob.new)
      start
      thread = Timeout.timeout(5) { recording.pop }
      thread.raise(Delayed::ShutdownInterrupt, 'late')
      sleep 0.05
      gate << true
      Timeout.timeout(5) { sleep 0.01 while dispatcher.send(:in_flight) > 0 }

      expect(thread).to be_alive
      expect(Delayed::Job.all).not_to include(job)
      expect(SimpleJob.runs).to eq 1
      expect(dispatcher.send(:snapshot).first).to match_array dispatcher.workers # Both idle again.
      allow(dispatcher).to receive(:job_finished).and_call_original
      stop_and_join
      expect(reported).to be_empty
      expect(log.map(&:last).grep(/interrupted by shutdown/)).to be_empty
    end

    it "lets the :execute callbacks (e.g. ClearLocks) finish when interrupted" do
      dispatcher # Worker.new resets the lifecycle.
      exiting = Queue.new
      gate = Queue.new
      cleared = Queue.new
      Delayed::Worker.lifecycle.after(:execute) do |worker|
        exiting << Thread.current
        gate.pop
        cleared << worker.name
      end
      start
      dispatcher.stop
      threads = Timeout.timeout(5) { Array.new(2) { exiting.pop } }
      threads.each { |t| t.raise(Delayed::ShutdownInterrupt, 'late') }
      sleep 0.05
      2.times { gate << true }
      Timeout.timeout(5) { @thread.join }

      expect(Array.new(cleared.size) { cleared.pop }).to match_array dispatcher.workers.map(&:name)
      expect(reported).to be_empty
      expect(dispatcher.instance_variable_get(:@thread_error)).to be_nil
    end

    it 'still interrupts a running job, and lets the thread release it' do
      Delayed::Worker.shutdown_timeout = 0
      job, = enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
      expect(GateJob.interrupted).to eq [:a]
      expect(job.reload.locked_by).to be_nil
      expect(reported).to be_empty
    end

    it 'still interrupts a running job with a signal (Worker.raise_signal_exceptions)' do
      dispatcher.workers.each { |w| allow(w).to receive(:say) }
      enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      busy = dispatcher.instance_variable_get(:@running).keys.first
      busy.raise(SignalException, 'TERM')
      Timeout.timeout(5) { sleep 0.01 until GateJob.interrupted == [:a] }
      dispatcher.stop
      Timeout.timeout(5) { thread.join }
    end
  end

  describe 'interrupts arriving after the job ran' do
    let(:reported) { [] }
    let(:paused) { Queue.new }

    before do
      SimpleJob.runs = 0
      Delayed::Worker.on_thread_error = ->(error, info) { reported << [error, info] }
    end

    # Quits while the worker thread is paused at `stage` (after the job's
    # own code ran), then lets it go on.
    def quit_while_paused
      thread = Thread.new { dispatcher.run }
      Timeout.timeout(5) { paused.pop }
      dispatcher.quit
      sleep 0.1 # The interrupt is raised into the paused thread meanwhile.
      yield if block_given?
      Timeout.timeout(10) { thread.join }
    end

    def pause_in(klass, method)
      p = paused
      allow_any_instance_of(klass).to receive(method).and_wrap_original do |m, *args, &block|
        p << true
        sleep 0.3
        m.call(*args, &block)
      end
    end

    it 'does not release (to run again) a job interrupted while it is being finished' do
      job = Delayed::Job.enqueue(SimpleJob.new)
      pause_in(Delayed::Backend::Test::Job, :destroy)
      quit_while_paused
      expect(SimpleJob.runs).to eq 1
      expect(Delayed::Job.all).not_to include(job)
      expect(log.map(&:last).grep(/interrupted by shutdown/)).to be_empty
      expect(reported).to be_empty
    end

    it 'does not release a job interrupted while it is being rescheduled after failing' do
      job = Delayed::Job.enqueue(ErrorJob.new)
      pause_in(Delayed::Backend::Test::Job, :save!)
      quit_while_paused
      job.reload
      expect(job.attempts).to eq 1
      expect(job.last_error).to match(/did not work/)
      expect(job.locked_by).to be_nil
      expect(log.map(&:last).grep(/interrupted by shutdown/)).to be_empty
    end

    it 'lets :perform callbacks after the job run uninterrupted' do
      dispatcher # Worker.new resets the lifecycle.
      after_perform = []
      p = paused
      Delayed::Worker.lifecycle.after(:perform) do |_worker, job|
        p << true
        sleep 0.3
        after_perform << job.id
      end
      job = Delayed::Job.enqueue(SimpleJob.new)
      quit_while_paused
      expect(after_perform).to eq [job.id]
      expect(Delayed::Job.all).not_to include(job)
    end

    it 'lets perform subscribers run uninterrupted' do
      seen = []
      p = paused
      subscription = ActiveSupport::Notifications.subscribe('perform.delayed_job') do |*args|
        p << true
        sleep 0.3
        seen << args.last[:success]
      end
      job = Delayed::Job.enqueue(SimpleJob.new)
      quit_while_paused
      expect(seen).to eq [true]
      expect(Delayed::Job.all).not_to include(job)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it 'still interrupts the job itself' do
      job, = enqueue(GateJob.new(:a))
      thread = Thread.new { dispatcher.run }
      Timeout.timeout(5) { GateJob.started.pop }
      dispatcher.quit
      Timeout.timeout(10) { thread.join }
      expect(GateJob.interrupted).to eq [:a]
      expect(job.reload.locked_by).to be_nil
      expect(job.attempts).to eq 0
    end

    it 'still times jobs out' do
      job = Delayed::Job.enqueue(LongRunningJob.new)
      allow_any_instance_of(LongRunningJob).to receive(:max_run_time).and_return(1)
      worker = Delayed::Worker.new
      allow(worker).to receive(:say)
      expect(worker.work_off(1)).to eq [0, 1]
      expect(job.reload.last_error).to match(/execution expired/)
    end
  end

  describe '#quit' do
    it 'interrupts running jobs at once, even without a shutdown timeout' do
      jobs = enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      took = elapsed do
        dispatcher.quit
        Timeout.timeout(5) { thread.join }
      end

      expect(took).to be < 0.25
      expect(dispatcher).to be_quit
      expect(dispatcher).to be_stop
      expect(GateJob.interrupted).to eq [:a]
      expect(jobs.first.locked_by).to be_nil
      expect(jobs.first.attempts).to eq 0
      expect(log.map(&:last)).to include('Quitting: interrupting 1 running job(s)')
    end

    it 'takes effect while waiting for jobs after a stop' do
      enqueue(GateJob.new(:a))
      thread = run_until_started(1)
      dispatcher.stop
      sleep 0.3
      expect(thread).to be_alive
      took = elapsed do
        dispatcher.quit
        Timeout.timeout(5) { thread.join }
      end
      expect(took).to be < 0.25
      expect(GateJob.interrupted).to eq [:a]
    end
  end

  describe 'signal traps' do
    let(:traps) { {} }

    before do
      allow(dispatcher).to receive(:trap) { |signal, &block| traps[signal] = block }
      dispatcher.send(:trap_signals)
    end

    it 'stops on TERM and INT' do
      traps['TERM'].call
      expect(dispatcher).to be_stop
      expect(dispatcher).not_to be_quit
    end

    it 'quits on QUIT' do
      skip 'no SIGQUIT on this platform' unless Signal.list.key?('QUIT')
      traps['QUIT'].call
      expect(dispatcher).to be_quit
    end

    context 'with raise_signal_exceptions' do
      before { Delayed::Worker.raise_signal_exceptions = true }
      after { Delayed::Worker.raise_signal_exceptions = false }

      it 'raises only for the first signal, so a repeated signal cannot interrupt the shutdown' do
        expect { traps['TERM'].call }.to raise_error(SignalException)
        expect { traps['TERM'].call }.not_to raise_error
        expect { traps['INT'].call }.not_to raise_error
      end
    end
  end

  describe 'Worker#initialize' do
    it 'sets the shutdown timeout' do
      Delayed::Worker.new(:shutdown_timeout => 12.5)
      expect(Delayed::Worker.shutdown_timeout).to eq 12.5
    end

    it 'defaults to nil' do
      expect(Delayed::Worker.shutdown_timeout).to be_nil
    end
  end
end

describe Delayed::Launcher::Forking, 'stopping worker processes' do
  subject(:launcher) { described_class.new(options) }
  let(:options) { {:processes => 2} }
  let(:traps) { {} }
  let(:logger) { instance_double(Logger, :info => nil, :warn => nil, :error => nil) }

  before do
    allow(launcher).to receive(:logger).and_return(logger)
    allow(Signal).to receive(:trap) { |signal, &block| traps[signal] = block }
    launcher.send(:workers).merge!(11 => ['delayed_job.0', {}], 12 => ['delayed_job.1', {}])
    launcher.send(:trap_signals)
  end

  after { Delayed::Worker.reset }

  %w[TERM INT].each do |signal|
    describe "on SIG#{signal}" do
      it 'stops the run loop and forwards the signal to every worker' do
        expect(Process).to receive(:kill).with(signal, 11)
        expect(Process).to receive(:kill).with(signal, 12)
        expect(launcher).not_to receive(:schedule_kill)
        traps[signal].call
        expect(launcher.instance_variable_get(:@stopped)).to be true
      end

      it 'ignores workers that already exited' do
        allow(Process).to receive(:kill).with(signal, 11).and_raise(Errno::ESRCH)
        expect(Process).to receive(:kill).with(signal, 12)
        expect { traps[signal].call }.not_to raise_error
      end

      context 'with a shutdown timeout' do
        let(:options) { {:processes => 2, :shutdown_timeout => 20} }

        it 'kills workers still running SHUTDOWN_GRACE seconds after it' do
          allow(Process).to receive(:kill)
          expect(launcher).to receive(:schedule_kill).with(20 + described_class::SHUTDOWN_GRACE)
          traps[signal].call
        end
      end

      it 'uses Worker.shutdown_timeout when no option is given' do
        Delayed::Worker.shutdown_timeout = 7
        allow(Process).to receive(:kill)
        expect(launcher).to receive(:schedule_kill).with(7 + described_class::SHUTDOWN_GRACE)
        traps[signal].call
      end
    end
  end

  describe 'on SIGQUIT' do
    before { skip 'no SIGQUIT on this platform' unless Signal.list.key?('QUIT') }

    it 'forwards QUIT to every worker and kills those still running after SHUTDOWN_GRACE seconds' do
      expect(Process).to receive(:kill).with('QUIT', 11)
      expect(Process).to receive(:kill).with('QUIT', 12)
      expect(launcher).to receive(:schedule_kill).with(described_class::SHUTDOWN_GRACE)
      traps['QUIT'].call
      expect(launcher.instance_variable_get(:@stopped)).to be true
    end
  end

  describe '#schedule_kill' do
    it 'kills the workers after the timeout' do
      expect(launcher).to receive(:kill).with(1, 'after 0.05 second timeout')
      launcher.send(:schedule_kill, 0.05).join(2)
    end

    it 'keeps the earliest kill when called again' do
      allow(launcher).to receive(:kill)
      first = launcher.send(:schedule_kill, 0.05)
      expect(launcher.send(:schedule_kill, 30)).to be_nil
      first.join(2)
      expect(launcher).to have_received(:kill).once
    end

    it 'schedules an earlier kill' do
      allow(launcher).to receive(:kill)
      launcher.send(:schedule_kill, 30)
      sooner = launcher.send(:schedule_kill, 0.05)
      expect(sooner).to be_a Thread
      sooner.join(2)
      expect(launcher).to have_received(:kill).with(1, 'after 0.05 second timeout')
    end
  end
end

describe Delayed::Dispatcher, 'shutdown timeout message' do
  it 'formats whole and fractional seconds the same way, whatever their type' do
    dispatcher = described_class.new
    messages = []
    allow(dispatcher).to receive(:say) { |text, *| messages << text }
    thread = Thread.new { sleep }
    [1, 1.0, 2.5].each do |timeout|
      Delayed::Worker.shutdown_timeout = timeout
      stub_const('Delayed::Dispatcher::INTERRUPT_GRACE', 0)
      allow(thread).to receive(:raise)
      dispatcher.send(:interrupt_threads, [thread])
    end
    expect(messages.grep(/Shutdown timeout/)).to eq [
      'Shutdown timeout of 1s exceeded: interrupting 1 running job(s)',
      'Shutdown timeout of 1s exceeded: interrupting 1 running job(s)',
      'Shutdown timeout of 2.5s exceeded: interrupting 1 running job(s)'
    ]
  ensure
    thread.kill
    Delayed::Worker.reset
  end
end

describe 'Signals received while a worker process starts up' do
  describe 'Delayed::Launcher::Forking#capture_signals' do
    subject(:launcher) { Delayed::Launcher::Forking.new(:processes => 2) }

    around do |example|
      previous = %w[TERM INT QUIT].select { |s| Signal.list.key?(s) }.map { |s| [s, Signal.trap(s, 'DEFAULT')] }
      example.run
    ensure
      previous.each { |signal, handler| Signal.trap(signal, handler || 'DEFAULT') }
    end

    it "replaces the parent's traps with ones that only record the signal" do
      parent_trap_ran = false
      Signal.trap('TERM') { parent_trap_ran = true }
      pending = launcher.send(:capture_signals)

      Process.kill('TERM', Process.pid)
      Process.kill('INT', Process.pid)
      Timeout.timeout(2) { sleep 0.01 until pending.size == 2 }

      expect(pending).to eq %w[TERM INT]
      expect(parent_trap_ran).to be false
    end

    it 'records each signal once, though it may arrive twice' do
      pending = launcher.send(:capture_signals)
      Process.kill('TERM', Process.pid)
      Timeout.timeout(2) { sleep 0.01 until pending.any? }
      Process.kill('TERM', Process.pid)
      sleep 0.1
      expect(pending).to eq ['TERM']
    end

    it 'records QUIT' do
      skip 'no SIGQUIT on this platform' unless Signal.list.key?('QUIT')
      pending = launcher.send(:capture_signals)
      Process.kill('QUIT', Process.pid)
      Timeout.timeout(2) { sleep 0.01 until pending.any? }
      expect(pending).to eq ['QUIT']
    end

    it 'is called first in the forked worker, and its signals are passed to the worker' do
      pending = ['TERM']
      allow(launcher).to receive(:fork) { |&block| block.call; 123 }
      expect(launcher).to receive(:capture_signals).ordered.and_return(pending)
      expect(launcher).to receive(:run_worker).with('delayed_job.0', {}, pending).ordered
      expect(launcher.send(:fork_worker, 'delayed_job.0', {})).to eq 123
    end
  end

  describe Delayed::Dispatcher do
    let(:dispatcher) { described_class.new }

    before do
      allow(dispatcher).to receive(:trap_signals)
      allow(dispatcher).to receive(:say)
    end

    it 'stops before running when it received TERM or INT while starting' do
      %w[TERM INT].each do |signal|
        d = described_class.new
        allow(d).to receive(:trap_signals)
        allow(d).to receive(:say)
        expect(Delayed::Job).not_to receive(:reserve_batch)
        Timeout.timeout(5) { d.start([signal]) }
        expect(d).to be_stop
        expect(d).not_to be_quit
        expect(d).to have_received(:say).with("Received SIG#{signal} while starting", 'warn')
      end
    end

    it 'quits when it received QUIT while starting' do
      Timeout.timeout(5) { dispatcher.start(['QUIT']) }
      expect(dispatcher).to be_quit
    end

    it 'does not raise a SignalException for them, even with raise_signal_exceptions' do
      Delayed::Worker.raise_signal_exceptions = true
      expect { Timeout.timeout(5) { dispatcher.start(['TERM']) } }.not_to raise_error
    ensure
      Delayed::Worker.raise_signal_exceptions = false
    end

    it 'installs its traps before handling them, so later signals are not lost' do
      expect(dispatcher).to receive(:trap_signals).ordered
      expect(dispatcher).to receive(:handle_pending_signal).with('TERM').ordered.and_call_original
      expect(dispatcher).to receive(:run).ordered
      dispatcher.start(['TERM'])
    end

    it 'runs normally without pending signals' do
      expect(dispatcher).to receive(:run)
      dispatcher.start
      expect(dispatcher).not_to be_stop
    end
  end

  describe 'Delayed::Launcher::Base#run_worker' do
    it 'passes the pending signals to the dispatcher' do
      launcher = Delayed::Launcher::Forking.new(:processes => 2)
      allow(Dir).to receive(:chdir)
      allow(Delayed::Worker).to receive(:after_fork)
      allow(launcher).to receive(:setup_logger)
      dispatcher = double(:name_prefix= => nil)
      allow(Delayed::Dispatcher).to receive(:new).and_return(dispatcher)
      expect(dispatcher).to receive(:start).with(['TERM'])
      launcher.send(:run_worker, 'delayed_job.0', {}, ['TERM'])
    end
  end
end
