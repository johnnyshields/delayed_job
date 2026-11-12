NamedJob = Struct.new(:perform)
class NamedJob
  def display_name
    'named_job'
  end
end

class SimpleJob
  cattr_accessor :runs
  @runs = 0
  def perform
    self.class.runs += 1
  end
end

class NamedQueueJob < SimpleJob
  def queue_name
    'job_tracking'
  end
end

class ErrorJob
  cattr_accessor :runs
  @runs = 0
  def perform
    raise Exception, 'did not work'
  end
end

CustomRescheduleJob = Struct.new(:offset)
class CustomRescheduleJob
  cattr_accessor :runs
  @runs = 0
  def perform
    raise 'did not work'
  end

  def reschedule_at(time, _attempts)
    time + offset
  end
end

class LongRunningJob
  def perform
    sleep 250
  end
end

class OnPermanentFailureJob < SimpleJob
  attr_writer :raise_error

  def initialize
    @raise_error = false
  end

  def failure
    raise 'did not work' if @raise_error
  end

  def max_attempts
    1
  end
end

module M
  class ModuleJob
    cattr_accessor :runs
    @runs = 0
    def perform
      self.class.runs += 1
    end
  end
end

class CallbackJob
  cattr_accessor :messages

  def enqueue(_job)
    self.class.messages << 'enqueue'
  end

  def before(_job)
    self.class.messages << 'before'
  end

  def perform
    self.class.messages << 'perform'
  end

  def after(_job)
    self.class.messages << 'after'
  end

  def success(_job)
    self.class.messages << 'success'
  end

  def error(_job, error)
    self.class.messages << "error: #{error.class}"
  end

  def failure(_job)
    self.class.messages << 'failure'
  end
end

class EnqueueJobMod < SimpleJob
  def enqueue(job)
    job.run_at = 20.minutes.from_now
  end
end

# Records which thread/worker ran it and how many jobs ran at once.
class ConcurrencyJob
  cattr_accessor :mutex, :running, :max_running, :runs, :delay
  self.mutex = Mutex.new

  def self.reset(delay = 0.05)
    self.running = 0
    self.max_running = 0
    self.runs = Hash.new(0)
    self.delay = delay
  end
  reset

  attr_accessor :key

  def initialize(key)
    self.key = key
  end

  def perform
    self.class.mutex.synchronize do
      self.class.running += 1
      self.class.max_running = [self.class.max_running, self.class.running].max
      self.class.runs[key] += 1
    end
    sleep self.class.delay
  ensure
    self.class.mutex.synchronize { self.class.running -= 1 }
  end
end
