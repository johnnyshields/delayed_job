# frozen_string_literal: true

module Puma
  module Launcher
    # This class is instantiated by the `Puma::Cluster` and represents a single
    # worker process.
    #
    # At the core of this class is running an instance of `Delayed::Worker` which
    # gets created via the `start_worker` method.
    class ChildProcess
      attr_reader :index,
                  :master

      def initialize(index:, master:, launcher:, pipes:, worker: nil)
        super(launcher, launcher.events)

        @index = index
        @master = master
        @launcher = launcher
        @options = launcher.options
        @check_pipe = pipes[:check_pipe]
        @worker_write = pipes[:worker_write]
        @fork_pipe = pipes[:fork_pipe]
        @wakeup = pipes[:wakeup]
        @worker = worker
      end

      def run
        title  = "puma: cluster worker #{index}: #{master}"
        title += " [#{@options[:tag]}]" if @options[:tag] && !@options[:tag].empty?
        $0 = title

        Signal.trap "SIGINT", "IGNORE"
        Signal.trap "SIGCHLD", "DEFAULT"

        Thread.new do
          Delayed.set_thread_name "wrkr check"
          @check_pipe.wait_readable
          log "! Detected parent died, dying"
          exit! 1
        end

        # If we're not running under a Bundler context, then
        # report the info about the context we will be using
        if !ENV['BUNDLE_GEMFILE']
          if File.exist?("Gemfile")
            log "+ Gemfile in context: #{File.expand_path("Gemfile")}"
          elsif File.exist?("gems.rb")
            log "+ Gemfile in context: #{File.expand_path("gems.rb")}"
          end
        end

        # Invoke any worker boot hooks so they can get
        # things in shape before booting the app.
        @launcher.config.run_hooks :before_worker_boot, index, @launcher.events

        begin
          worker = @worker ||= start_worker
        rescue Exception => e
          log "! Unable to start worker"
          log e.backtrace[0]
          exit 1
        end

        restart_worker = Queue.new << true << false

        fork_worker = @options[:fork_worker] && index == 0

        if fork_worker
          restart_worker.clear
          worker_pids = []
          Signal.trap "SIGCHLD" do
            wakeup! if worker_pids.reject! do |p|
              Process.wait(p, Process::WNOHANG) rescue true
            end
          end

          Thread.new do
            Delayed.set_thread_name "wrkr fork"
            while (idx = @fork_pipe.gets)
              idx = idx.to_i
              if idx == -1 # stop worker
                if restart_worker.length > 0
                  restart_worker.clear
                  worker.begin_restart(true)
                  @launcher.config.run_hooks :before_refork, nil, @launcher.events
                  Puma::Util.nakayoshi_gc @events if @options[:nakayoshi_fork]
                end
              elsif idx == 0 # restart worker
                restart_worker << true << false
              else # fork worker
                worker_pids << pid = spawn_worker(idx)
                @worker_write << "f#{pid}:#{idx}\n" rescue nil
              end
            end
          end
        end

        Signal.trap "SIGTERM" do
          @worker_write << "e#{Process.pid}\n" rescue nil
          restart_worker.clear
          worker.stop
          restart_worker << false
        end

        begin
          @worker_write << "b#{Process.pid}:#{index}\n"
        rescue SystemCallError, IOError
          Puma::Util.purge_interrupt_queue
          STDERR.puts "Master seems to have exited, exiting."
          return
        end

        while restart_worker.pop
          worker_thread = worker.run
          stat_thread ||= Thread.new(@worker_write) do |io|
            Delayed.set_thread_name "stat pld"
            base_payload = "p#{Process.pid}"

            while true
              begin
                b = worker.backlog || 0
                r = worker.running || 0
                t = worker.pool_capacity || 0
                m = worker.max_threads || 0
                rc = worker.requests_count || 0
                payload = %Q!#{base_payload}{ "backlog":#{b}, "running":#{r}, "pool_capacity":#{t}, "max_threads": #{m}, "requests_count": #{rc} }\n!
                io << payload
              rescue IOError
                Puma::Util.purge_interrupt_queue
                break
              end
              sleep @options[:worker_check_interval]
            end
          end
          worker_thread.join
        end

        # Invoke any worker shutdown hooks so they can prevent the worker
        # exiting until any background operations are completed
        @launcher.config.run_hooks :before_worker_shutdown, index, @launcher.events
      ensure
        @worker_write << "t#{Process.pid}\n" rescue nil
        @worker_write.close
      end

      private

      def spawn_worker(idx)
        @launcher.config.run_hooks :before_worker_fork, idx, @launcher.events

        pid = fork do
          new_worker = Worker.new index: idx,
                                  master: master,
                                  launcher: @launcher,
                                  pipes: { check_pipe: @check_pipe,
                                           worker_write: @worker_write },
                                  worker: @worker
          new_worker.run
        end

        if !pid
          log "! Complete inability to spawn new workers detected"
          log "! Seppuku is the only choice."
          exit! 1
        end

        @launcher.config.run_hooks :after_worker_fork, idx, @launcher.events
        pid
      end
    end
  end
end
