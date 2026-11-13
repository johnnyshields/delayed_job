require 'optparse'

module Delayed
  class Command # rubocop:disable Metrics/ClassLength
    def initialize(args)
      @options = {
        :quiet => true,
        :processes => 1,
        :monitor => false
      }

      @options[:args] = option_parser.parse!(args) + (@daemon_options || [])

      pools = pool_parser.pools
      @options[:pools] = pools unless pools.empty?

      validate_options!
    end

    def launch
      launcher.launch
    end

    def daemonize
      @launch_strategy ||= :daemon
      launch
    end

  private

    def launcher
      @launcher ||= launcher_class.new(@options)
    end

    def launcher_class
      case @launch_strategy
      when :daemon
        Delayed::Launcher::Daemonized
      else
        Delayed::Launcher::Forking
      end
    end

    def option_parser # rubocop:disable Metrics/MethodLength, Metrics/CyclomaticComplexity
      @option_parser ||= OptionParser.new do |opt|
        opt.banner = "Usage: #{Delayed.program_name} [options] start|stop|restart|run"
        opt.on('-h', '--help', 'Show this message') do
          puts opt
          exit 1
        end
        opt.on('-e', '--environment=NAME', 'Specifies the environment to run this delayed jobs under (test/development/production).') do |_e|
          STDERR.puts 'The -e/--environment option has been deprecated and has no effect. Use RAILS_ENV and see http://github.com/collectiveidea/delayed_job/issues/7'
        end
        opt.on('-d', '--daemonize', 'Launch in daemon mode') do |_fork|
          @launch_strategy ||= :daemon
        end
        opt.on('--daemon-options a, b, c', Array, 'options to be passed through to daemons gem') do |daemon_options|
          @launch_strategy ||= :daemon
          @daemon_options = daemon_options
        end
        opt.on('--fork', 'Launch in forking mode') do |_fork|
          @launch_strategy ||= :fork
        end
        opt.on('--min-priority N', 'Minimum priority of jobs to run.') do |n|
          @options[:min_priority] = Integer(n) rescue nil
        end
        opt.on('--max-priority N', 'Maximum priority of jobs to run.') do |n|
          @options[:max_priority] = Integer(n) rescue nil
        end
        opt.on('-n', '--processes=N', 'Number of worker processes to spawn') do |n|
          @options[:processes] = Integer(n) rescue 1
        end
        opt.on('--num-workers=N', 'DEPRECATED: Use --processes') do |n|
          STDERR.puts 'DEPRECATED: Use -n or --processes instead of --num-workers. This will be removed in the next major version.'
          @options[:processes] = Integer(n) rescue 1
        end
        opt.on('-t', '--threads=N', 'Number of threads per worker process') do |n|
          @options[:threads] = Integer(n) rescue 0
        end
        opt.on('--number_of_workers=N', 'DEPRECATED: Use --processes') do |n|
          STDERR.puts 'DEPRECATED: Use -n or --processes instead of --number_of_workers. This will be removed in the next major version.'
          @options[:processes] = Integer(n) rescue 1
        end
        opt.on('--pid-dir=DIR', 'Specifies an alternate directory in which to store the process ids.') do |dir|
          @options[:pid_dir] = dir
        end
        opt.on('--pid-file[=PATH]', 'With --fork, write the parent process id to PATH (default: <pid-dir>/delayed_job.pid) and refuse to start if that process is running') do |path|
          @options[:pid_file] = path || true
        end
        opt.on('--log-dir=DIR', 'Specifies an alternate directory in which to store the delayed_job log.') do |dir|
          @options[:log_dir] = dir
        end
        opt.on('-v', '--verbose', 'Output additional logging') do
          @options[:quiet] = false
        end
        opt.on('-i', '--identifier=n', 'A numeric identifier for the worker.') do |n|
          @options[:identifier] = n
        end
        opt.on('-m', '--monitor', 'Start monitor process.') do
          @options[:monitor] = true
        end
        opt.on('--shutdown-timeout N', 'Seconds to let running jobs finish when stopping before interrupting and releasing them (default: wait for them)') do |n|
          @options[:shutdown_timeout] = seconds(n)
        end
        opt.on('--lock-heartbeat N', 'Refresh the locks of running jobs every N seconds, so a dead or hung worker\'s jobs are picked up after --lock-timeout (default: off)') do |n|
          @options[:lock_heartbeat_interval] = seconds(n, 0)
        end
        opt.on('--lock-timeout N', 'With --lock-heartbeat, seconds after which a lock that was not refreshed counts as abandoned (default: 300)') do |n|
          @options[:lock_timeout] = seconds(n, 0)
        end
        opt.on('--count-shutdown-interrupts', 'Count a job interrupted by shutdown as a failed attempt (default: release it, attempts unchanged)') do
          @options[:count_shutdown_interrupts] = true
        end
        opt.on('--silence-polling', "Don't log the database queries of polling for jobs and refreshing their locks") do
          @options[:silence_polling] = true
        end
        opt.on('--sleep-delay N', 'Seconds to sleep when no jobs are found (default: 1)') do |n|
          @options[:sleep_delay] = seconds(n)
        end
        opt.on('--prefetch N', 'Jobs each thread may hold queued behind the one it runs, to start the next one without waiting for a poll (default: 0)') do |n|
          @options[:prefetch] = Integer(n) rescue -1
        end
        opt.on('--prefetch-dynamic', 'Scale the prefetch queue depth with demand: from 0, one level deeper after each poll that gets every job it asks for, back to 0 after one that gets fewer') do
          @options[:prefetch_dynamic] = true
        end
        opt.on('--read-ahead N', 'Number of jobs from the queue to consider') do |n|
          @options[:read_ahead] = Integer(n) rescue nil
        end
        opt.on('-p', '--prefix NAME', 'String to be prefixed to worker process names') do |prefix|
          @options[:prefix] = prefix
        end
        opt.on('--queues=queue1[,queue2]', 'Specify the job queues to work. Comma separated.') do |queues|
          @options[:queues] = queues.split(',')
        end
        opt.on('--queue=queue1[,queue2]', 'Specify the job queues to work. Comma separated.') do |queue|
          @options[:queues] = queue.split(',')
        end
        opt.on('--pools=queue1[,queue2][:processes][|...]', 'Specify queues and number of processes for a worker pool. Use pipe to delimit multiple pools.') do |pools|
          pool_parser.add(pools)
        end
        opt.on('--pool=queue1[,queue2][:processes]', 'Specify queues and number of processes for a worker pool') do |pool|
          pool_parser.add(pool)
        end
        opt.on('-x', '--exit-on-complete', 'Exit when no more jobs are available to run. This will exit if all jobs are scheduled to run in the future.') do
          @options[:exit_on_complete] = true
        end
      end
    end

    def pool_parser
      @pool_parser ||= PoolParser.new
    end

    # Parses a number of seconds (see Delayed.parse_seconds), or returns
    # `invalid` - a value the option's validation rejects with its message.
    def seconds(value, invalid = -1)
      Delayed.parse_seconds(value)
    rescue ArgumentError
      invalid
    end

    def validate_options!
      validate_process_count!
      validate_sleep_delay!
      validate_thread_count!
      validate_prefetch!
      validate_shutdown_timeout!
      validate_lock_heartbeat!
      validate_priority!
      validate_identifier!
      validate_processes_and_pools!
      validate_queues_and_pools!
    end

    def validate_process_count!
      return unless @options[:processes] < 1
      STDERR.puts 'WARNING: --processes must be 1 or greater. This will raise an ArgumentError in the next major version.'
    end

    def validate_sleep_delay!
      return unless @options.key?(:sleep_delay) && @options[:sleep_delay] < 0
      raise ArgumentError, '--sleep-delay must be a number of seconds, 0 or greater'
    end

    def validate_thread_count!
      return unless @options[:threads] && @options[:threads] < 1
      raise ArgumentError, '--threads must be 1 or greater'
    end

    def validate_prefetch!
      return unless @options[:prefetch] && @options[:prefetch] < 0
      raise ArgumentError, '--prefetch must be 0 or greater'
    end

    def validate_shutdown_timeout!
      return unless @options.key?(:shutdown_timeout) && @options[:shutdown_timeout] < 0
      raise ArgumentError, '--shutdown-timeout must be a number of seconds, 0 or greater'
    end

    def validate_lock_heartbeat!
      interval = @options[:lock_heartbeat_interval]
      timeout = @options.fetch(:lock_timeout, Delayed::Worker::DEFAULT_LOCK_TIMEOUT)
      raise ArgumentError, '--lock-timeout must be greater than 0' if @options.key?(:lock_timeout) && timeout <= 0
      return unless @options.key?(:lock_heartbeat_interval)
      raise ArgumentError, '--lock-heartbeat must be greater than 0' unless interval > 0
      return if timeout >= 2 * interval
      raise ArgumentError, '--lock-timeout must be at least twice --lock-heartbeat'
    end

    def validate_priority!
      return unless @options[:min_priority] && @options[:max_priority] && @options[:min_priority] > @options[:max_priority]
      STDERR.puts 'WARNING: --min-priority must be less than or equal to --max-priority. This will raise an ArgumentError in the next major version.'
    end

    def validate_identifier!
      return unless @options[:identifier] && @options[:processes] > 1
      raise ArgumentError, 'Cannot specify both --processes and --identifier'
    end

    def validate_processes_and_pools!
      return unless @options[:processes] > 1 && @options[:pools]
      STDERR.puts 'WARNING: Cannot specify both --processes and --pool. This will raise an ArgumentError in the next major version.'
    end

    def validate_queues_and_pools!
      return unless @options[:queues] && @options[:pools]
      STDERR.puts 'WARNING: Cannot specify both --queues and --pool. This will raise an ArgumentError in the next major version.'
    end
  end
end
