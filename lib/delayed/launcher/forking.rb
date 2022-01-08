require 'delayed/launcher/single'
require 'delayed/launcher/cluster'
require 'delayed/launcher/pooled_cluster'

module Delayed
  module Launcher

    # Parent launcher class which spawns DelayedJob worker processes
    # in the foreground.
    #
    # Some code in this class is lovingly borrowed from Puma (puma.io)
    class Forking
      include Loggable

      KILL_TIMEOUT = 30

      def initialize(options)

        # Remove options used only for Launcher::Daemonized
        options[:daemonized] = false
        options.delete(:monitor)
        options.delete(:args)

        # Set default options
        options[:worker_count] ||= 1
        options.delete(:pools) if options[:pools] == []
        options[:pid_dir] ||= "#{Delayed.root}/tmp/pids"
        options[:log_dir] ||= "#{Delayed.root}/log"

        @options = options

        # TODO - RESTART?
        @argv = options[:argv] || []
        @original_argv = @argv.dup
        generate_restart_data
        Dir.chdir(@restart_dir)
        prune_bundler if prune_bundler?

        @status = :run
      end

      def run
        @runner = build_runner
        setup_signals
        @runner.run
      end

      # Begin graceful shutdown of the workers
      def stop(timeout = nil)
        @status = :stop
        @runner.stop(timeout)
      end

      # Begin forced shutdow nof the workers
      def halt
        @status = :halt
        @runner.halt
      end

      # Begin restart of the workers
      def restart
        @status = :restart
        @runner.restart
      end

      # Begin phased restart of the workers
      def phased_restart
        if @runner.respond_to?(:phased_restart)
          @runner.phased_restart
        else
          logger.warn 'phased_restart called but not available, restarting normally.'
          restart
        end
      end

    private

      def restart!
        if Delayed.jruby?
          require_relative 'jruby_restart'
          JRubyRestart.chdir_exec(@restart_dir, restart_args)
        elsif Delayed.windows?
          argv = restart_args
          Dir.chdir(@restart_dir)
          Kernel.exec(*argv)
        else
          argv = restart_args
          Dir.chdir(@restart_dir)
          Kernel.exec(*argv)
        end
      end

      def build_runner
        if @options[:pools]
          PooledCluster.new(self, @options)
        elsif @options[:worker_count] > 1
          Cluster.new(self, @options)
        else
          Single.new(self, @options)
        end
      end

      def prune_bundler?
        @options[:prune_bundler] && clustered?
      end

      def clustered?
        @options[:pools] || @options[:worker_count] > 1
      end

      def setup_signals
        setup_signal_restart
        setup_signal_phased_restart
        setup_signal_term
        setup_signal_int
      end

      def setup_signal_restart
        Signal.trap('SIGUSR2') { restart }
      rescue Exception # rubocop:disable Lint/RescueException
        logger.info '*** SIGUSR2 not implemented, signal based restart unavailable!'
      end

      def setup_signal_phased_restart
        return if Delayed.jruby?
        Signal.trap('SIGUSR1') { phased_restart }
      rescue Exception # rubocop:disable Lint/RescueException
        logger.info '*** SIGUSR1 not implemented, signal based restart unavailable!'
      end

      def setup_signal_term
        Signal.trap('SIGTERM') do
          stop
          raise(SignalException, 'SIGTERM') if raise_sigterm
        end
      rescue Exception # rubocop:disable Lint/RescueException
        logger.info '*** SIGTERM not implemented, signal based gracefully stopping unavailable!'
      end

      def setup_signal_int
        Signal.trap('SIGINT') do
          stop
          raise(SignalException, 'SIGINT') if raise_sigint
        end
      rescue Exception # rubocop:disable Lint/RescueException
        logger.info '*** SIGINT not implemented, signal based gracefully stopping unavailable!'
      end

      def raise_sigterm
        Delayed::Worker.raise_signal_exceptions
      end

      def raise_sigint
        Delayed::Worker.raise_signal_exceptions && Delayed::Worker.raise_signal_exceptions != :term
      end

      def restart_args
        cmd = @options[:restart_cmd]
        if cmd
          cmd.split(' ') + @original_argv
        else
          @restart_argv
        end
      end

      def generate_restart_data
        if (dir = @options[:directory])
          @restart_dir = dir
        elsif Delayed.windows?
          @restart_dir = Dir.pwd
        elsif (dir = ENV['PWD'])
          s_env = File.stat(dir)
          s_pwd = File.stat(Dir.pwd)
          if s_env.ino == s_pwd.ino && (Puma.jruby? || s_env.dev == s_pwd.dev)
            @restart_dir = dir
          end
        end

        @restart_dir ||= Dir.pwd

        # If $0 is a file in the current directory, then restart
        # it the same, otherwise add -S on there because it was
        # picked up in PATH.
        arg0 = if File.exist?($0)
          [Gem.ruby, $0]
        else
          [Gem.ruby, '-S', $0]
        end

        # Detect and reinject -Ilib from the command line, used for
        # testing without bundler. cruby has an expanded path,
        # jruby has just "lib"
        lib = File.expand_path "lib"
        arg0[1, 0] = ["-I", lib] if [lib, "lib"].include?($LOAD_PATH[0])

        @restart_argv = if defined?(Delayed::WILD_ARGS)
          arg0 + Delayed::WILD_ARGS + @original_argv
        else
          arg0 + @original_argv
        end
      end
    end
  end
end
