module Delayed
  module Launcher
    class Forking < Base
      def launch
        @stop = !!@options[:exit_on_complete]
        setup_logger
        setup_signals
        Delayed::Worker.before_fork if worker_count > 1
        setup_workers
        run_loop if worker_count > 1
        on_exit
      end

    private

      def setup_signals
        Signal.trap('INT') do
          Thread.new { logger.info('Received SIGINT. Waiting for workers to finish current job...') }
          @stop = true
        end

        Signal.trap('TERM') do
          Thread.new { logger.info('Received SIGTERM. Waiting for workers to finish current job...') }
          @stop = true
        end
      end

      def workers
        @workers ||= {}
      end

      def setup_single_worker
        set_process_name(get_name(process_identifier))
        Delayed::Worker.new(@options).start
      end

      def add_worker(options)
        worker_name = get_name(@worker_index)
        worker_pid = fork_worker(worker_name, options)

        queues = options[:queues]
        queue_msg = " queues=#{queues.empty? ? '*' : queues.join(',')}" if queues
        logger.info "Worker #{worker_name} started - pid #{worker_pid}#{queue_msg}"

        workers[worker_pid] = [worker_name, queues]
        @worker_index += 1
      end

      def fork_worker(worker_name, options)
        fork { run_worker(worker_name, options) }
      end

      def run_loop # rubocop:disable CyclomaticComplexity
        loop do
          worker_pid = Process.wait
          next unless workers.key?(worker_pid)
          worker_name, queues = workers.delete(worker_pid)
          logger.info "Worker #{worker_name} exited - #{$?}"
          break if @stop && workers.empty?
          next if @stop
          options = @options
          options = options.merge(:queues => queues) if queues
          add_worker(options)
        end
      rescue Errno::ECHILD
        logger.warn 'No worker processes found'
      end

      def on_exit
        logger.info "#{get_name(process_identifier)}#{' (parent)' if worker_count > 1} exited gracefully - pid #{$$}"
      end
    end
  end
end
