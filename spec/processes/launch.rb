# Runs a Delayed::Launcher::Forking on an SQLite file database.
# Usage: ruby -Ilib spec/processes/launch.rb DB_PATH OPTIONS_JSON
# OPTIONS_JSON holds the launcher options, plus "worker" settings applied to
# Delayed::Worker (e.g. {"sleep_delay": 0.1}). Logs go to STDOUT.
require 'bundler/setup'
require 'json'
require 'logger'
require_relative 'backend'
require_relative 'jobs'

db_path, json = ARGV
options = JSON.parse(json || '{}', :symbolize_names => true)
worker_settings = options.delete(:worker) || {}

Delayed::Backend::SqliteFile::Job.connect(db_path)
Delayed::Worker.backend = Delayed::Backend::SqliteFile::Job
STDOUT.sync = true
Delayed::Worker.logger = Logger.new(STDOUT).tap { |l| l.formatter = proc { |_s, _t, _p, m| "#{m}\n" } }
worker_settings.each { |setting, value| Delayed::Worker.send("#{setting}=", value) }

options[:pools] = options[:pools].map { |queues, count| [queues, count] } if options[:pools]
Delayed::Launcher::Forking.new(options.merge(:quiet => true)).launch
