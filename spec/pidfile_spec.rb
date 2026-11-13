require 'helper'
require 'tmpdir'

describe Delayed::Pidfile do
  around do |example|
    Dir.mktmpdir('dj-pidfile') do |dir|
      @dir = dir
      example.run
    end
  end

  let(:path) { File.join(@dir, 'pids', 'delayed_job.pid') }
  subject(:pidfile) { described_class.new(path) }

  after { pidfile.delete }

  def write_pid(content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  # Runs Ruby code in another process (spawned, not forked: a fork would
  # inherit the spec suite's database connections), with the pidfile path
  # as ARGV[0]; returns [pid, output_reader].
  def spawn_ruby(code)
    reader, writer = IO.pipe
    pid = Process.spawn(RbConfig.ruby, '-I', File.expand_path('../lib', __dir__), '-rdelayed/exceptions', '-rdelayed/pidfile', '-e', code, path,
                        :out => writer)
    writer.close
    [pid, reader]
  end

  # Starts another process holding the pidfile; returns its pid once it
  # holds it.
  def hold_in_other_process
    pid, reader = spawn_ruby("Delayed::Pidfile.new(ARGV[0]).setup; puts 'held'; STDOUT.flush; sleep 30")
    expect(reader.gets).to eq "held\n"
    reader.close
    @holders = (@holders || []) << pid
    pid
  end

  after do
    (@holders || []).each do |pid|
      Process.kill('KILL', pid)
      Process.wait(pid)
    end
  end

  describe '#setup' do
    it "writes this process' pid, creating the directory" do
      expect(pidfile.setup).to be pidfile
      expect(File.read(path)).to eq "#{Process.pid}\n"
    end

    it 'accepts a Pathname' do
      named = described_class.new(Pathname.new(path)).setup
      expect(File.read(path)).to eq "#{Process.pid}\n"
      named.delete
    end

    it 'raises AlreadyRunningError while another process holds it' do
      other = hold_in_other_process
      expect { pidfile.setup }.to raise_error(Delayed::AlreadyRunningError) do |error|
        expect(error.pid).to eq other
        expect(error.path).to eq path
        expect(error.message).to eq "delayed_job is already running (pid #{other}): pidfile #{path} exists. " \
                                    'Stop that process, or delete the file if it is not a delayed_job process.'
      end
      expect(File.read(path)).to eq "#{other}\n"
    end

    it 'says so when the running process has not written its pid yet' do
      FileUtils.mkdir_p(File.dirname(path))
      pid, reader = spawn_ruby(<<-RUBY)
        file = File.open(ARGV[0], File::RDWR | File::CREAT)
        file.flock(File::LOCK_EX)
        puts 'locked'
        STDOUT.flush
        sleep 30
      RUBY
      @holders = [pid]
      expect(reader.gets).to eq "locked\n"
      expect { pidfile.setup }.to raise_error(Delayed::AlreadyRunningError, "delayed_job is already running: pidfile #{path} exists. " \
                                                                             'Stop that process, or delete the file if it is not a delayed_job process.')
    end

    it 'can be set up again once the process holding it was SIGKILLed' do
      other = hold_in_other_process
      Process.kill('KILL', other)
      Process.wait(other)
      @holders.delete(other)
      expect(File.read(path)).to eq "#{other}\n" # Left behind.
      pidfile.setup
      expect(File.read(path)).to eq "#{Process.pid}\n"
    end

    it 'replaces the pid of a process that is not running, whatever is in the file' do
      write_pid("#{Process.ppid}\n") # A live pid, but it doesn't hold the lock: a recycled pid.
      pidfile.setup
      expect(File.read(path)).to eq "#{Process.pid}\n"
    end

    it 'replaces a longer pid without leaving trailing digits' do
      write_pid("123456789\n")
      pidfile.setup
      expect(File.read(path)).to eq "#{Process.pid}\n"
    end

    it 'raises AlreadyRunningError when this process already holds it through another Pidfile' do
      pidfile.setup
      expect { described_class.new(path).setup }.to raise_error(Delayed::AlreadyRunningError, /pid #{Process.pid}/)
    end

    it 'retries when the file it locked was deleted by the previous holder in between' do
      FileUtils.mkdir_p(File.dirname(path))
      opened = 0
      allow(File).to receive(:open).and_wrap_original do |original, *args, &block|
        opened += 1
        original.call(*args, &block).tap do
          # The previous holder deletes its file (as it exits) right after we opened it.
          File.delete(path) if opened == 1
        end
      end
      pidfile.setup
      expect(opened).to eq 2
      expect(File.read(path)).to eq "#{Process.pid}\n"
    end

    it 'lets only one of several processes starting at once run' do
      started = Array.new(4) do
        spawn_ruby(<<-RUBY)
          begin
            Delayed::Pidfile.new(ARGV[0]).setup
            print 'ok'
            STDOUT.flush
            sleep 2 # Keep running while the others start.
          rescue Delayed::AlreadyRunningError
            print 'running'
          end
        RUBY
      end
      results = started.map { |_, reader| reader.read.tap { reader.close } }
      started.each { |pid, _| Process.wait(pid) }
      expect(results.sort).to eq %w[ok running running running]
    end
  end

  describe '#delete' do
    it 'removes the file and releases the lock' do
      pidfile.setup
      pidfile.delete
      expect(File.exist?(path)).to be false
      other = hold_in_other_process
      expect(File.read(path)).to eq "#{other}\n"
    end

    it 'does nothing when it was not set up' do
      write_pid("#{Process.ppid}\n")
      pidfile.delete
      expect(File.read(path)).to eq "#{Process.ppid}\n"
    end

    it 'does nothing when called twice' do
      pidfile.setup
      pidfile.delete
      expect { pidfile.delete }.not_to raise_error
    end

    it 'does not delete it from another process, such as a forked worker' do
      pidfile.setup
      parent = Process.pid
      allow(Process).to receive(:pid).and_return(parent + 1)
      pidfile.delete
      expect(File.read(path)).to eq "#{parent}\n"
      allow(Process).to receive(:pid).and_return(parent)
    end

    it "leaves a newer launcher's file alone when its own was replaced" do
      pidfile.setup
      File.delete(path)
      write_pid("4242\n")
      pidfile.delete
      expect(File.read(path)).to eq "4242\n"
    end
  end

  describe '.lock_file?' do
    it 'is true for the locked file of a pidfile' do
      pidfile.setup
      expect(described_class.lock_file?(pidfile.instance_variable_get(:@file))).to be true
    end

    it 'is false for other files' do
      write_pid('1')
      File.open(path) { |file| expect(described_class.lock_file?(file)).to be false }
    end
  end

  # Worker.after_fork reopens the files open in the parent (log files); it
  # must not reopen the pidfile, which would drop the lock in the worker.
  describe 'Worker.before_fork and .after_fork' do
    around do |example|
      Delayed::Worker.instance_variable_set(:@files_to_reopen, nil)
      example.run
    ensure
      Delayed::Worker.instance_variable_set(:@files_to_reopen, nil)
    end

    before do
      allow(Delayed::Worker.backend).to receive(:before_fork)
      allow(Delayed::Worker.backend).to receive(:after_fork)
    end

    it 'does not reopen the pidfile' do
      pidfile.setup
      log = File.open(File.join(@dir, 'other.log'), 'a')
      Delayed::Worker.before_fork
      reopened = Delayed::Worker.instance_variable_get(:@files_to_reopen)
      expect(reopened).to include log
      expect(reopened).not_to include pidfile.instance_variable_get(:@file)
      Delayed::Worker.after_fork
      # The lock survives: another process still can't take the pidfile.
      expect(File.read(path)).to eq "#{Process.pid}\n"
      _, reader = spawn_ruby("begin; Delayed::Pidfile.new(ARGV[0]).setup; print 'took it'; rescue Delayed::AlreadyRunningError; print 'refused'; end")
      expect(reader.read).to eq 'refused'
      reader.close
      Process.waitall
    ensure
      log.close if log
    end
  end

  describe '#read_pid' do
    it 'is nil without a file' do
      expect(pidfile.read_pid).to be_nil
    end

    it 'reads the pid, ignoring surrounding whitespace' do
      write_pid(" 123\n")
      expect(pidfile.read_pid).to eq 123
    end

    it 'reads pids with leading zeros as decimal' do
      write_pid('0123')
      expect(pidfile.read_pid).to eq 123
    end

    it 'is nil when the file does not hold a pid' do
      write_pid('12abc')
      expect(pidfile.read_pid).to be_nil
    end

    it 'is nil when the file is empty' do
      write_pid('')
      expect(pidfile.read_pid).to be_nil
    end
  end
end
