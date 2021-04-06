module Delayed
  def self.program_name
    File.basename($PROGRAM_NAME)
  end

  def self.root
    defined?(::Rails.root) ? ::Rails.root : Pathname.new(Dir.pwd)
  end

  def object_space_usable?
    if defined?(::JRuby) && ::JRuby.respond_to?(:runtime)
      ::JRuby.runtime.is_object_space_enabled
    else
      defined?(::ObjectSpace)
    end
  end
end
