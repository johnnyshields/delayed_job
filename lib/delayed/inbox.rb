module Delayed
  # A worker thread's jobs, handed over by its Delayed::Dispatcher: the job
  # it is about to run and, with prefetch, those queued behind it. #pop
  # takes the most urgent job (lowest priority, then earliest run_at, then
  # first handed over), so a job reserved after the queue filled up doesn't
  # wait behind less urgent ones. Once #close is called, #pop returns EOQ
  # when no job is left.
  class Inbox
    # Returned by #pop once the inbox is closed and empty: end of queue.
    EOQ = Object.new.freeze

    def initialize
      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @items = [] # [key, [slot, job]]
      @sequence = 0
      @closed = false
    end

    # Hands over [slot, job], reserved at `reserved_at` (monotonic seconds).
    def push(slot, job, reserved_at)
      @mutex.synchronize do
        @items << [[job.priority.to_i, run_at_of(job), @sequence += 1], [slot, job, reserved_at]]
        @cond.signal
      end
      self
    end

    # The most urgent [slot, job, reserved_at]; waits for one, or returns
    # EOQ once closed and empty.
    def pop
      @mutex.synchronize do
        loop do
          unless @items.empty?
            best = @items.each_index.min_by { |index| @items[index].first }
            return @items.delete_at(best).last
          end
          return EOQ if @closed
          @cond.wait(@mutex)
        end
      end
    end

    # Takes every job left, without waiting.
    def drain
      @mutex.synchronize do
        items = @items.map(&:last)
        @items.clear
        items
      end
    end

    def close
      @mutex.synchronize do
        @closed = true
        @cond.broadcast
      end
    end

    def size
      @mutex.synchronize { @items.size }
    end

  private

    # run_at as a number (Float seconds), so jobs compare whatever the time
    # class the backend uses; jobs without one come first.
    def run_at_of(job)
      run_at = job.run_at
      run_at ? run_at.to_f : 0.0
    end
  end
end
