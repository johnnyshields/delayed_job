module Delayed
  class PoolParser
    # Adds pools given as "queue1,queue2:processes", several separated by
    # "|"; "*" or a blank list of queues is any queue, and the process count
    # defaults to 1. Raises ArgumentError for a count that isn't a whole
    # number of 1 or more (e.g. "mailers:0" or "*:abc").
    def add(string)
      string.split('|').each do |segment|
        queues, process_count = segment.split(':', 2)
        queues = ['*', '', nil].include?(queues) ? [] : queues.split(',')
        pools << [queues, process_count(process_count, segment)]
      end
      self
    end

    def pools
      @pools ||= []
    end

  private

    def process_count(text, segment)
      return 1 if text.nil? || text.strip.empty?
      count = Integer(text.strip, 10)
      return count if count >= 1
      raise ArgumentError
    rescue ArgumentError
      raise ArgumentError, "a pool's process count must be a whole number, 1 or greater (got #{segment.inspect})"
    end
  end
end
