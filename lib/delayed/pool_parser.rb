module Delayed
  class PoolParser
    def add(string)
      string.split('|').each do |segment|
        queues, process_count = segment.split(':')
        queues = ['*', '', nil].include?(queues) ? [] : queues.split(',')
        process_count = (process_count || 1).to_i rescue 1
        pools << [queues, process_count]
      end
      self
    end

    def pools
      @pools ||= []
    end
  end
end
