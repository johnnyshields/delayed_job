module Delayed
  # Parses and checks the options a worker launcher is started with, given
  # on the command line (Delayed::Command) or in environment variables
  # (rake jobs:work): one set of rules for both. Errors are ArgumentErrors
  # naming the option as it was given (see CLI_NAMES and ENV_NAMES).
  module LaunchOptions
    CLI_NAMES = {
      :processes => '--processes', :threads => '--threads', :read_ahead => '--read-ahead', :prefetch => '--prefetch',
      :min_priority => '--min-priority', :max_priority => '--max-priority', :sleep_delay => '--sleep-delay',
      :shutdown_timeout => '--shutdown-timeout', :lock_heartbeat_interval => '--lock-heartbeat',
      :lock_timeout => '--lock-timeout', :identifier => '--identifier', :queues => '--queues', :pools => '--pool'
    }.freeze

    ENV_NAMES = {
      :processes => 'NUM_PROCESSES', :threads => 'NUM_THREADS', :read_ahead => 'READ_AHEAD', :prefetch => 'PREFETCH',
      :min_priority => 'MIN_PRIORITY', :max_priority => 'MAX_PRIORITY', :sleep_delay => 'SLEEP_DELAY',
      :shutdown_timeout => 'SHUTDOWN_TIMEOUT', :lock_heartbeat_interval => 'LOCK_HEARTBEAT',
      :lock_timeout => 'LOCK_TIMEOUT', :queues => 'QUEUES', :pools => 'POOLS'
    }.freeze

    # option => [kind, valid?, what a valid value is]
    RULES = {
      :processes => [:integer, ->(n) { n >= 1 }, 'must be 1 or greater'],
      :threads => [:integer, ->(n) { n >= 1 }, 'must be 1 or greater'],
      :read_ahead => [:integer, ->(n) { n >= 1 }, 'must be 1 or greater'],
      :prefetch => [:integer, ->(n) { n.between?(0, Worker::MAX_PREFETCH) }, "must be a whole number from 0 to #{Worker::MAX_PREFETCH}"],
      :min_priority => [:integer, ->(_) { true }, 'must be a whole number'],
      :max_priority => [:integer, ->(_) { true }, 'must be a whole number'],
      :sleep_delay => [:seconds, ->(s) { s >= 0 }, 'must be a number of seconds, 0 or greater'],
      :shutdown_timeout => [:seconds, ->(s) { s >= 0 }, 'must be a number of seconds, 0 or greater'],
      :lock_heartbeat_interval => [:seconds, ->(s) { s > 0 }, 'must be greater than 0'],
      :lock_timeout => [:seconds, ->(s) { s > 0 }, 'must be greater than 0']
    }.freeze

    # Parses the text given for `option` (a key of RULES): a whole number,
    # or a number of seconds (see Delayed.parse_seconds). Raises an
    # ArgumentError, naming the option `name`, unless it is valid.
    def self.parse(option, text, name)
      kind, valid, requirement = RULES.fetch(option)
      value = kind == :integer ? Integer(text.to_s.strip, 10) : Delayed.parse_seconds(text)
      return value if valid.call(value)
      raise ArgumentError
    rescue ArgumentError, TypeError
      raise ArgumentError, "#{name} #{requirement}"
    end

    # Checks parsed options (see #parse) against each other, and those set
    # some other way against RULES. `names` maps options to how they were
    # given (CLI_NAMES or ENV_NAMES).
    def self.validate!(options, names)
      RULES.each do |option, (_, valid, requirement)|
        value = options[option]
        raise ArgumentError, "#{names.fetch(option)} #{requirement}" unless value.nil? || (value.is_a?(Numeric) && valid.call(value))
      end
      validate_lock_heartbeat!(options, names)
      validate_priorities!(options, names)
      validate_exclusive!(options, names)
    end

    # The lock timeout (from the options, else the Worker setting, e.g. from
    # an initializer) must outlast two heartbeats.
    def self.validate_lock_heartbeat!(options, names)
      interval = options[:lock_heartbeat_interval]
      return unless interval
      timeout = options[:lock_timeout] || Worker.lock_timeout || Worker::DEFAULT_LOCK_TIMEOUT
      return if timeout >= 2 * interval
      raise ArgumentError, "#{names[:lock_timeout]} must be at least twice #{names[:lock_heartbeat_interval]}"
    end
    private_class_method :validate_lock_heartbeat!

    def self.validate_priorities!(options, names)
      min = options[:min_priority]
      max = options[:max_priority]
      return unless min && max && min > max
      raise ArgumentError, "#{names[:min_priority]} must be less than or equal to #{names[:max_priority]}"
    end
    private_class_method :validate_priorities!

    # Options that can't be given together: [first, second, given?].
    EXCLUSIVE = [
      [:processes, :identifier, ->(o) { o[:processes].to_i > 1 && o[:identifier] }],
      [:identifier, :pools, ->(o) { o[:identifier] && o[:pools] }],
      [:processes, :pools, ->(o) { o[:processes].to_i > 1 && o[:pools] }],
      [:queues, :pools, ->(o) { o[:queues] && o[:pools] }]
    ].freeze

    def self.validate_exclusive!(options, names)
      first, second, = EXCLUSIVE.detect { |_, _, given| given.call(options) }
      raise ArgumentError, "Cannot specify both #{names[first]} and #{names[second]}" if first
    end
    private_class_method :validate_exclusive!
  end
end
