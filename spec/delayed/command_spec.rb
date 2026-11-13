require 'helper'
require 'delayed/command'

describe Delayed::Command do
  let(:options) { [] }
  let(:logger) { double('Logger') }
  let(:output_options) { subject.instance_variable_get(:'@options') }
  subject { Delayed::Command.new(options) }

  def verify_worker_processes
    command = Delayed::Command.new(%w[-d] + options)
    allow(FileUtils).to receive(:mkdir_p)
    exp.each do |args|
      expect(command.send(:launcher)).to receive(:run_process).with(*args).once
    end
    command.launch
  end

  describe '#launch' do
    it 'should use fork mode by default' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to_not receive(:launch)
      expect_any_instance_of(Delayed::Launcher::Forking).to receive(:launch)
      Delayed::Command.new([]).launch
    end

    it 'should use fork mode if --fork set' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to_not receive(:launch)
      expect_any_instance_of(Delayed::Launcher::Forking).to receive(:launch)
      Delayed::Command.new(%w[--fork]).launch
    end

    it 'should use daemon mode if -d set' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:launch)
      expect_any_instance_of(Delayed::Launcher::Forking).to_not receive(:launch)
      Delayed::Command.new(%w[-d]).launch
    end

    it 'should use daemon mode if --daemonize set' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:launch)
      expect_any_instance_of(Delayed::Launcher::Forking).to_not receive(:launch)
      Delayed::Command.new(%w[--daemonize]).launch
    end

    it 'using multiple switches should use first one' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:launch)
      expect_any_instance_of(Delayed::Launcher::Forking).to_not receive(:launch)
      Delayed::Command.new(%w[-d --fork]).launch
    end
  end

  describe '#daemonize' do
    it 'should use daemon mode by default' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:launch)
      expect_any_instance_of(Delayed::Launcher::Forking).to_not receive(:launch)
      Delayed::Command.new([]).daemonize
    end

    it 'should use fork mode if --fork set' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to_not receive(:launch)
      expect_any_instance_of(Delayed::Launcher::Forking).to receive(:launch)
      Delayed::Command.new(%w[--fork]).daemonize
    end

    it 'should use daemon mode if -d set' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:launch)
      expect_any_instance_of(Delayed::Launcher::Forking).to_not receive(:launch)
      Delayed::Command.new(%w[-d]).daemonize
    end

    it 'should use daemon mode if --daemonize set' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:launch)
      expect_any_instance_of(Delayed::Launcher::Forking).to_not receive(:launch)
      Delayed::Command.new(%w[--daemonize]).daemonize
    end

    it 'using multiple switches should use first one' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to_not receive(:launch)
      expect_any_instance_of(Delayed::Launcher::Forking).to receive(:launch)
      Delayed::Command.new(%w[--fork -d]).daemonize
    end
  end

  describe '--min-priority arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:min_priority]).to eq nil }
    end

    context 'set' do
      let(:options) { %w[--min-priority 2] }
      it { expect(output_options[:min_priority]).to eq 2 }
    end

    context 'not a number' do
      let(:options) { %w[--min-priority sponge] }
      it { expect(output_options[:min_priority]).to eq nil }
    end
  end

  describe '--max-priority arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:max_priority]).to eq nil }
    end

    context 'set' do
      let(:options) { %w[--max-priority -5] }
      it { expect(output_options[:max_priority]).to eq(-5) }
    end

    context 'not a number' do
      let(:options) { %w[--max-priority giraffe] }
      it { expect(output_options[:max_priority]).to eq nil }
    end
  end

  describe '--processes arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:processes]).to eq 1 }
    end

    context '-n set' do
      let(:options) { %w[-n 2] }
      it { expect(output_options[:processes]).to eq 2 }
    end

    context '-n not a number' do
      let(:options) { %w[-n elephant] }
      it { expect(output_options[:processes]).to eq 1 }
    end

    context '--processes set' do
      let(:options) { %w[--processes 3] }
      it { expect(output_options[:processes]).to eq 3 }
    end

    context '--processes= set' do
      let(:options) { %w[--processes=6] }
      it { expect(output_options[:processes]).to eq 6 }
    end

    context '--processes not a number' do
      let(:options) { %w[--processes zebu] }
      it { expect(output_options[:processes]).to eq 1 }
    end

    context '--num-workers (deprecated) set' do
      let(:options) { %w[--num-workers 4] }
      it do
        expect(STDERR).to receive(:puts).with(/DEPRECATED: Use -n or --processes instead of --num-workers/)
        expect(output_options[:processes]).to eq 4
      end
    end

    context '--num-workers not a number' do
      let(:options) { %w[--num-workers hippo] }
      it do
        expect(STDERR).to receive(:puts)
        expect(output_options[:processes]).to eq 1
      end
    end

    context '--number_of_workers (deprecated) set' do
      let(:options) { %w[--number_of_workers 5] }
      it do
        expect(STDERR).to receive(:puts).with(/DEPRECATED: Use -n or --processes instead of --number_of_workers/)
        expect(output_options[:processes]).to eq 5
      end
    end

    context '--processes does not warn' do
      let(:options) { %w[--processes 2] }
      it do
        expect(STDERR).not_to receive(:puts)
        expect(output_options[:processes]).to eq 2
      end
    end

    context '--number_of_workers not a number' do
      let(:options) { %w[--number_of_workers rhino] }
      it do
        expect(STDERR).to receive(:puts)
        expect(output_options[:processes]).to eq 1
      end
    end
  end

  describe '--threads arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:threads]).to eq nil }
    end

    context '-t set' do
      let(:options) { %w[-t 5] }
      it { expect(output_options[:threads]).to eq 5 }
    end

    context '--threads set' do
      let(:options) { %w[--threads 8] }
      it { expect(output_options[:threads]).to eq 8 }
    end

    context '--threads zero' do
      let(:options) { %w[--threads 0] }
      it { expect { output_options }.to raise_error(ArgumentError) }
    end

    context '--threads not a number' do
      let(:options) { %w[--threads zebra] }
      it { expect { output_options }.to raise_error(ArgumentError) }
    end
  end

  describe '--pid-dir arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:pid_dir]).to eq nil }
    end

    context 'set' do
      let(:options) { %w[--pid-dir ./foo/bar] }
      it { expect(output_options[:pid_dir]).to eq './foo/bar' }
    end

    context 'worker processes' do
      let(:options) { %w[--pid-dir ./foo/bar] }
      let(:exp) do
        [['delayed_job', {:quiet => true, :pid_dir => './foo/bar', :log_dir => './log'}]]
      end
      it { verify_worker_processes }
    end
  end

  describe '--pid-file arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options).not_to have_key(:pid_file) }
    end

    context 'set without a path' do
      let(:options) { %w[--pid-file start] }
      it 'uses the default path' do
        expect(output_options[:pid_file]).to be true
        expect(output_options[:args]).to eq %w[start]
      end
    end

    context 'set with a path' do
      let(:options) { %w[--pid-file=/var/run/dj.pid] }
      it { expect(output_options[:pid_file]).to eq '/var/run/dj.pid' }
    end

    it 'is passed to the forking launcher' do
      command = Delayed::Command.new(%w[--fork --pid-file=/var/run/dj.pid])
      expect(command.send(:launcher)).to be_a Delayed::Launcher::Forking
      expect(command.send(:launcher).pid_file).to eq '/var/run/dj.pid'
    end

    it 'is rejected in daemon mode' do
      expect { Delayed::Command.new(%w[--pid-file]).daemonize }.to raise_error(ArgumentError, /--pid-file is for --fork mode/)
    end
  end

  describe '--count-shutdown-interrupts arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options).not_to have_key(:count_shutdown_interrupts) }
    end

    context 'set' do
      let(:options) { %w[--count-shutdown-interrupts] }
      it { expect(output_options[:count_shutdown_interrupts]).to be true }
    end
  end

  describe '--shutdown-on-worker-kill arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options).not_to have_key(:shutdown_on_worker_kill) }
    end

    context 'set' do
      let(:options) { %w[--shutdown-on-worker-kill] }
      it { expect(output_options[:shutdown_on_worker_kill]).to be true }
    end
  end

  describe '--silence-polling arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options).not_to have_key(:silence_polling) }
    end

    context 'set' do
      let(:options) { %w[--silence-polling] }
      it { expect(output_options[:silence_polling]).to be true }
    end
  end

  describe '--log-dir arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:log_dir]).to eq nil }
    end

    context 'set' do
      let(:options) { %w[--log-dir ./foo/bar] }
      it { expect(output_options[:log_dir]).to eq './foo/bar' }
    end

    context 'worker processes' do
      let(:options) { %w[--log-dir ./foo/bar] }
      let(:exp) do
        [['delayed_job', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './foo/bar'}]]
      end
      it { verify_worker_processes }
    end
  end

  describe '--monitor arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:monitor]).to eq false }
    end

    context 'set' do
      let(:options) { %w[--monitor] }
      it { expect(output_options[:monitor]).to eq true }
    end
  end

  describe '--shutdown-timeout arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options).not_to have_key(:shutdown_timeout) }
    end

    context 'set to whole seconds' do
      let(:options) { %w[--shutdown-timeout 25] }
      it { expect(output_options[:shutdown_timeout]).to eq 25.0 }
    end

    context 'set to fractional seconds' do
      let(:options) { %w[--shutdown-timeout=2.5] }
      it { expect(output_options[:shutdown_timeout]).to eq 2.5 }
    end

    context 'set to 0' do
      let(:options) { %w[--shutdown-timeout 0] }
      it { expect(output_options[:shutdown_timeout]).to eq 0.0 }
    end

    context 'negative' do
      let(:options) { %w[--shutdown-timeout -1] }
      it { expect { output_options }.to raise_error(ArgumentError, /--shutdown-timeout/) }
    end

    context 'not a number' do
      let(:options) { %w[--shutdown-timeout soon] }
      it { expect { output_options }.to raise_error(ArgumentError, /--shutdown-timeout/) }
    end
  end

  describe '--lock-heartbeat and --lock-timeout args' do
    context 'not set' do
      let(:options) { [] }
      it do
        expect(output_options).not_to have_key(:lock_heartbeat_interval)
        expect(output_options).not_to have_key(:lock_timeout)
      end
    end

    context 'heartbeat only' do
      let(:options) { %w[--lock-heartbeat 30] }
      it { expect(output_options[:lock_heartbeat_interval]).to eq 30.0 }
    end

    context 'both' do
      let(:options) { %w[--lock-heartbeat=10 --lock-timeout=45] }
      it { expect(output_options.values_at(:lock_heartbeat_interval, :lock_timeout)).to eq [10.0, 45.0] }
    end

    context 'a heartbeat longer than half the default lock timeout' do
      let(:options) { %w[--lock-heartbeat 200] }
      it { expect { output_options }.to raise_error(ArgumentError, /at least twice --lock-heartbeat/) }
    end

    context 'a lock timeout under twice the heartbeat' do
      let(:options) { %w[--lock-heartbeat 10 --lock-timeout 15] }
      it { expect { output_options }.to raise_error(ArgumentError, /at least twice/) }
    end

    context 'heartbeat not a number' do
      let(:options) { %w[--lock-heartbeat often] }
      it { expect { output_options }.to raise_error(ArgumentError, /--lock-heartbeat must be greater than 0/) }
    end

    context 'lock timeout not positive' do
      let(:options) { %w[--lock-timeout 0] }
      it { expect { output_options }.to raise_error(ArgumentError, /--lock-timeout must be greater than 0/) }
    end
  end

  describe '--sleep-delay arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:sleep_delay]).to eq nil }
    end

    context 'set' do
      let(:options) { %w[--sleep-delay 5] }
      it { expect(output_options[:sleep_delay]).to eql(5) }
    end

    context 'set to fractional seconds' do
      let(:options) { %w[--sleep-delay 0.5] }
      it { expect(output_options[:sleep_delay]).to eql(0.5) }
    end

    context 'set with =' do
      let(:options) { %w[--sleep-delay=2.25] }
      it { expect(output_options[:sleep_delay]).to eql(2.25) }
    end

    context 'set to 0' do
      let(:options) { %w[--sleep-delay 0] }
      it { expect(output_options[:sleep_delay]).to eql(0) }
    end

    context 'with a leading zero' do
      let(:options) { %w[--sleep-delay 010] }
      it { expect(output_options[:sleep_delay]).to eql(10) } # Not octal.
    end

    context 'negative' do
      let(:options) { %w[--sleep-delay -1] }
      it { expect { output_options }.to raise_error(ArgumentError, '--sleep-delay must be a number of seconds, 0 or greater') }
    end

    context 'not a number' do
      let(:options) { %w[--sleep-delay giraffe] }
      it { expect { output_options }.to raise_error(ArgumentError, /--sleep-delay/) }
    end
  end

  describe '--read-ahead arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:read_ahead]).to eq nil }
    end

    context 'set' do
      let(:options) { %w[--read-ahead 5] }
      it { expect(output_options[:read_ahead]).to eq(5) }
    end

    context 'not a number' do
      let(:options) { %w[--read-ahead giraffe] }
      it { expect(output_options[:read_ahead]).to eq nil }
    end
  end

  describe '--identifier arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:identifier]).to eq nil }
    end

    context '-i set' do
      let(:options) { %w[-i bond] }
      it { expect(output_options[:identifier]).to eq 'bond' }
    end

    context '--identifier set' do
      let(:options) { %w[--identifier goldfinger] }
      it { expect(output_options[:identifier]).to eq 'goldfinger' }
    end

    context 'worker processes' do
      let(:options) { %w[--identifier spectre] }
      let(:exp) do
        [['delayed_job.spectre', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log'}]]
      end
      it { verify_worker_processes }
    end
  end

  describe '--prefix arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:prefix]).to eq nil }
    end

    context '-p set' do
      let(:options) { %w[-p oddjob] }
      it { expect(output_options[:prefix]).to eq 'oddjob' }
    end

    context '--prefix set' do
      let(:options) { %w[--prefix jaws] }
      it { expect(output_options[:prefix]).to eq 'jaws' }
    end
  end

  describe '--exit-on-complete arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:exit_on_complete]).to eq nil }
    end

    context '-x set' do
      let(:options) { %w[-x] }
      it { expect(output_options[:exit_on_complete]).to eq true }
    end

    context '--exit-on-complete set' do
      let(:options) { %w[--exit-on-complete] }
      it { expect(output_options[:exit_on_complete]).to eq true }
    end
  end

  describe '--verbose arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:quiet]).to eq true }
    end

    context '-v set' do
      let(:options) { %w[-v] }
      it { expect(output_options[:quiet]).to eq false }
    end

    context '--verbose set' do
      let(:options) { %w[--verbose] }
      it { expect(output_options[:quiet]).to eq false }
    end

    context 'worker processes' do
      let(:options) { %w[-v] }
      let(:exp) do
        [['delayed_job', {:quiet => false, :pid_dir => './tmp/pids', :log_dir => './log'}]]
      end
      it { verify_worker_processes }
    end
  end

  describe '--queues arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:queues]).to eq nil }
    end

    context '--queue set' do
      let(:options) { %w[--queue mailers] }
      it { expect(output_options[:queues]).to eq %w[mailers] }
    end

    context '--queues set' do
      let(:options) { %w[--queues mailers,tweets] }
      it { expect(output_options[:queues]).to eq %w[mailers tweets] }
    end

    context 'worker processes' do
      let(:options) { %w[--queues mailers,tweets] }
      let(:exp) do
        [['delayed_job', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => %w[mailers tweets]}]]
      end
      it { verify_worker_processes }
    end
  end

  describe '--pool arg' do
    context 'multiple --pool args set' do
      let(:options) { %w[--pool=*:1 --pool=test_queue:4 --pool=mailers,misc:2] }
      it 'should parse correctly' do
        expect(output_options[:pools]).to eq [
          [[], 1],
          [['test_queue'], 4],
          [%w[mailers misc], 2]
        ]
      end
    end

    context 'pipe-delimited' do
      let(:options) { %w[--pools=*:1|test_queue:4 --pool=mailers,misc:2] }
      it 'should parse correctly' do
        expect(output_options[:pools]).to eq [
          [[], 1],
          [['test_queue'], 4],
          [%w[mailers misc], 2]
        ]
      end
    end

    context 'queues specified as *' do
      let(:options) { ['--pool=*:4'] }
      it 'should use all queues' do
        expect(output_options[:pools]).to eq [[[], 4]]
      end
    end

    context 'queues not specified' do
      let(:options) { ['--pools=:4'] }
      it 'should use all queues' do
        expect(output_options[:pools]).to eq [[[], 4]]
      end
    end

    context 'worker count not specified' do
      let(:options) { ['--pool=mailers'] }
      it 'should default to one worker' do
        expect(output_options[:pools]).to eq [[['mailers'], 1]]
      end
    end

    context 'worker processes' do
      let(:options) { %w[--pool=*:1 --pool=test_queue:4 --pool=mailers,misc:2] }
      let(:exp) do
        [
          ['delayed_job.0', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => []}],
          ['delayed_job.1', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
          ['delayed_job.2', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
          ['delayed_job.3', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
          ['delayed_job.4', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => ['test_queue']}],
          ['delayed_job.5', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => %w[mailers misc]}],
          ['delayed_job.6', {:quiet => true, :pid_dir => './tmp/pids', :log_dir => './log', :queues => %w[mailers misc]}]
        ]
      end
      it { verify_worker_processes }
    end
  end

  describe '--daemon-options arg' do
    context 'not set' do
      let(:options) { [] }
      it { expect(output_options[:exit_on_complete]).to eq nil }
      it 'does not affect launch_strategy' do
        expect(subject.instance_variable_get(:'@launch_strategy')).to eq nil
      end
    end

    context 'set' do
      let(:options) { %w[--daemon-options a,b,c] }
      it { expect(subject.instance_variable_get(:'@daemon_options')).to eq %w[a b c] }
      it 'coerces launch_strategy to :daemon' do
        expect(subject.instance_variable_get(:'@launch_strategy')).to eq :daemon
      end
    end
  end

  describe 'extra args' do
    context '--daemon-options not set' do
      let(:options) { %w[foo bar baz] }
      it { expect(output_options[:args]).to eq %w[foo bar baz] }
    end

    context '--daemon-options set' do
      let(:options) { %w[foo bar --daemon-options a,b,c baz] }
      it { expect(output_options[:args]).to eq %w[foo bar baz a b c] }
    end
  end

  describe 'validations' do
    it 'should launch normally without validations' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:launch)
      expect(STDERR).to_not receive(:puts)
      Delayed::Command.new(%w[-d]).launch
    end

    it 'raise error processes and identifier are present' do
      expect { Delayed::Command.new(%w[-d --processes=2 --identifier=foobar]) }.to raise_error(ArgumentError, /--processes/)
    end

    it 'raise error processes and identifier are present (via -n)' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to_not receive(:launch)
      expect(STDERR).to_not receive(:puts)
      expect { Delayed::Command.new(%w[-d -n2 --identifier=foobar]).launch }.to raise_error(ArgumentError)
    end

    it 'warn if processes is 0' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:launch)
      expect(STDERR).to receive(:puts).with(/--processes must be 1 or greater/)
      Delayed::Command.new(%w[-d --processes=0]).launch
    end

    it 'not warn if min-priority is less than max-priority' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:launch)
      expect(STDERR).to_not receive(:puts)
      Delayed::Command.new(%w[-d --min-priority=-5 --max-priority=0]).launch
    end

    it 'not warn if min-priority equals max-priority' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:launch)
      expect(STDERR).to_not receive(:puts)
      Delayed::Command.new(%w[-d --min-priority=-5 --max-priority=-5]).launch
    end

    it 'warn if min-priority is greater than max-priority' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:launch)
      expect(STDERR).to receive(:puts)
      Delayed::Command.new(%w[-d --min-priority=-4 --max-priority=-5]).launch
    end

    it 'warn if both queues and pools are present' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:launch)
      expect(STDERR).to receive(:puts)
      Delayed::Command.new(%w[-d --queues=mailers --pool=mailers:2]).launch
    end

    it 'warn if both processes and pools are present' do
      expect_any_instance_of(Delayed::Launcher::Daemonized).to receive(:launch)
      expect(STDERR).to receive(:puts)
      Delayed::Command.new(%w[-d --processes=2 --pool=mailers:2]).launch
    end
  end
end
