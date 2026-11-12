module Delayed
  # Log formatting shared by Delayed::Worker and Delayed::Dispatcher.
  # Includers must respond to #name and may set @quiet.
  module Logging
    def say(text, level = Delayed::Worker.default_log_level)
      text = "[Worker(#{name})] #{text}"
      puts text unless @quiet
      logger = Delayed::Worker.logger
      return unless logger
      # TODO: Deprecate use of Fixnum log levels
      unless level.is_a?(String)
        level = Logger::Severity.constants.detect { |i| Logger::Severity.const_get(i) == level }.to_s.downcase
      end
      logger.send(level, "#{Time.now.strftime('%FT%T%z')}: #{text}")
    end
  end
end
