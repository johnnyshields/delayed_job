require 'active_support/notifications'

module Delayed
  # Publishes `<event>.delayed_job` events with ActiveSupport::Notifications.
  # See README ("Instrumentation") for the events and their payloads.
  #
  # Subscribers are user code that runs on worker threads: an exception
  # raised by one is logged and otherwise ignored, so it can't fail a job,
  # skip a job, or crash a worker. Exceptions raised by the instrumented
  # block itself propagate as usual (and are in the payload's :exception).
  module Instrumentation
    NAMESPACE = 'delayed_job'.freeze

    module_function

    def instrument(event, payload = {})
      name = "#{event}.#{NAMESPACE}"
      return notify(name, payload) unless block_given?

      started = false
      finished = false
      result = nil
      begin
        ActiveSupport::Notifications.instrument(name, payload) do |p|
          started = true
          result = yield(p)
          finished = true
          result
        end
      rescue Exception => error # rubocop:disable RescueException
        # Raised by the block; or not a subscriber's bug (a signal, a
        # Delayed::ShutdownInterrupt raised into this thread).
        raise if (started && !finished) || !error.is_a?(StandardError)
        subscriber_failed(name, error)
        result = yield(payload) unless started # A subscriber failed before the block ran.
      end
      result
    end

    def notify(name, payload)
      ActiveSupport::Notifications.instrument(name, payload)
    rescue StandardError => error
      subscriber_failed(name, error)
    end

    def subscriber_failed(name, error)
      logger = Delayed::Worker.logger
      logger.error("Error in a subscriber to #{name}: #{error.class}: #{error.message}") if logger
      nil
    end
  end

  def self.instrument(event, payload = {}, &block)
    Instrumentation.instrument(event, payload, &block)
  end
end
