require 'delayed/launcher/runner'

module Delayed
  module Launcher
    # Some code in this class is lovingly borrowed from Puma (puma.io)
    class Single < Runner

      def run
        set_process_name(get_name(process_identifier))
        worker = start_worker
        events.fire(:on_booted)
        worker
      end

      def stop(timeout = nil)
        schedule_halt(timeout)
        stop_worker
        logger.info "#{process_name} exited gracefully - pid #{$$}"
        exit(0)
      end

      # def restart
      #   logger.info "#{process_name} restarting... - pid #{$$}"
      #   stop_worker
      #   start_worker
      #   logger.info "#{process_name} restarted - pid #{$$}"
      # end

      def halt(exit_status = 0, message = nil)
        logger.warn "#{process_name} exited forcefully #{message} - pid #{$$}"
        exit(exit_status)
      end

    private

      def start_worker
        @worker = Delayed::Worker.new(@options).start
      end

      def stop_worker
        @worker.stop
      end

      def schedule_halt(timeout)
        return unless timeout
        Thread.new do
          sleep(timeout)
          halt(1, "after #{timeout} second timeout")
        end
      end

      def process_name
        get_name(process_identifier)
      end
    end
  end
end
