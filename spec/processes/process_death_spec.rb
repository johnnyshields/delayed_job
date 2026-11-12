require 'helper'
require_relative 'helpers'

# Runs a real forking launcher whose worker processes die mid-job, and checks
# that their jobs are recovered right away instead of staying locked until
# max_run_time.
describe 'A worker process dying while running jobs', :processes do
  include ProcessHelpers

  let(:worker_settings) { {:sleep_delay => 0.1, :max_run_time => 3600} }

  # A worker process killed with SIGKILL makes the launcher shut down all
  # workers (see Forking#run_loop); a crash with a failure status gets the
  # worker replaced. Either way, the dead worker's job is recovered at once.
  context 'when it is SIGKILLed' do
    it 'recovers its job as a failed attempt instead of leaving it locked' do
      job = enqueue_process_job(ProcessJobs::KillJob.new('killed', 'KILL'))
      status, output = run_launcher(:processes => 2, :worker => worker_settings)

      expect(status).to be_success
      expect(output).to match(/Recovered 1 job\(s\) left locked by worker delayed_job\.\d \(pid \d+\)/)
      job = reload_job(job)
      expect(job.locked_by).to be_nil
      expect(job.locked_at).to be_nil
      expect(job.attempts).to eq 1
      expect(job.last_error).to match(/\AWorker process delayed_job\.\d \(pid \d+\) was killed by signal 9/)
      expect(job.run_at).to be > job.created_at
    end
  end

  context 'when it exits with a failure status' do
    it 'recovers its job and replaces the worker' do
      job = enqueue_process_job(ProcessJobs::ExitJob.new('exit', 3))
      pid, reader = spawn_launcher(:processes => 1, :pools => [[[], 1]], :worker => worker_settings)
      wait_for { reload_job(job).attempts == 1 }
      sleep 1 # let the replacement worker start
      Process.kill('TERM', -pid) # the process group, as a terminal or init system does
      status, output = wait_for_launcher(pid, reader)

      expect(status).to be_success
      expect(output).to match(/Worker delayed_job\.0 exited - pid \d+ exit 3/)
      expect(output).to match(/Recovered 1 job\(s\) left locked by worker delayed_job\.0 \(pid \d+\)/)
      expect(output).to match(/Worker delayed_job\.1 started - pid \d+/)
      job = reload_job(job)
      expect(job.attempts).to eq 1
      expect(job.last_error).to match(/\AWorker process delayed_job\.0 \(pid \d+\) exited with status 3/)
      expect(job.locked_by).to be_nil
      expect(job.run_at).to be > job.created_at
    end

    it 'fails the job permanently once it has used all its attempts' do
      job = enqueue_process_job(ProcessJobs::ExitJob.new('exit', 3), :attempts => 1)
      pid, reader = spawn_launcher(:processes => 1, :pools => [[[], 1]],
                                   :worker => worker_settings.merge(:max_attempts => 2, :destroy_failed_jobs => false))
      wait_for { reload_job(job).failed_at }
      Process.kill('TERM', -pid) # the process group, as a terminal or init system does
      _status, output = wait_for_launcher(pid, reader)

      expect(output).to include 'Recovered 1 job(s)'
      job = reload_job(job)
      expect(job.attempts).to eq 2
      expect(job.failed_at).not_to be_nil
      expect(job.locked_by).to be_nil
    end
  end

  context 'with several threads per worker process' do
    it 'recovers the jobs of every thread of the dead worker' do
      jobs = Array.new(3) { |i| enqueue_process_job(ProcessJobs::SleepJob.new("slow#{i}", 30)) }
      pid, reader = spawn_launcher(:processes => 1, :pools => [[[], 1]], :threads => 4, :worker => worker_settings)
      wait_for { ProcessHelpers::Job.where.not(:locked_by => nil).count == 3 }
      child = ProcessHelpers::Job.where.not(:locked_by => nil).first.locked_by[/pid:(\d+)/, 1].to_i
      Process.kill('KILL', child)
      status, output = wait_for_launcher(pid, reader)

      expect(status).to be_success
      expect(output).to include 'Recovered 3 job(s) left locked by worker delayed_job.0'
      jobs = jobs.map { |j| reload_job(j) }
      expect(jobs.map(&:locked_by)).to eq [nil, nil, nil]
      expect(jobs.map(&:attempts)).to eq [1, 1, 1]
      expect(jobs.map(&:last_error)).to all(start_with('Worker process delayed_job.0'))
    end
  end

  it 'leaves the jobs of the other, healthy worker processes alone' do
    slow = enqueue_process_job(ProcessJobs::SleepJob.new('survivor', 1), :queue => 'slow')
    pid, reader = spawn_launcher(:pools => [[['slow'], 1], [['kill'], 1]], :worker => worker_settings)
    wait_for { reload_job(slow).locked_by }
    healthy = reload_job(slow).locked_by
    victim = enqueue_process_job(ProcessJobs::KillJob.new('victim', 'KILL'), :queue => 'kill')
    status, output = wait_for_launcher(pid, reader)

    expect(status).to be_success
    expect(output).to match(/Recovered 1 job\(s\) left locked by worker delayed_job\.1/)
    # The healthy worker was shut down gracefully and finished its job.
    expect(ProcessHelpers::Run.where(:key => 'survivor').count).to eq 1
    expect(reload_job(slow)).to be_nil
    victim = reload_job(victim)
    expect(victim.attempts).to eq 1
    expect(victim.last_error).to start_with 'Worker process delayed_job.1'
    expect(healthy).to start_with 'delayed_job.0'
  end
end
