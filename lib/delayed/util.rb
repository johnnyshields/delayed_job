module Delayed
  def self.program_name
    File.basename($PROGRAM_NAME)
  end

  # Parses a number of seconds given as text (a command-line option or an
  # environment variable): decimal digits, optionally negative and with a
  # fraction, e.g. "5", "0.5", "010" (ten). Returns an Integer for whole
  # numbers, else a Float. Raises ArgumentError for anything else, such as
  # "0x10", "1_0", "1e2" or "soon", which Float() would accept or misread.
  def self.parse_seconds(value)
    text = value.to_s.strip
    raise ArgumentError, "invalid number of seconds: #{value.inspect}" unless text =~ /\A-?\d+(\.\d+)?\z/
    Regexp.last_match(1) ? Float(text) : Integer(text, 10)
  end

  # Raises ArgumentError (as Signal.trap does for a reserved signal) if
  # `signal` can't be trapped here: QUIT on the JVM (JRuby), which reserves
  # it for thread dumps - trapping it there only prints a warning.
  def self.check_trappable!(signal)
    raise ArgumentError, "can't trap reserved signal: SIG#{signal}" if signal == 'QUIT' && RUBY_ENGINE == 'jruby'
  end

  def self.root
    defined?(::Rails.root) ? ::Rails.root : Pathname.new(Dir.pwd)
  end
end
