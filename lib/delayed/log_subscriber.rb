require 'active_support/log_subscriber'

module Delayed
  # Logs `*.delayed_job` events (see Delayed::Instrumentation) to
  # Delayed::Worker.logger, with their durations. Not attached by default,
  # since workers already log their activity; attach it for the extra
  # detail (reservation round trips, per-event timings):
  #
  #   Delayed::LogSubscriber.attach_to :delayed_job
  #
  # reserve and perform events are logged at debug level.
  class LogSubscriber < ActiveSupport::LogSubscriber
    def logger
      Delayed::Worker.logger
    end

    def start_process(event)
      p = event.payload
      log(:info) { "Started #{p[:dispatcher]} (pid #{p[:pid]}, #{p[:threads]} thread(s), queues=#{queues(p[:queues])})" }
    end

    def stop_process(event)
      p = event.payload
      error_text = p[:error] ? " with #{p[:error].class}: #{p[:error].message}" : ''
      log(:info) { "Stopped #{p[:dispatcher]} (pid #{p[:pid]})#{error_text}" }
    end

    def reserve(event)
      p = event.payload
      log(:debug) { "#{p[:dispatcher]} reserved #{p[:reserved]} of #{p[:requested]} job(s)#{raised(event)} (#{ms(event)})" }
    end

    def perform(event)
      p = event.payload
      outcome = if p[:exception] then "was interrupted (#{p[:exception].first})"
      elsif p[:success] then 'succeeded'
      else 'failed'
      end
      log(:debug) { "#{job(p[:job])} #{outcome} on #{p[:worker]} (#{ms(event)})" }
    end

    def attempt_failed(event)
      p = event.payload
      log(:warn) { "#{job(p[:job])} failed attempt #{p[:attempts]} on #{p[:worker]} with #{p[:error].class}: #{p[:error].message}" }
    end

    def job_failed(event)
      p = event.payload
      log(:error) { "#{job(p[:job])} failed permanently on #{p[:worker]}" }
    end

    def lock_lost(event)
      p = event.payload
      log(:warn) { "#{job(p[:job])} was #{p[:outcome]} on #{p[:worker]} after its lock was taken over; result discarded" }
    end

    def thread_error(event)
      p = event.payload
      log(:error) { "#{p[:context]} error in #{p[:dispatcher] || p[:worker]}: #{p[:error].class}: #{p[:error].message}" }
    end

    def interrupt(event)
      p = event.payload
      log(:warn) { "#{p[:dispatcher]} interrupted #{p[:jobs]} running job(s) (#{p[:reason]})" }
    end

    def locks_released(event)
      p = event.payload
      log(:info) { "Released #{p[:count]} job(s) of #{Array(p[:workers]).join(', ')} (#{p[:reason]})" }
    end

    def fork_replaced(event)
      p = event.payload
      log(:info) { "Replaced worker process #{p[:worker]} (pid #{p[:pid]}, #{p[:status]}) with pid #{p[:new_pid]}" }
    end

    if respond_to?(:subscribe_log_level)
      subscribe_log_level :reserve, :debug
      subscribe_log_level :perform, :debug
    end

  private

    # Logs through the logger directly: ActiveSupport's level helpers
    # (info, error, ...) differ between its versions.
    def log(level, &block)
      logger.public_send(level, &block) if logger
    end

    # The exception raised in an instrumented block, if any.
    def raised(event)
      exception = event.payload[:exception]
      exception ? " - #{exception.first}: #{exception.last}" : ''
    end

    def job(job)
      return 'Job' unless job
      "Job #{job.name} (id=#{job.id})#{" (queue=#{job.queue})" if job.queue}"
    end

    def queues(queues)
      queues.nil? || queues.empty? ? '*' : queues.join(',')
    end

    def ms(event)
      format('%.1fms', event.duration)
    end
  end
end
