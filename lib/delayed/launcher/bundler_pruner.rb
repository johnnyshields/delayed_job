
module Delayed
  module Launcher
    module BundlerPruner
      include Loggable

      def prune_bundler
        return if ENV['DELAYED_JOB_BUNDLER_PRUNED']
        return unless defined?(Bundler)
        require_rubygems_min_version!

        unless delayed_job_restart_location
          logger.info '! Unable to prune Bundler environment, continuing'
          return
        end

        dirs = files_to_require_after_prune

        logger.info '* Pruning Bundler environment'
        home = ENV['GEM_HOME']
        bundle_gemfile = Bundler.original_env['BUNDLE_GEMFILE']
        bundle_app_config = Bundler.original_env['BUNDLE_APP_CONFIG']

        with_unbundled_env do
          ENV['GEM_HOME'] = home
          ENV['BUNDLE_GEMFILE'] = bundle_gemfile
          ENV['DELAYED_JOB_BUNDLER_PRUNED'] = '1'
          ENV['BUNDLE_APP_CONFIG'] = bundle_app_config
          args = [Gem.ruby, delayed_job_restart_location, '-I', dirs.join(':')] + @original_argv
          Kernel.exec(*args)
        end
      end

      private

      def delayed_job_restart_location
        dirs = require_paths_for_gem(spec_for_delayed_job)
        lib_dir = dirs.detect { |x| File.exist? File.join(x, '../bin/delayed_job_restart') }
        File.expand_path(File.join(lib_dir, '../bin/delayed_job_restart'))
      end

      def files_to_require_after_prune
        require_paths_for_gem(spec_for_delayed_job) + extra_runtime_deps_directories
      end

      def extra_runtime_deps_directories
        Array(@options[:extra_runtime_dependencies]).map do |d_name|
          if (spec = spec_for_gem(d_name))
            require_paths_for_gem(spec)
          else
            log "* Could not load extra dependency: #{d_name}"
            nil
          end
        end.flatten.compact
      end

      def spec_for_delayed_job
        spec_for_gem('delayed_job')
      end

      def spec_for_gem(gem_name)
        Bundler.rubygems.loaded_specs(gem_name)
      end

      def require_paths_for_gem(gem_spec)
        gem_spec.full_require_paths
      end

      def require_rubygems_min_version!
        min_version = Gem::Version.new('2.2')
        return if min_version <= Gem::Version.new(Gem::VERSION)
        raise "prune_bundler is not supported on your version of RubyGems. You must have RubyGems #{min_version}+ to use this feature."
      end

      def with_unbundled_env
        bundler_ver = Gem::Version.new(Bundler::VERSION)
        if bundler_ver < Gem::Version.new('2.1.0')
          Bundler.with_clean_env { yield }
        else
          Bundler.with_unbundled_env { yield }
        end
      end
    end
  end
end
