module Delayed
  module Launcher
    # Mold process (experimental), child side; see Delayed::Worker.mold and
    # MoldSupervisor (the parent side).
    #
    # A promoted child process stops like on TERM, then forks a mold and
    # exits. The mold (an orphan, so no mold is ever another mold's child)
    # runs no jobs: it only forks child processes the parent asks for, which
    # share its warmed memory copy-on-write, and reports their exits.
    #
    # Pipes, opened by the parent before its first fork:
    # * fork pipe: the parent writes FORK_RECORD (worker index, pool index);
    #   only the active mold reads it.
    # * status pipe: one line per message, shorter than PIPE_BUF so writes
    #   from several processes don't interleave:
    #     b <pid>                   child booted
    #     p <pid> <jobs> <busy>     child ping (jobs performed, busy threads)
    #     M <child pid> <mold pid>  promoted child forked its mold
    #     m <mold pid>              mold ready
    #     f <mold pid> <pid> <idx>  mold forked a child
    #     x <pid> <exit> <signal>   mold reaped a child ("-" when nil)
    # * life pipe: never written; EOF tells molds the parent is gone.
    module Mold
      FORK_RECORD = 'NN'.freeze
      FORK_RECORD_BYTES = 8
      NO_POOL = 0xFFFF_FFFF

      def self.included(base)
        # Seconds between child pings; tests lower it.
        base.class_attribute :mold_ping_interval, :instance_writer => false, :default => 5
      end

    private

      def mold_thresholds
        return @mold_thresholds if defined?(@mold_thresholds)
        @mold_thresholds = Delayed::Worker.mold_thresholds(@options.key?(:mold) ? @options[:mold] : Delayed::Worker.mold)
      end

      def molding?
        !mold_thresholds.nil?
      end

      def open_mold_pipes
        @fork_read, @fork_write = IO.pipe
        @status_read, @status_write = IO.pipe
        @life_read, @life_write = IO.pipe
        @fork_write.sync = true
        @status_write.sync = true
      end

      # In a child forked by the parent.
      def close_parent_pipe_ends
        [@fork_write, @status_read, @life_write].each(&:close)
      end

      # Lines are written whole (sync), so they don't interleave. A ping is
      # dropped rather than block when the parent falls behind.
      def report(line, blocking: true)
        line = "#{line}\n"
        blocking ? @status_write.write(line) : @status_write.write_nonblock(line, :exception => false)
      rescue IOError, SystemCallError
        nil # The parent is gone.
      end

      def run_dispatcher(worker_name, dispatcher, pending_signals)
        return super unless molding?
        Signal.trap('URG') { dispatcher.promote }
        report("b #{Process.pid}") # After the trap: the parent only promotes booted children.
        ping = start_mold_ping(dispatcher)
        super
        return unless dispatcher.promoted?
        ping.kill.join
        fork_mold(worker_name)
      end

      def start_mold_ping(dispatcher)
        Thread.new do
          loop do
            report("p #{Process.pid} #{dispatcher.jobs_performed} #{dispatcher.busy_threads}", :blocking => false)
            sleep mold_ping_interval
          end
        end
      end

      # This process then exits, orphaning the mold: a mold's children are
      # never molds, so a retired mold can exit once its children have.
      def fork_mold(worker_name)
        Delayed::Worker.before_fork
        mold_pid = fork do
          run_mold(worker_name)
          exit!(0) # Not the dispatcher's at_exit hooks again.
        end
        report("M #{Process.pid} #{mold_pid}")
      end

      def run_mold(worker_name)
        wake_read, wake_write = @mold_wake = IO.pipe
        trap_mold_signals(wake_write)
        @supervisor_pid = Process.pid # Of the children it forks.
        @mold_children = {}
        set_process_name("#{worker_name}: mold")
        warmup_heap
        Delayed::Worker.lifecycle.run_callbacks(:mold, Process.pid) do
          report("m #{Process.pid}")
          mold_loop(wake_read)
        end
      end

      # Traps only write to the wake pipe: C child exited, U retired (stop
      # forking), S stop (stop forking, exit once the children have). In a
      # child forked before it replaces them, they record the signal (see
      # Forking#capture_signals).
      def trap_mold_signals(wake_write)
        mold_pid = Process.pid
        {'CHLD' => 'C', 'URG' => 'U', 'TERM' => 'S', 'INT' => 'S', 'QUIT' => 'S'}.each do |signal, code|
          Signal.trap(signal) do
            if Process.pid == mold_pid
              wake_write.write_nonblock(code, :exception => false)
            elsif code == 'S'
              child_signal(signal)
            end
          end
        end
        Signal.trap('HUP', 'IGNORE')
      end

      # Until retired or stopping with no children left, or the parent is
      # gone (life pipe EOF; the children then stop by themselves).
      def mold_loop(wake_read)
        @mold_done = false # Retired or stopping: forks nothing more.
        loop do
          ready = wait_for_mold_work(wake_read)
          reap_mold_children
          return if ready.include?(@life_read)
          fork_requested_child if ready.include?(@fork_read) && !@mold_done
          return if @mold_done && @mold_children.empty?
        end
      end

      # Returns the readable pipes; wakes at least every second.
      def wait_for_mold_work(wake_read)
        readers = [wake_read, @life_read]
        readers << @fork_read unless @mold_done
        ready = IO.select(readers, nil, nil, 1)&.first || []
        read_mold_wakeups(wake_read)
        ready
      end

      def read_mold_wakeups(wake_read)
        codes = wake_read.read_nonblock(64, :exception => false)
        @mold_done = true if codes.is_a?(String) && codes.match?(/[US]/)
      end

      def fork_requested_child
        record = @fork_read.read_nonblock(FORK_RECORD_BYTES, :exception => false)
        return unless record.is_a?(String) && record.bytesize == FORK_RECORD_BYTES
        worker_index, pool_index = record.unpack(FORK_RECORD)
        worker_name = get_name(worker_index)
        options = pool_index == NO_POOL ? @options : @options.merge(:queues => pools[pool_index].first)
        child_signals.clear # Before forking: the child's traps append to it.
        pid = fork do
          pending_signals = capture_signals
          @mold_wake.each(&:close)
          %w[CHLD URG].each { |signal| Signal.trap(signal, 'DEFAULT') }
          run_worker(worker_name, options, pending_signals)
        end
        @mold_children[pid] = true
        report("f #{Process.pid} #{pid} #{worker_index}")
      end

      def reap_mold_children
        loop do
          pid, status = Process.wait2(-1, Process::WNOHANG)
          break unless pid
          @mold_children.delete(pid)
          report("x #{pid} #{status.exitstatus || '-'} #{status.termsig || '-'}")
        end
      rescue Errno::ECHILD
        nil
      end
    end
  end
end
