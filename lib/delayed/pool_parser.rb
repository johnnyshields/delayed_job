module Delayed
  class PoolParser
    def add(string)
      string.split('|').each do |segment|
        queues, worker_count, thread_count = segment.split(':')
        queues = ['*', '', nil].include?(queues) ? [] : queues.split(',')
        worker_count = (worker_count || 1).to_i rescue 1
        pool = [queues, worker_count]
        pool << [thread_count.to_i, 1].max unless thread_count.nil? || thread_count.empty?
        pools << pool
      end
      self
    end

    def pools
      @pools ||= []
    end
  end
end
