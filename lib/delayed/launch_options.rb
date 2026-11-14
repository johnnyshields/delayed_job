module Delayed
  # Parses and checks the options a worker launcher is started with, given
  # on the command line (Delayed::Command) or in environment variables
  # (rake jobs:work): one set of rules for both. Errors are ArgumentErrors
  # naming the option as it was given (see CLI_NAMES and ENV_NAMES).
  module LaunchOptions
    POSITIVE = [:integer, ->(n) { n >= 1 }, 'must be 1 or greater'].freeze
    WHOLE = [:integer, ->(_) { true }, 'must be a whole number'].freeze
    SECONDS = [:seconds, ->(s) { s >= 0 }, 'must be a number of seconds, 0 or greater'].freeze
    POSITIVE_SECONDS = [:seconds, ->(s) { s > 0 }, 'must be greater than 0'].freeze
    PREFETCH = [:integer, ->(n) { n.between?(0, Worker::MAX_PREFETCH) }, "must be a whole number from 0 to #{Worker::MAX_PREFETCH}"].freeze

    # option => [command-line name, environment variable, rule]; a rule is
    # [kind, valid?, what a valid value is], for options parsed as numbers.
    OPTIONS = {
      :processes => ['--processes', 'NUM_PROCESSES', POSITIVE],
      :threads => ['--threads', 'NUM_THREADS', POSITIVE],
      :read_ahead => ['--read-ahead', 'READ_AHEAD', POSITIVE],
      :prefetch => ['--prefetch', 'PREFETCH', PREFETCH],
      :min_priority => ['--min-priority', 'MIN_PRIORITY', WHOLE],
      :max_priority => ['--max-priority', 'MAX_PRIORITY', WHOLE],
      :sleep_delay => ['--sleep-delay', 'SLEEP_DELAY', SECONDS],
      :shutdown_timeout => ['--shutdown-timeout', 'SHUTDOWN_TIMEOUT', SECONDS],
      :lock_heartbeat_interval => ['--lock-heartbeat', 'LOCK_HEARTBEAT', POSITIVE_SECONDS],
      :lock_timeout => ['--lock-timeout', 'LOCK_TIMEOUT', POSITIVE_SECONDS],
      :identifier => ['--identifier', nil, nil], # No environment variable.
      :queues => ['--queues', 'QUEUES', nil],
      :pools => ['--pool', 'POOLS', nil]
    }.freeze

    CLI_NAMES = OPTIONS.transform_values(&:first).freeze
    ENV_NAMES = OPTIONS.transform_values { |(_, env)| env }.compact.freeze
    RULES = OPTIONS.transform_values(&:last).compact.freeze

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
