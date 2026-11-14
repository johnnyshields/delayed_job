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
    names = Delayed::LaunchOptions::ENV_NAMES
    # The value of a numeric variable, if set (see Delayed::LaunchOptions).
    number = lambda do |option, variable = names.fetch(option)|
      Delayed::LaunchOptions.parse(option, ENV[variable], variable) if ENV[variable]
    end
    # Whether a boolean variable is set to anything but blank, 0, f(alse), n(o) or off.
    flag = ->(variable) { !!ENV[variable] && ENV[variable] !~ /\A(?:|0|f|false|n|no|off)\z/i }

    @options = {
      # NUM_WORKERS is an alias of NUM_PROCESSES.
      :processes => number.call(:processes) || number.call(:processes, 'NUM_WORKERS') || 1,
      :quiet => flag.call('QUIET')
    }
    {
      :min_priority => number.call(:min_priority), :max_priority => number.call(:max_priority),
      :sleep_delay => number.call(:sleep_delay), :read_ahead => number.call(:read_ahead),
      :threads => number.call(:threads), :prefetch => number.call(:prefetch),
      :shutdown_timeout => number.call(:shutdown_timeout),
      :lock_heartbeat_interval => number.call(:lock_heartbeat_interval), :lock_timeout => number.call(:lock_timeout)
    }.each { |option, value| @options[option] = value unless value.nil? }
    @options[:prefetch_dynamic] = true if flag.call('PREFETCH_DYNAMIC')
    @options[:silence_polling] = true if flag.call('SILENCE_POLLING')
    @options[:count_shutdown_interrupts] = true if flag.call('COUNT_SHUTDOWN_INTERRUPTS')
    # PIDFILE=path, or PIDFILE=1 (true, yes, on) for tmp/pids/delayed_job.pid.
    if flag.call('PIDFILE')
      @options[:pid_file] = ENV['PIDFILE'] =~ /\A(?:1|t|true|y|yes|on)\z/i ? true : ENV['PIDFILE']
    end

    queues = (ENV['QUEUES'] || ENV['QUEUE'] || '').split(',')
    @options[:queues] = queues unless queues.empty?

    pools = Delayed::PoolParser.new.add(ENV['POOLS'] || ENV['POOL'] || '').pools
    @options[:pools] = pools unless pools.empty?

    # The same rules as script/delayed_job (see Delayed::LaunchOptions).
    Delayed::LaunchOptions.validate!(@options, names)
  end

  desc "Exit with error status if any jobs older than max_age seconds haven't been attempted yet."
  task :check, [:max_age] => :environment do |_, args|
    args.with_defaults(:max_age => 300)

    unprocessed_jobs = Delayed::Job.where('attempts = 0 AND created_at < ?', Time.now - args[:max_age].to_i).count

    raise "#{unprocessed_jobs} jobs older than #{args[:max_age]} seconds have not been processed yet" if unprocessed_jobs > 0
  end
end
