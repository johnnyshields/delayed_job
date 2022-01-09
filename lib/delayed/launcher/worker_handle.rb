module Delayed
  module Launcher

    # This class represents a worker process from the perspective of the
    # DelayedJob parent process. It contains information about the process
    # and its health and it exposes methods to control the process via IPC.
    # It does not include the actual logic executed by the worker process itself.
    # For that see Delayed::Worker.
    #
    # Some code in this class is lovingly borrowed from Puma (puma.io)
    class WorkerHandle

      attr_reader :index,
                  :pid,
                  :name,
                  :queues,
                  # :phase,
                  :signal,
                  :last_checkin,
                  :last_status,
                  :started_at

      attr_writer :pid, :phase

      # def initialize(idx, pid, phase, options)
      def initialize(idx, pid, name, queues)
        @index = idx
        @pid = pid
        @name = name
        @queues = queues
        # @phase = phase
        @stage = :started
        @signal = 'TERM'
        # @options = options
        @first_term_sent = nil
        @started_at = Time.now
        @last_checkin = Time.now
        @last_status = {}
        @term = false
      end

      def booted?
        @stage == :booted
      end

      def uptime
        Time.now - started_at
      end

      def boot!
        @last_checkin = Time.now
        @stage = :booted
      end

      def term?
        @term
      end

      def ping!(status)
        @last_checkin = Time.now
        captures = status.match(/{ "backlog":(?<backlog>\d*), "running":(?<running>\d*), "pool_capacity":(?<pool_capacity>\d*), "max_threads": (?<max_threads>\d*), "jobs_count": (?<jobs_count>\d*) }/)
        @last_status = captures.names.inject({}) do |hash, key|
          hash[key.to_sym] = captures[key].to_i
          hash
        end
      end

      def ping_timeout
        timeout = booted? ? @options[:worker_timeout] : @options[:worker_boot_timeout]
        @last_checkin + timeout
      end

      def term
        if @first_term_sent && (Time.now - @first_term_sent) > @options[:worker_shutdown_timeout]
          @signal = 'KILL'
        else
          @term ||= true
          @first_term_sent ||= Time.now
        end
        Process.kill @signal, @pid if @pid
      rescue Errno::ESRCH
      end

      def kill
        @signal = 'KILL'
        term
      end

      def hup
        Process.kill 'HUP', @pid
      rescue Errno::ESRCH
      end
    end
  end
end
