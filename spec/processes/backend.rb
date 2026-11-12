# A minimal Active Record backend on an SQLite file, so that several real
# processes (a forking launcher and its children) share one job table.
# Used by the process-level specs, in the spec process and in subprocesses.
require 'active_record'
require 'delayed_job'

module Delayed
  module Backend
    module SqliteFile
      class Job < ActiveRecord::Base
        include Delayed::Backend::Base
        self.table_name = 'delayed_jobs'

        before_save :set_default_run_at

        def self.connect(path)
          establish_connection(:adapter => 'sqlite3', :database => path, :pool => 20, :timeout => 10_000)
          Run.establish_connection(:adapter => 'sqlite3', :database => path, :pool => 20, :timeout => 10_000)
        end

        def self.create_schema
          connection.create_table :delayed_jobs, :force => true do |t|
            t.integer :priority, :default => 0, :null => false
            t.integer :attempts, :default => 0, :null => false
            t.text :handler, :null => false
            t.text :last_error
            t.datetime :run_at, :locked_at, :failed_at
            t.string :locked_by, :queue
            t.timestamps :null => true
          end
          connection.create_table :runs, :force => true do |t|
            t.string :key
            t.integer :pid
            t.string :worker
            t.float :started, :finished
          end
        end

        def self.db_time_now
          Time.now.utc
        end

        def self.before_fork
          connection_handler.clear_all_connections!(:all)
        rescue ArgumentError
          connection_handler.clear_all_connections!
        end

        def self.after_fork
          connection_handler.clear_all_connections!(:all)
        rescue ArgumentError
          connection_handler.clear_all_connections!
        end

        def self.locked_jobs(name)
          where(:locked_by => name).to_a
        end

        def self.clear_locks!(name)
          where(:locked_by => name).update_all(:locked_by => nil, :locked_at => nil)
        end

        def self.find_available(name, limit, max_run_time)
          now = db_time_now
          scope = where('run_at <= ? AND failed_at IS NULL AND (locked_at IS NULL OR locked_at < ? OR locked_by = ?)', now, now - max_run_time, name)
          scope = scope.where('priority >= ?', Worker.min_priority) if Worker.min_priority
          scope = scope.where('priority <= ?', Worker.max_priority) if Worker.max_priority
          scope = scope.where(:queue => Worker.queues) if Worker.queues.any?
          scope.order(:priority, :run_at, :id).limit(limit).to_a
        end

        def lock_exclusively!(max_run_time, name)
          now = self.class.db_time_now
          locked = self.class.where('id = ? AND (locked_at IS NULL OR locked_at < ? OR locked_by = ?)', id, now - max_run_time, name)
                       .update_all(:locked_at => now, :locked_by => name)
          return false unless locked == 1
          self.locked_at = now
          self.locked_by = name
          clear_changes_information
          true
        end

        def reload(*)
          reset
          super
        end
      end

      # One row per job run, written by the jobs in jobs.rb.
      class Run < ActiveRecord::Base
        self.table_name = 'runs'
      end
    end
  end
end
