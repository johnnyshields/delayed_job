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

# Enqueues the next link of a chain of `length` jobs, then finishes after a
# short (random) time; records each link it runs.
class ChainJob
  cattr_accessor :runs, :mutex, :fixed_sleep
  self.mutex = Mutex.new
  self.runs = []

  attr_accessor :chain, :link, :length, :max_sleep

  def initialize(chain, link, length, max_sleep = 0.01)
    self.chain = chain
    self.link = link
    self.length = length
    self.max_sleep = max_sleep
  end

  def perform
    Delayed::Job.enqueue(ChainJob.new(chain, link + 1, length, max_sleep)) if link + 1 < length
    sleep(fixed_sleep || (rand * max_sleep))
    self.class.mutex.synchronize { self.class.runs << [chain, link] }
  end
end

# Runs for `seconds`, then records that it completed.
class FuzzJob
  cattr_accessor :completed, :mutex
  self.mutex = Mutex.new
  self.completed = Hash.new(0)

  attr_accessor :key, :seconds

  def initialize(key, seconds)
    self.key = key
    self.seconds = seconds
  end

  def perform
    sleep seconds
    self.class.mutex.synchronize { self.class.completed[key] += 1 }
  end
end

# Blocks until released, so a dispatcher can be stopped while it runs.
class BlockingJob
  cattr_accessor :started, :release

  def self.reset
    self.started = Queue.new
    self.release = false
  end
  reset

  def perform
    self.class.started << true
    sleep 0.01 until self.class.release
  end
end

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
        sleep 0.01 until self.class.release
        break
      rescue Exception # rubocop:disable Lint/RescueException
        next
      end
    else
      begin
        sleep 0.01 until self.class.release
      rescue StandardError
        raise 'a StandardError rescue must not catch the interrupt'
      rescue Exception # rubocop:disable Lint/RescueException
        self.class.interrupted << key
        raise
      end
    end
    self.class.finished << key
  end
end

# Runs for 0.2s, recording whether it finished or was interrupted.
class NapJob
  cattr_accessor :outcomes
  self.outcomes = Queue.new

  def perform
    sleep 0.2
    self.class.outcomes << :finished
  rescue Exception # rubocop:disable Lint/RescueException
    self.class.outcomes << :interrupted
    raise
  end
end

# Ignores its timeout (as a job blocked in native code would) and runs
# for `seconds`.
class StuckJob
  attr_accessor :seconds, :limit

  def initialize(seconds, limit)
    self.seconds = seconds
    self.limit = limit
  end

  def max_run_time
    limit
  end

  def perform
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    begin
      sleep 0.01 while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    rescue Exception # rubocop:disable Lint/RescueException
      retry
    end
  end
end
