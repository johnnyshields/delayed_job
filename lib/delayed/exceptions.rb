require 'timeout'

module Delayed
  class WorkerTimeout < Timeout::Error
    def message
      seconds = Delayed::Worker.max_run_time.to_i
      "#{super} (Delayed::Worker.max_run_time is only #{seconds} second#{seconds == 1 ? '' : 's'})"
    end
  end

  class FatalBackendError < RuntimeError; end

  # Recorded as the error of jobs that were running in a worker process when
  # it died (killed by a signal, or exited with a failure status).
  class ProcessExitError < StandardError
    attr_reader :worker_name, :pid, :status

    def initialize(worker_name, pid, status)
      @worker_name = worker_name
      @pid = pid
      @status = status
      reason = status.signaled? ? "was killed by signal #{status.termsig}" : "exited with status #{status.exitstatus}"
      super("Worker process #{worker_name} (pid #{pid}) #{reason}")
      set_backtrace([])
    end
  end
end
