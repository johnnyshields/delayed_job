module Delayed
  module Launcher
    # Mold process (experimental); see Delayed::Worker.mold, and
    # MoldSupervisor for the parent side.
    #
    # A promoted child process stops like on TERM, forks a mold and exits.
    # The mold (an orphan, so no mold is ever another mold's child) runs no
    # jobs: it forks the child processes the parent asks for, which share its
    # warmed memory copy-on-write, and reports their exits.
    class Mold
      FORK_RECORD = 'NN'.freeze # worker index, pool index
      FORK_RECORD_BYTES = 8
      NO_POOL = 0xFFFF_FFFF

      # Index of the pool with these options' queues, or NO_POOL.
      def self.pool_index(pools, options)
        return NO_POOL unless pools
        pools.index { |queues, _| queues == options[:queues] } || NO_POOL
      end

      # Pipes opened by the parent before its first fork, inherited by every
      # child process and mold:
      # * fork: the parent writes FORK_RECORDs; only the active mold reads.
      # * status: one line per message, shorter than PIPE_BUF so writes from
      #   several processes don't interleave:
      #     b <pid>                   child booted
      #     p <pid> <jobs> <busy>     child ping (jobs performed, busy threads)
      #     M <child pid> <mold pid>  promoted child forked its mold
      #     m <mold pid>              mold ready
      #     f <mold pid> <pid> <idx>  mold forked a child
      #     x <pid> <exit> <signal>   mold reaped a child ("-" when nil)
      # * life: never written; EOF tells a mold the parent is gone.
      class Pipes
        attr_reader :fork_read, :life_read

        def initialize
          @fork_read, @fork_write = IO.pipe
          @status_read, @status_write = IO.pipe
          @life_read, @life_write = IO.pipe
          @fork_write.sync = true
          @status_write.sync = true
          @status_buffer = +''
        end

        # In a child process. Idempotent.
        def close_parent_ends
          [@fork_write, @status_read, @life_write].each(&:close)
        end

        # Lines are written whole (sync). A ping is dropped rather than block
        # when the parent falls behind.
        def report(line, blocking: true)
          line = "#{line}\n"
          blocking ? @status_write.write(line) : @status_write.write_nonblock(line, :exception => false)
        rescue IOError, SystemCallError
          nil # The parent is gone.
        end

        def request_fork(worker_index, pool_index)
          @fork_write.write([worker_index, pool_index].pack(FORK_RECORD))
        end

        # [worker index, pool index], or nil.
        def read_fork_request
          record = @fork_read.read_nonblock(FORK_RECORD_BYTES, :exception => false)
          record.unpack(FORK_RECORD) if record.is_a?(String) && record.bytesize == FORK_RECORD_BYTES
        end

        def drain_fork_requests
          loop { break unless @fork_read.read_nonblock(4096, :exception => false).is_a?(String) }
        end

        # Yields each status line received within `timeout` seconds, as its
        # type and integer arguments (nil for "-").
        def each_status(timeout)
          return unless @status_read.wait_readable(timeout)
          @status_buffer << @status_read.read_nonblock(65_536)
          while (line = @status_buffer.slice!(/\A[^\n]*\n/))
            type, *args = line.split
            yield type, *args.map { |arg| arg == '-' ? nil : arg.to_i }
          end
        rescue IO::WaitReadable
          nil
        end
      end

      def initialize(launcher, pipes)
        @launcher = launcher
        @pipes = pipes
        @children = {}
        @done = false # Retired or stopping: forks nothing more.
      end

      # Yields once the signal traps are in place (to prepare the process).
      # Returns once retired or stopping with no children left, or once the
      # parent is gone (its children then stop by themselves).
      def run
        @wake_read, @wake_write = IO.pipe
        trap_signals
        yield if block_given?
        Delayed::Worker.lifecycle.run_callbacks(:mold, Process.pid) do
          @pipes.report("m #{Process.pid}")
          fork_loop
        end
      end

    private

      # Traps only write to the wake pipe: C child exited, U retired (stop
      # forking), S stop (stop forking, exit once the children have). In a
      # child, before it replaces them, they record the signal (see
      # Forking#capture_signals).
      def trap_signals
        mold_pid = Process.pid
        {'CHLD' => 'C', 'URG' => 'U', 'TERM' => 'S', 'INT' => 'S', 'QUIT' => 'S'}.each do |signal, code|
          Signal.trap(signal) do
            if Process.pid == mold_pid
              @wake_write.write_nonblock(code, :exception => false)
            elsif code == 'S'
              @launcher.child_signal(signal)
            end
          end
        end
        Signal.trap('HUP', 'IGNORE')
      end

      def fork_loop
        loop do
          ready = wait_for_work
          reap_children
          return if ready.include?(@pipes.life_read)
          fork_requested_child if ready.include?(@pipes.fork_read) && !@done
          return if @done && @children.empty?
        end
      end

      # Returns the readable pipes; wakes at least every second.
      def wait_for_work
        readers = [@wake_read, @pipes.life_read]
        readers << @pipes.fork_read unless @done
        ready = IO.select(readers, nil, nil, 1)&.first || []
        codes = @wake_read.read_nonblock(64, :exception => false)
        @done = true if codes.is_a?(String) && codes.match?(/[US]/)
        ready
      end

      def fork_requested_child
        worker_index, pool_index = @pipes.read_fork_request
        return unless worker_index
        pid = @launcher.fork_mold_child(worker_index, pool_index, [@wake_read, @wake_write])
        @children[pid] = true
        @pipes.report("f #{Process.pid} #{pid} #{worker_index}")
      end

      def reap_children
        loop do
          pid, status = Process.wait2(-1, Process::WNOHANG)
          break unless pid
          @children.delete(pid)
          @pipes.report("x #{pid} #{status.exitstatus || '-'} #{status.termsig || '-'}")
        end
      rescue Errno::ECHILD
        nil
      end
    end
  end
end
