require 'helper'

describe 'Recovering the jobs of a dead worker process' do
  let(:killed) { double('Process::Status', :signaled? => true, :termsig => 9, :success? => false) }
  let(:crashed) { double('Process::Status', :signaled? => false, :termsig => nil, :exitstatus => 3, :success? => false) }

  before { Delayed::Job.delete_all }

  describe Delayed::ProcessExitError do
    it 'describes a worker killed by a signal' do
      error = described_class.new('delayed_job.1', 123, killed)
      expect(error.message).to eq 'Child process delayed_job.1 (pid 123) was killed by signal 9'
      expect([error.worker_name, error.pid, error.status]).to eq ['delayed_job.1', 123, killed]
    end

    it 'describes a worker that exited with a failure status' do
      error = described_class.new('delayed_job.0', 456, crashed)
      expect(error.message).to eq 'Child process delayed_job.0 (pid 456) exited with status 3'
    end

    it 'has an empty backtrace, so it can be recorded as a job error' do
      expect(described_class.new('w', 1, killed).backtrace).to eq []
    end
  end

  describe 'worker names' do
    it 'builds the default name for any pid' do
      expect(Delayed::Worker.default_name('dj.0 ', 42)).to match(/\Adj\.0 host:.+ pid:42\z/)
      expect(Delayed::Worker.default_name).to end_with "pid:#{Process.pid}"
    end

    it 'builds a lock name with an optional thread index' do
      expect(Delayed::Worker.lock_name('dj.0 ', 42)).to end_with 'pid:42'
      expect(Delayed::Worker.lock_name('dj.0 ', 42, 3)).to end_with 'pid:42 thread:3'
    end

    it 'matches the names workers lock jobs under' do
      dispatcher = Delayed::Dispatcher.new(:threads => 3)
      dispatcher.name_prefix = 'dj.0 '
      expect(Delayed::Worker.lock_names('dj.0 ', Process.pid, 3)).to eq dispatcher.workers.map(&:name)

      single = Delayed::Dispatcher.new
      single.name_prefix = 'dj.0 '
      expect(Delayed::Worker.lock_names('dj.0 ', Process.pid, 1)).to eq single.workers.map(&:name)
    end
  end

  describe 'Delayed::Worker.recover_jobs_of' do
    let(:error) { Delayed::ProcessExitError.new('dj.1', 77, killed) }
    let(:now) { Delayed::Job.db_time_now }

    def locked_job(locked_by, attrs = {})
      Delayed::Job.create!({:payload_object => SimpleJob.new, :locked_by => locked_by, :locked_at => now}.merge(attrs))
    end

    it 'counts the jobs of the dead workers as failed attempts and reschedules them' do
      job = locked_job('dj.1 pid:77 thread:0')
      expect(Delayed::Worker.recover_jobs_of(['dj.1 pid:77 thread:0'], error)).to eq 1

      expect(job.attempts).to eq 1
      expect(job.locked_by).to be_nil
      expect(job.locked_at).to be_nil
      expect(job.run_at).to be > now
      expect(job.last_error).to start_with 'Child process dj.1 (pid 77) was killed by signal 9'
      expect(job.failed_at).to be_nil
      expect(Delayed::Job.all).to include(job)
    end

    it 'recovers the jobs of every given worker' do
      jobs = Array.new(3) { |i| locked_job("dj.1 pid:77 thread:#{i}") }
      expect(Delayed::Worker.recover_jobs_of(jobs.map(&:locked_by), error)).to eq 3
      expect(jobs.map(&:attempts)).to eq [1, 1, 1]
      expect(jobs.map(&:locked_by)).to eq [nil, nil, nil]
    end

    it "leaves other workers' jobs alone" do
      other = locked_job('dj.2 pid:88')
      unlocked = Delayed::Job.create!(:payload_object => SimpleJob.new)
      Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], error)

      expect([other.attempts, other.locked_by]).to eq [0, 'dj.2 pid:88']
      expect(unlocked.attempts).to eq 0
    end

    context 'when the job has used its last attempt' do
      it 'fails it permanently, deleting it by default' do
        job = locked_job('dj.1 pid:77', :attempts => Delayed::Worker.max_attempts - 1)
        Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], error)
        expect(Delayed::Job.all).not_to include(job)
      end

      it 'keeps it as failed when failed jobs are kept' do
        Delayed::Worker.destroy_failed_jobs = false
        job = locked_job('dj.1 pid:77', :attempts => Delayed::Worker.max_attempts - 1)
        Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], error)
        expect(job.failed_at).not_to be_nil
        expect(job.last_error).to include 'was killed by signal 9'
        expect(job.locked_by).to be_nil
      ensure
        Delayed::Worker.destroy_failed_jobs = true
      end
    end

    it 'runs the :error callbacks with a worker named after the dead worker' do
      job = locked_job('dj.1 pid:77')
      seen = []
      Delayed::Worker.lifecycle.before(:error) { |worker, failed_job| seen << [worker.name, failed_job.id] }
      Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], error)
      expect(seen).to eq [['dj.1 pid:77', job.id]]
    ensure
      Delayed::Worker.setup_lifecycle
    end

    it 'runs the job error hook, like a failed run' do
      payload = ErrorJob.new
      allow(payload).to receive(:error)
      job = locked_job('dj.1 pid:77', :payload_object => payload)
      allow(job).to receive(:payload_object).and_return(payload)
      allow(Delayed::Job).to receive(:locked_jobs).and_return([job])
      Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], error)
      expect(job.attempts).to eq 1
    end

    context 'when the backend cannot list locked jobs' do
      before { allow(Delayed::Job).to receive(:locked_jobs).and_return(nil) }

      it 'only clears the locks' do
        job = locked_job('dj.1 pid:77')
        expect(Delayed::Worker.recover_jobs_of(['dj.1 pid:77'], error)).to eq 0
        expect([job.locked_by, job.attempts]).to eq [nil, 0]
      end
    end
  end

  describe Delayed::Launcher::Forking do
    subject(:launcher) { described_class.new(:processes => 2, :threads => 2) }
    let(:logger) { instance_double(Logger, :info => nil, :warn => nil, :error => nil) }

    before do
      allow(launcher).to receive(:logger).and_return(logger)
      allow(Delayed::Worker.backend).to receive(:before_fork)
    end

    describe '#recover_jobs_of_worker' do
      let(:options) { {:threads => 2} }

      it 'recovers the jobs of every thread of a worker that died' do
        names = Delayed::Worker.lock_names('delayed_job.1 ', 99, 2)
        expect(Delayed::Worker).to receive(:recover_jobs_of) do |lock_names, error|
          expect(lock_names).to eq names
          expect(error).to be_a Delayed::ProcessExitError
          expect(error.message).to eq 'Child process delayed_job.1 (pid 99) was killed by signal 9'
          2
        end
        expect(logger).to receive(:warn).with('Recovered 2 job(s) left locked by child process delayed_job.1 (pid 99)')
        launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, options, killed)
      end

      it 'uses the single-thread name for single-threaded workers' do
        expect(Delayed::Worker).to receive(:recover_jobs_of).with([Delayed::Worker.lock_name('delayed_job.1 ', 99)], anything).and_return(0)
        expect(logger).not_to receive(:warn)
        launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, {}, crashed)
      end

      it 'does nothing for a worker that exited cleanly' do
        expect(Delayed::Worker).not_to receive(:recover_jobs_of)
        launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, options, double(:success? => true))
      end

      it 'logs and carries on when the database cannot be reached' do
        allow(Delayed::Worker).to receive(:recover_jobs_of).and_raise(IOError, 'connection refused')
        expect(logger).to receive(:error).with(/Could not recover the jobs of child process delayed_job.1 \(pid 99\): IOError: connection refused/)
        expect { launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, options, killed) }.not_to raise_error
      end

      it 'disconnects from the database afterwards, so the next fork does not inherit the connection' do
        allow(Delayed::Worker).to receive(:recover_jobs_of).and_return(0)
        expect(Delayed::Worker.backend).to receive(:before_fork)
        launcher.send(:recover_jobs_of_worker, 'delayed_job.1', 99, options, killed)
      end
    end

    describe '#run_loop' do
      let(:options) { {:threads => 2, :queues => ['mail']} }

      before do
        launcher.send(:workers)[99] = ['delayed_job.1', options]
        launcher.instance_variable_set(:@stopped, false)
      end

      # Process.wait2 reaps worker 99 with the given status, then finds no
      # more children.
      def reap(status)
        calls = 0
        allow(Process).to receive(:wait2) do
          raise Errno::ECHILD unless (calls += 1) == 1
          [99, status]
        end
      end

      it 'recovers the jobs of a crashed worker, then replaces it' do
        reap(crashed)
        expect(launcher).to receive(:recover_jobs_of_worker).with('delayed_job.1', 99, options, crashed).ordered
        expect(launcher).to receive(:add_worker).with(options).ordered
        launcher.send(:run_loop)
      end

      it 'recovers the jobs of a SIGKILLed worker, then replaces it' do
        reap(killed)
        expect(launcher).to receive(:recover_jobs_of_worker).with('delayed_job.1', 99, options, killed).ordered
        expect(launcher).to receive(:add_worker).with(options).ordered
        expect(launcher).not_to receive(:shutdown)
        launcher.send(:run_loop)
        expect(launcher.instance_variable_get(:@killed)).to be_falsey
      end

      it 'says that a SIGKILLed worker is replaced' do
        reap(killed)
        logger = instance_double(Logger, :info => nil, :warn => nil, :error => nil)
        allow(launcher).to receive(:logger).and_return(logger)
        allow(launcher).to receive(:recover_jobs_of_worker)
        allow(launcher).to receive(:add_worker)
        launcher.send(:run_loop)
        expect(logger).to have_received(:warn).with('Child process delayed_job.1 (pid 99) was SIGKILLed (e.g. by the OOM killer); replacing it')
      end

      it 'never shuts down the other worker processes, however often one is SIGKILLed' do
        calls = 0
        allow(Process).to receive(:wait2) do
          raise Errno::ECHILD if (calls += 1) > 3
          launcher.send(:workers)[99] = ['delayed_job.1', options]
          [99, killed]
        end
        allow(launcher).to receive(:recover_jobs_of_worker)
        expect(launcher).to receive(:add_worker).with(options).exactly(3).times
        expect(launcher).not_to receive(:shutdown)
        expect(launcher).not_to receive(:schedule_kill)
        launcher.send(:run_loop)
        expect(launcher.instance_variable_get(:@stopped)).to be false
      end

      it 'does not say a worker process it killed itself was SIGKILLed by someone else' do
        reap(killed)
        launcher.instance_variable_set(:@stopped, true)
        launcher.instance_variable_set(:@killed, true)
        logger = instance_double(Logger, :info => nil, :warn => nil, :error => nil)
        allow(launcher).to receive(:logger).and_return(logger)
        allow(launcher).to receive(:recover_jobs_of_worker)
        launcher.send(:run_loop)
        expect(logger).not_to have_received(:warn).with(/was SIGKILLed/)
      end

      it 'does not replace a SIGKILLed worker while stopping' do
        reap(killed)
        launcher.instance_variable_set(:@stopped, true)
        allow(launcher).to receive(:recover_jobs_of_worker)
        expect(launcher).not_to receive(:add_worker)
        expect(launcher).not_to receive(:shutdown)
        launcher.send(:run_loop)
      end
    end

    describe '#kill' do
      it 'recovers the jobs of the workers it kills' do
        launcher.send(:workers)[99] = ['delayed_job.1', {:threads => 2}]
        allow(Process).to receive(:kill)
        allow(Process).to receive(:waitpid2).with(99).and_return([99, killed])
        expect(launcher).to receive(:recover_jobs_of_worker).with('delayed_job.1', 99, {:threads => 2}, killed)
        expect { launcher.kill(1, 'test') }.to raise_error(SystemExit)
      end

      it 'skips workers already reaped by the main thread' do
        launcher.send(:workers)[99] = ['delayed_job.1', {}]
        allow(Process).to receive(:kill)
        allow(Process).to receive(:waitpid2).with(99).and_raise(Errno::ECHILD)
        expect(launcher).not_to receive(:recover_jobs_of_worker)
        expect { launcher.kill(1) }.to raise_error(SystemExit)
      end
    end
  end
end
