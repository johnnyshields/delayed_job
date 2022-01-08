module Delayed
  module Launcher
    # Some code in this class is lovingly borrowed from Puma (puma.io)
    class Runner
      include Loggable

      attr_reader :process_prefix,
                  :process_identifier

      def initialize(launcher, options)
        @launcher = launcher
        @process_prefix = options.delete(:prefix)
        @process_identifier = options.delete(:identifier)
        @options = options
      end

    private

      def check_fork_supported!
        return if Process.respond_to?(:fork)
        raise "Process fork not supported on #{RUBY_ENGINE} on this platform"
      end

      def output_header(mode)
        # min_t = @options[:min_threads]
        # max_t = @options[:max_threads]

        logger.info "Delayed Job starting in #{mode} mode..."
        logger.info "*      Version: #{Delayed::VERSION} (#{ruby_engine})"
        # logger.info "*  Min threads: #{min_t}"
        # logger.info "*  Max threads: #{max_t}"
        logger.info "*  Environment: #{ENV['RAILS_ENV']}"

        if mode == 'single'
          logger.info "*          PID: #{Process.pid}"
        else
          logger.info "*   Parent PID: #{Process.pid}"
        end
      end

      def ruby_engine
        if !defined?(RUBY_ENGINE) || RUBY_ENGINE == 'ruby'
          "ruby #{RUBY_VERSION}-p#{RUBY_PATCHLEVEL}"
        elsif defined?(RUBY_ENGINE_VERSION)
          "#{RUBY_ENGINE} #{RUBY_ENGINE_VERSION} - ruby #{RUBY_VERSION}"
        else
          "#{RUBY_ENGINE} #{RUBY_VERSION}"
        end
      end

      def set_process_name(name) # rubocop:disable AccessorMethodName
        $0 = process_prefix ? File.join(process_prefix, name) : name
      end

      def get_name(label)
        "delayed_job#{".#{label}" if label}"
      end
    end
  end
end
