module Delayed
  module Launcher
    class Base
      attr_accessor :worker_count,
                    :pools,
                    :process_prefix,
                    :process_identifier

      def initialize(options)
        @worker_index = 0
        @worker_count = options.delete(:worker_count) || 1
        @pools = options.delete(:pools)
        @pools = nil if @pools == []
        @monitor = options.delete(:monitor)
        @process_prefix = options.delete(:prefix)
        @process_identifier = options.delete(:identifier)
        @args = options.delete(:args)

        @options = options
        @options[:pid_dir] ||= "#{Delayed.root}/tmp/pids"
        @options[:log_dir] ||= "#{Delayed.root}/log"
      end

      def launch
        raise NotImplementedError, '#launch must be implemented in subclass'
      end

    protected

      def setup_logger
        Delayed::Worker.logger ||= Logger.new(File.join(@options[:log_dir], 'delayed_job.log'))
      end

      # Readies the booted parent process to be forked, so that as much memory
      # as possible is shared copy-on-write with the worker processes: loads
      # all application code up front, then runs a full GC and compacts the
      # heap so long-lived objects sit on pages the children won't write to.
      def prepare_for_fork
        eager_load_application
        warmup_heap
      end

      # Rails does not eager load in rake tasks (config.rake_eager_load is
      # false by default), so without this each worker would autoload, and
      # hold a private copy of, the application code. Skipped when code
      # reloading is enabled, since reloaded code is not shared anyway.
      def eager_load_application
        return unless defined?(::Rails.application) && ::Rails.application
        return unless ::Rails.application.config.cache_classes
        ::Rails.application.eager_load!
      end

      def warmup_heap
        if Process.respond_to?(:warmup)
          Process.warmup
        else
          GC.start
          GC.compact if GC.respond_to?(:compact)
        end
      rescue NotImplementedError
        nil # GC.compact is unsupported on this platform
      end

      def setup_workers
        if pools
          setup_pooled_workers
        elsif process_identifier
          setup_identified_worker
        elsif worker_count > 1
          setup_multiple_workers
        else
          setup_single_worker
        end
      end

      def setup_pooled_workers
        pools.each do |queues, pool_worker_count, pool_thread_count|
          options = @options.merge(:queues => queues)
          options[:thread_count] = pool_thread_count if pool_thread_count
          pool_worker_count.times { add_worker(options) }
        end
      end

      def setup_multiple_workers
        worker_count.times { add_worker(@options) }
      end

      def setup_single_worker
        raise NotImplementedError, '#setup_single_worker must be implemented in subclass'
      end

      def setup_identified_worker
        setup_single_worker
      end

      def add_worker(_options)
        raise NotImplementedError, '#add_worker must be implemented in subclass'
      end

      def run_worker(worker_name, options)
        Dir.chdir(Delayed.root)
        set_process_name(worker_name)
        Delayed::Worker.after_fork
        setup_logger
        poller = Delayed::Poller.new(options)
        poller.name_prefix = "#{worker_name} "
        poller.start
      rescue => e
        STDERR.puts e.message
        STDERR.puts e.backtrace
        logger.fatal(e)
        exit_with_error_status
      end

      def thread_count(options)
        (options[:thread_count] || 1).to_i
      end

      def set_process_name(name) # rubocop:disable AccessorMethodName
        $0 = process_prefix ? File.join(process_prefix, name) : name
      end

      def get_name(label)
        "delayed_job#{".#{label}" if label}"
      end

      def exit_with_error_status
        exit(1)
      end

      def logger
        @logger ||= Delayed::Worker.logger || (::Rails.logger if defined?(::Rails.logger)) || Logger.new(STDOUT)
      end
    end
  end
end
