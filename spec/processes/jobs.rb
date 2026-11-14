# Jobs used by the process-level specs. Each run is recorded in the runs table.
module ProcessJobs
  def self.record(key, started)
    Delayed::Backend::SqliteFile::Run.create!(
      :key => key, :pid => Process.pid, :worker => Thread.current.name,
      :started => started, :finished => Time.now.to_f
    )
  end

  # Sleeps, then records its run.
  SleepJob = Struct.new(:key, :seconds) do
    def perform
      started = Time.now.to_f
      sleep seconds
      ProcessJobs.record(key, started)
    end
  end

  # Kills the process running it with `signal` on its first attempt;
  # succeeds on later attempts.
  KillJob = Struct.new(:key, :signal) do
    def perform
      Process.kill(signal, Process.pid) if Delayed::Job.find_by(:id => job_id).attempts.zero?
      sleep 1 # let the signal arrive
      ProcessJobs.record(key, Time.now.to_f)
    end

    attr_accessor :job_id

    def before(job)
      self.job_id = job.id
    end
  end

  # Exits the process running it with `status`, skipping at_exit hooks.
  ExitJob = Struct.new(:key, :status) do
    def perform
      exit!(status)
    end
  end
end
