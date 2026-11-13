namespace :jobs do
  desc 'Clear the delayed_job queue.'
  task :clear => :environment do
    Delayed::Job.delete_all
  end

  desc 'Start a delayed_job worker.'
  task :work => :environment_options do
    Delayed::Launcher::Forking.new(@options).launch
  end

  desc 'Start a delayed_job worker and exit when all available jobs are complete.'
  task :workoff => :environment_options do
    Delayed::Launcher::Forking.new(@options.merge(:exit_on_complete => true)).launch
  end

  task :environment_options => :environment do
    # NUM_WORKERS is an alias of NUM_PROCESSES.
    num_processes = ENV['NUM_PROCESSES'] || ENV['NUM_WORKERS']

    @options = {
      :processes => num_processes ? Integer(num_processes) : 1,
      :quiet => !!ENV['QUIET'] && ENV['QUIET'] !~ /\A(?:0|f|false)\z/i
    }
    @options[:min_priority] = Integer(ENV['MIN_PRIORITY']) if ENV['MIN_PRIORITY']
    @options[:max_priority] = Integer(ENV['MAX_PRIORITY']) if ENV['MAX_PRIORITY']
    # Whole or fractional seconds.
    @options[:sleep_delay] = (Integer(ENV['SLEEP_DELAY'], 10) rescue Float(ENV['SLEEP_DELAY'])) if ENV['SLEEP_DELAY'] # rubocop:disable RescueModifier
    @options[:read_ahead] = Integer(ENV['READ_AHEAD']) if ENV['READ_AHEAD']
    @options[:threads] = Integer(ENV['NUM_THREADS']) if ENV['NUM_THREADS']
    @options[:shutdown_timeout] = Float(ENV['SHUTDOWN_TIMEOUT']) if ENV['SHUTDOWN_TIMEOUT']
    @options[:lock_heartbeat_interval] = Float(ENV['LOCK_HEARTBEAT']) if ENV['LOCK_HEARTBEAT']
    @options[:lock_timeout] = Float(ENV['LOCK_TIMEOUT']) if ENV['LOCK_TIMEOUT']
    @options[:silence_polling] = true if ENV['SILENCE_POLLING'] && ENV['SILENCE_POLLING'] !~ /\A(?:|0|f|false)\z/i
    @options[:count_shutdown_interrupts] = true if ENV['COUNT_SHUTDOWN_INTERRUPTS'] && ENV['COUNT_SHUTDOWN_INTERRUPTS'] !~ /\A(?:|0|f|false)\z/i
    @options[:shutdown_on_worker_kill] = true if ENV['SHUTDOWN_ON_WORKER_KILL'] && ENV['SHUTDOWN_ON_WORKER_KILL'] !~ /\A(?:|0|f|false)\z/i
    # PIDFILE=path, or PIDFILE=1 for tmp/pids/delayed_job.pid.
    if ENV['PIDFILE'] && ENV['PIDFILE'] !~ /\A(?:|0|f|false)\z/i
      @options[:pid_file] = ENV['PIDFILE'] =~ /\A(?:1|t|true)\z/i ? true : ENV['PIDFILE']
    end

    queues = (ENV['QUEUES'] || ENV['QUEUE'] || '').split(',')
    @options[:queues] = queues unless queues.empty?

    pools = Delayed::PoolParser.new.add(ENV['POOLS'] || ENV['POOL'] || '').pools
    @options[:pools] = pools unless pools.empty?

    if @options[:processes] < 1
      raise ArgumentError, 'NUM_PROCESSES must be 1 or greater'
    end

    if @options[:sleep_delay] && @options[:sleep_delay] < 0
      raise ArgumentError, 'SLEEP_DELAY must be 0 or greater'
    end

    if @options[:threads] && @options[:threads] < 1
      raise ArgumentError, 'NUM_THREADS must be 1 or greater'
    end

    if @options[:shutdown_timeout] && @options[:shutdown_timeout] < 0
      raise ArgumentError, 'SHUTDOWN_TIMEOUT must be 0 or greater'
    end

    if @options[:lock_heartbeat_interval]
      timeout = @options.fetch(:lock_timeout, Delayed::Worker::DEFAULT_LOCK_TIMEOUT)
      raise ArgumentError, 'LOCK_HEARTBEAT must be greater than 0' unless @options[:lock_heartbeat_interval] > 0
      raise ArgumentError, 'LOCK_TIMEOUT must be at least twice LOCK_HEARTBEAT' if timeout < 2 * @options[:lock_heartbeat_interval]
    end

    if @options[:min_priority] && @options[:max_priority] && @options[:min_priority] > @options[:max_priority]
      raise ArgumentError, 'MIN_PRIORITY must be less than or equal to MAX_PRIORITY'
    end

    if num_processes && @options[:pools]
      raise ArgumentError, 'Cannot specify both NUM_PROCESSES and POOLS'
    end

    if @options[:queues] && @options[:pools]
      raise ArgumentError, 'Cannot specify both QUEUES and POOLS'
    end
  end

  desc "Exit with error status if any jobs older than max_age seconds haven't been attempted yet."
  task :check, [:max_age] => :environment do |_, args|
    args.with_defaults(:max_age => 300)

    unprocessed_jobs = Delayed::Job.where('attempts = 0 AND created_at < ?', Time.now - args[:max_age].to_i).count

    if unprocessed_jobs > 0
      raise "#{unprocessed_jobs} jobs older than #{args[:max_age]} seconds have not been processed yet"
    end
  end
end
