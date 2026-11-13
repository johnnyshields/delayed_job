require 'fileutils'

module Delayed
  # The pidfile of a forking launcher (Delayed::Launcher::Forking with the
  # :pid_file option). Holds the pid of the supervising process, and keeps a
  # second launcher from starting while the first one runs.
  #
  # Whether a launcher runs is decided by an exclusive lock (flock) on the
  # file, not by the pid in it: the lock is released by the OS however the
  # process ends (even SIGKILL), so a stale file never blocks a start, and a
  # recycled pid never fakes a running launcher. Forked worker processes
  # inherit the lock (see .lock_file?), so it is only released once the
  # launcher and all of its workers have exited.
  class Pidfile
    attr_reader :path

    # Whether `file` is the locked file of a Pidfile. Worker.after_fork
    # reopens the files open in the parent; reopening this one would drop
    # the lock in the worker.
    def self.lock_file?(file)
      file.instance_variable_defined?(:@delayed_pidfile)
    end

    def initialize(path)
      @path = path.to_s
    end

    # Locks the file and writes this process' pid in it. Raises
    # Delayed::AlreadyRunningError if another process holds the lock.
    def setup
      FileUtils.mkdir_p(File.dirname(path))
      @file = lock_file
      @file.truncate(0)
      @file.write("#{Process.pid}\n")
      @file.flush
      self
    end

    # Removes the file and releases the lock. Only in the process that set
    # it up: not from forked children, and never a newer launcher's file.
    def delete
      return unless @file && @owner == Process.pid
      File.delete(path) if same_file?(@file)
      @file.close
      @file = nil
    rescue Errno::ENOENT
      nil
    end

    # The pid in the file, or nil if there is no file or it holds no pid.
    def read_pid
      pid = File.read(path).strip
      Integer(pid, 10) if pid =~ /\A\d+\z/
    rescue Errno::ENOENT
      nil
    end

  private

    def lock_file
      loop do
        file = File.open(path, File::RDWR | File::CREAT, 0o644)
        unless file.flock(File::LOCK_EX | File::LOCK_NB)
          file.close
          raise AlreadyRunningError.new(path, read_pid)
        end
        # The previous holder may have deleted the file between our open
        # and our lock: then we locked a file nobody else will open.
        if same_file?(file)
          file.instance_variable_set(:@delayed_pidfile, true)
          @owner = Process.pid
          return file
        end
        file.close
      end
    end

    def same_file?(file)
      File.identical?(path, file)
    rescue Errno::ENOENT
      false
    end
  end
end
