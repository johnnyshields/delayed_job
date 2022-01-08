module Delayed
  def self.program_name
    File.basename($PROGRAM_NAME)
  end

  def self.root
    defined?(::Rails.root) ? ::Rails.root : Pathname.new(Dir.pwd)
  end

  def self.set_thread_name(name)
    return unless Thread.current.respond_to?(:name=)
    Thread.current.name = "delayed_job #{name}"
  end
end
