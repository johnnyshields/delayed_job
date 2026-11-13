**If you're viewing this at https://github.com/collectiveidea/delayed_job,
you're reading the documentation for the master branch.
[View documentation for the latest release
(4.1.10).](https://github.com/collectiveidea/delayed_job/tree/v4.1.10)**

# Delayed Job

[![Gem Version](https://badge.fury.io/rb/delayed_job.svg)][gem]
![CI](https://github.com/collectiveidea/delayed_job/workflows/CI/badge.svg)
[![Code Climate](https://codeclimate.com/github/collectiveidea/delayed_job.svg)][codeclimate]
[![Coverage Status](https://coveralls.io/repos/collectiveidea/delayed_job/badge.svg?branch=master)][coveralls]

[gem]: https://rubygems.org/gems/delayed_job
[codeclimate]: https://codeclimate.com/github/collectiveidea/delayed_job
[coveralls]: https://coveralls.io/r/collectiveidea/delayed_job

Delayed Job encapsulates the common pattern of asynchronously executing
longer tasks in the background. Examples of such tasks include:

* Sending emails
* Image resizing
* HTTP downloads
* Updating smart collections
* Updating Solr, our search server, after product changes
* Batch imports
* Spam checks

Delayed Job was extracted from Shopify.

## Installation

### Version Support

Delayed Job 4.x only supports Rails 3.0+.

### Configuring your Database

Delayed Job supports multiple backends for storing the job queue. [See the wiki
for other backends](https://github.com/collectiveidea/delayed_job/wiki/Backends).

To use with Active Record, add `delayed_job_active_record` to your `Gemfile`.

```ruby
gem 'delayed_job_active_record'
```

To use with Mongoid, add `delayed_job_mongoid` to your `Gemfile`.

```ruby
gem 'delayed_job_mongoid'
```

Run `bundle install` to install the backend and `delayed_job` gems.

The Active Record backend requires a jobs table. You can create that table by
running the following command:

```
rails generate delayed_job:active_record
rake db:migrate
```

### Active Job

To use Delayed Job with Active Job (Rails 4.2+), set the `queue_adapter` in `config/application.rb`:

```ruby
config.active_job.queue_adapter = :delayed_job
```

See the [Rails Guide](http://guides.rubyonrails.org/active_job_basics.html#setting-the-backend) for more details.

### Protected Attributes

When using the `protected_attributes` gem, it must appear before `delayed_job` in your `Gemfile`. Otherwise you will see this error:

```
ActiveRecord::StatementInvalid: PG::NotNullViolation: ERROR:  null value in column "handler" violates not-null constraint
```

## Using Delayed Job in your Application

### Queuing Jobs

Call `.delay.method(params)` on any object and it will be processed in the background.

```ruby
# without delayed_job
@user.activate!(@device)

# with delayed_job
@user.delay.activate!(@device)
```

If a method should always be run in the background, you can call
`#handle_asynchronously` after the method declaration:

```ruby
class Device
  def deliver
    # long running method
  end
  handle_asynchronously :deliver
end

device = Device.new
device.deliver
```

### Parameters

`#handle_asynchronously` and `#delay` take these parameters:

- `:priority` (number): lower numbers run first; default is 0 but can be reconfigured (see below)
- `:run_at` (Time): run the job after this time (probably in the future)
- `:queue` (string): named queue to put this job in, an alternative to priorities (see below)

These params can be Proc objects, allowing call-time evaluation of the value.

For example:

```ruby
class LongTasks
  def send_mailer
    # Some other code
  end
  handle_asynchronously :send_mailer, :priority => 20

  def in_the_future
    # Some other code
  end
  # 5.minutes.from_now will be evaluated when in_the_future is called
  handle_asynchronously :in_the_future, :run_at => Proc.new { 5.minutes.from_now }

  def self.when_to_run
    2.hours.from_now
  end

  class << self
    def call_a_class_method
      # Some other code
    end
    handle_asynchronously :call_a_class_method, :run_at => Proc.new { when_to_run }
  end

  attr_reader :how_important

  def call_an_instance_method
    # Some other code
  end
  handle_asynchronously :call_an_instance_method, :priority => Proc.new {|i| i.how_important }
end
```

To call a `handle_asynchronously`'d method without Delayed Job, add `_without_delay` to the method name.
For instance, if your original method was `foo`, then call `foo_without_delay`.

### Rails Mailers

Delayed Job uses special syntax for Rails Mailers.
Do not call the `.deliver` method when using `.delay`.

```ruby
# without delayed_job
Notifier.signup(@user).deliver

# with delayed_job
Notifier.delay.signup(@user)

# delayed_job running at a specific time
Notifier.delay(run_at: 5.minutes.from_now).signup(@user)

# when using parameters, the .with method must be called before the .delay method
Notifier.with(foo: 1, bar: 2).delay.signup(@user)
```

You may also wish to consider using
[Active Job with Action Mailer](https://edgeguides.rubyonrails.org/active_job_basics.html#action-mailer)
which provides convenient `.deliver_later` syntax that forwards to Delayed Job under-the-hood.

### Queues

Delayed Job supports assigning jobs to named queues. Each queue may be worked by a
separate pool of workers, which may then be scaled and controlled individually.

Jobs can be assigned to a queue by setting the `:queue` option:

```ruby
object.delay(queue: 'tracking').method

Delayed::Job.enqueue job, queue: 'tracking'

handle_asynchronously :tweet_later, queue: 'tweets'
```

You may configure a default priority for each queue (lower number = higher priority):

```ruby
Delayed::Worker.queue_attributes = {
  high_priority_queue: { priority: -10 },
  low_priority_queue: { priority: 10 }
}
```

To override the queue's default priority, pass `:priority` to the delay method:

```ruby
object.delay(queue: 'high_priority_queue', priority: 0).method
```

You can start processes to only work certain queues with the `queue` and `queues`
options (refer to "Running Jobs" section below.) Processes started without specifying
a queue will run jobs from **any** queue. To effectively have a process that runs
jobs where a queue is not specified, set a default queue name with
`Delayed::Worker.default_queue_name` and have the processes run that queue.

## Running Jobs

### Running as a Daemon Process

`script/delayed_job` starts a background daemon process which will continually work jobs.

To install this script, add `gem "daemons"` to your `Gemfile` then run `rails generate delayed_job`.

Then run the `start` command:

```
# Run a single worker as a background process
RAILS_ENV=production script/delayed_job start

# Run 4 worker processes (-n is short for --processes)
RAILS_ENV=production script/delayed_job -n4 start
RAILS_ENV=production script/delayed_job --processes=4 start
```

Each worker will check the database at least every 5 seconds.

### Stopping and Restarting

You may use `stop` and `restart` commands. These commands wait for each worker
to finish its current job before proceeding. 

```
# Shutdown all workers and exit
RAILS_ENV=production script/delayed_job stop

# Shutdown all workers and start a single new worker process
RAILS_ENV=production script/delayed_job restart

# Shutdown all workers and start 4 new worker processes
RAILS_ENV=production script/delayed_job -n4 restart
```

You must pass the same arguments to `restart` that you used when calling `start`.

You may also send `SIGTERM` to stop Delayed Job.

### Worker Queues and Pools

```
# Set the --queues option to work from a particular queue
RAILS_ENV=production script/delayed_job --queues=mailers,tasks start

# Use the --pool option (queues:processes) to specify a worker pool. You can use
# this option multiple times to start different numbers of processes for different queues.
# The following command will start 1 process for the tracking queue,
# 2 processes for the mailers and tasks queues, and 2 processes for any jobs:
RAILS_ENV=production script/delayed_job --pool=tracking --pool=mailers,tasks:2 --pool=*:2 start
```

### Multi-Threaded Workers

Each worker process can run several jobs at once on separate threads, which
uses much less memory than running more processes and works well for IO-bound
jobs (HTTP calls, mailers, etc.). Use `-t`/`--threads` to set the number of
threads per process; total concurrency is processes × threads.

```
# 2 worker processes, each running 5 jobs concurrently (10 jobs at a time)
RAILS_ENV=production script/delayed_job --fork --processes=2 --threads=5 start

# --threads applies to every process, including pool processes:
# 3 processes (1 for mailers, 2 for any jobs), each with 4 threads
RAILS_ENV=production script/delayed_job --fork --pool=mailers:1 --pool=*:2 --threads=4 start
```

Every worker process, single- or multi-threaded, runs one `Delayed::Dispatcher`.
It reserves only as many jobs as there are idle threads and hands one to each,
so polling the database does not grow with the number of threads, and a job is
never locked while it waits for a thread. Each thread runs a `Delayed::Worker`
that locks jobs under its own name (e.g. `... pid:123 thread:2`).

Plugin callbacks: `:loop` wraps each poll and yields the `Delayed::Dispatcher`;
`:execute` wraps each worker thread's lifetime and yields its `Delayed::Worker`;
`:perform`, `:error` and `:failure` yield the `Delayed::Worker` running the job.

When using threads:

* Your job code (and any plugins) must be thread-safe.
* The database connection pool must hold at least one connection per thread
  plus one (`pool` in `config/database.yml`). A warning is logged if it is too small.
* All threads of a process work the same queues, and every process runs the
  same number of threads.
* Under Rails, each job runs inside the Rails reloader, so code reloading in
  development stays safe.
* On `SIGTERM`/`SIGINT`, running jobs finish before the process exits, as with
  single-threaded workers.

Backend authors may override `Delayed::Job.reserve_batch(workers, max_run_time)`
to reserve jobs for several threads in one query; each returned job must be
locked under the name of the worker it is paired with.

### Exit On Complete Mode

```
# Run as a daemon and exit after working all available jobs
RAILS_ENV=production script/delayed_job start --exit-on-complete

# or to run in the foreground
RAILS_ENV=production script/delayed_job run --exit-on-complete
```

### Experimental: Forking Mode

The `script/delayed_job` process (described above) uses the
[Daemons](https://github.com/thuehlinger/daemons) gem which has several
undesirable behaviors when running inside a container (Docker, etc.):

* The parent process spawns a background child process then exits immediately,
which causes the container to shutdown.
* The worker processes are detached from the parent, which prevents logging to `STDOUT`.

The `--fork` option solves this by running workers in a foreground process tree.
When using `--fork` the `daemons` gem is not required.

```
# Run as a foreground process with 4 worker child processes.
RAILS_ENV=production script/delayed_job --fork -n4 start

# Forking mode supports queues and pools.
RAILS_ENV=production script/delayed_job --fork --pool=mailers,tasks:2 --pool=*:2 start
```

Forking mode does not yet support the `restart`, `stop`, etc. script commands.
Use `SIGTERM` or `SIGINT` to allow workers to finish their current job then gracefully shutdown.
The parent forwards these signals to its worker processes, so sending them to the
parent alone (as `docker stop`, Kubernetes and systemd do) stops every worker.

#### Process titles

Each worker process keeps its title (as shown by `ps` and `top`) up to date
with its busy threads and queues, and whether it is stopping:

```
delayed_job.0: 3/4 busy, queues=mailers
delayed_job.1: stopping, 1/4 busy, queues=*
```

#### Pidfile

With `--pid-file`, the parent process writes its pid to a file and refuses to
start while another launcher holds that file, e.g. to stop a second
`rake jobs:work` (a deploy script run twice, a cron job) from doubling your workers:

```
# tmp/pids/delayed_job.pid (or delayed_job.<identifier>.pid; see --pid-dir)
RAILS_ENV=production script/delayed_job --fork -n4 --pid-file start
RAILS_ENV=production script/delayed_job --fork -n4 --pid-file=/var/run/delayed_job.pid start
PIDFILE=1 rake jobs:work
PIDFILE=/var/run/delayed_job.pid rake jobs:work
```

A second launcher exits with `Delayed::AlreadyRunningError` before starting any
worker. The parent deletes the file when it exits. Whether a launcher runs is
decided by a lock on the file, not by the pid in it: a file left behind by a
SIGKILLed launcher, or holding a pid since reused by another process, doesn't
block a start. Worker processes inherit the lock, so workers orphaned by a
SIGKILLed parent keep a new launcher from starting until they finish their jobs
and exit. Daemon mode writes its own pidfiles in `--pid-dir` and doesn't take
`--pid-file`.

#### Shutdown timeout and SIGQUIT

By default a stopping worker waits for its running jobs, however long they take.
Set a shutdown timeout to bound that, e.g. below your orchestrator's grace period
(Kubernetes' `terminationGracePeriodSeconds`, 30 seconds by default):

```
RAILS_ENV=production script/delayed_job --fork -n2 --shutdown-timeout=20 start
SHUTDOWN_TIMEOUT=20 rake jobs:work
# or in an initializer
Delayed::Worker.shutdown_timeout = 20
```

Jobs still running when it expires are interrupted with `Delayed::ShutdownInterrupt`
and released: unlocked, with their attempts and `run_at` unchanged, for another
worker to run right away. `SIGQUIT` does the same immediately. The forking parent
SIGKILLs any worker process still running 10 seconds after that.

`Delayed::ShutdownInterrupt` is not a `StandardError`, so `rescue => e` in a job
doesn't catch it. A released job runs again from the start, so jobs should be
safe to retry.

#### Lock heartbeats

A worker locks each job it runs. If the worker dies or hangs without its
process exiting (a frozen VM, a lost node, a deadlocked process), that lock is
only considered abandoned after `max_run_time`, 4 hours by default. Lock
heartbeats shorten that: each worker process refreshes the locks of its running
jobs every few seconds, and a lock that hasn't been refreshed for the lock
timeout counts as abandoned, so another worker picks the job up.

```
RAILS_ENV=production script/delayed_job --fork --lock-heartbeat=30 --lock-timeout=120 start
LOCK_HEARTBEAT=30 LOCK_TIMEOUT=120 rake jobs:work
# or in an initializer
Delayed::Worker.lock_heartbeat_interval = 30
Delayed::Worker.lock_timeout = 120 # default 300; at least twice the heartbeat
```

* Turn heartbeats on for **every** worker running the same jobs: a worker
  without them doesn't refresh its locks, so its long jobs would be taken over
  after the lock timeout.
* The backend must support them (`Delayed::Job.lock_heartbeats?`); otherwise
  Delayed Job logs a warning and locks expire after `max_run_time` as before.
* A worker whose lock was taken over doesn't overwrite the new owner's result:
  backends that implement `destroy_if_locked_by` and `save_if_locked_by` only
  finish, reschedule or fail a job while the worker still holds its lock.
* A job taken over from a worker that was only slow, not dead, runs twice.
  Choose a lock timeout well above the time a worker can stall.

#### When the parent process dies

If the forking parent is killed (e.g. with `SIGKILL`), its worker processes
notice within a second, stop polling, finish their running jobs (or interrupt
and release them after the shutdown timeout) and exit, instead of running on as
orphans.

#### Worker processes that die

When a worker process dies while running jobs (killed by the OOM killer or
`SIGKILL`, or exiting with a failure status), the parent process recovers its
jobs right away instead of leaving them locked until `max_run_time` expires.
Each counts as a failed attempt with a `Delayed::ProcessExitError`: it is
rescheduled with the usual back-off, or fails permanently after `max_attempts`,
so a job that keeps killing its worker eventually stops. `:error` and
`:failure` plugin callbacks and the job's `error` and `failure` hooks run as
for any failed attempt.

If the database can't be reached at that moment, the jobs' locks expire after
`max_run_time` as before. Backends support this by implementing
`Delayed::Job.locked_jobs(worker_name)`; for backends without it, the locks are
only cleared.

### Running via Rake

You may start a worker process using `rake jobs:work`.
You can exit the rake task with `CTRL-C`.

To run all available jobs and exit, use `rake jobs:workoff`.

Set the `QUEUES` or `POOLS` environment variable to work specific queues.

```
# Start a worker listening to all jobs
rake jobs:work

# Run 4 worker processes and exit when all jobs are finished
# (NUM_WORKERS is an alias of NUM_PROCESSES)
NUM_PROCESSES=4 rake jobs:workoff

# Work all jobs from the "mailers" and "tasks" queues, then exit
NUM_PROCESSES=4 QUEUES=mailers,tasks rake jobs:workoff

# You may also specify POOLS pipe-delimited
POOLS=mailers,tasks:2|tweets:1|*:2 rake jobs:workoff

# Run 2 worker processes with 5 threads each
NUM_PROCESSES=2 NUM_THREADS=5 rake jobs:work

# Write tmp/pids/delayed_job.pid; refuse to start if another launcher holds it
PIDFILE=1 rake jobs:work
```

Rake uses Forking Mode (see above) under-the-hood.

### Development

In `development` environment, Delayed Job runs each job inside the Rails
reloader, so your application code is reloaded before a job when it has changed.
You should not need to restart Delayed Job each time you update your code.

## Advanced Topics

### Custom Jobs

Jobs are simple ruby objects with a method called `perform`.
Any object which responds to `perform` can be enqueued into the jobs table.
Job objects are serialized to YAML so that they can later be marshalled by the job runner.

```ruby
NewsletterJob = Struct.new(:text, :emails) do
  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end
end

Delayed::Job.enqueue NewsletterJob.new('lorem ipsum...', Customers.pluck(:email))
```

To override `Delayed::Worker.max_attempts` per-job, you can define a `max_attempts` instance method in the job class.

```ruby
NewsletterJob = Struct.new(:text, :emails) do
  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end

  def max_attempts
    3
  end
end
```

To override `Delayed::Worker.max_run_time` per-job, you may define a `max_run_time`
instance method in the job class.

**NOTE:** You may only set a `max_run_time` that is lower than `Delayed::Worker.max_run_time`.
Otherwise the lock on the job would expire and a second worker would start working the same in-progress job.

```ruby
NewsletterJob = Struct.new(:text, :emails) do
  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end

  def max_run_time
    120 # seconds
  end
end
```

To override `Delayed::Worker.destroy_failed_jobs` per-job, you may define a `destroy_failed_jobs?`
instance method in the job class.

```ruby
NewsletterJob = Struct.new(:text, :emails) do
  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end

  def destroy_failed_jobs?
    false
  end
end
```

To override `Delayed::Worker.default_queue_name` per-job, you may define a `queue_name`
instance method in the job class.

```ruby
NewsletterJob = Struct.new(:text, :emails) do
  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end

  def queue_name
    'newsletter_queue'
  end
end
```

On error, the job is scheduled again in 5 seconds + N ** 4, where N is the number of attempts.
You may define a `reschedule_at` instance method to override this default behavior.

```ruby
NewsletterJob = Struct.new(:text, :emails) do
  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end

  def reschedule_at(current_time, attempts)
    current_time + (attempts * 60).seconds
  end
end
```

### Hooks

You can define hooks on your job that will be called at different stages in the process:

**NOTE:** If you are using Active Job these hooks are **not** available to your jobs.
You will need to use Active Job's callbacks.
See the [Rails Guides](https://guides.rubyonrails.org/active_job_basics.html#callbacks) for details.

```ruby
class ParanoidNewsletterJob < NewsletterJob
  def enqueue(job)
    record_stat 'newsletter_job/enqueue'
  end

  def perform
    emails.each { |e| NewsletterMailer.deliver_text_to_email(text, e) }
  end

  def before(job)
    record_stat 'newsletter_job/start'
  end

  def after(job)
    record_stat 'newsletter_job/after'
  end

  def success(job)
    record_stat 'newsletter_job/success'
  end

  def error(job, exception)
    Airbrake.notify(exception)
  end

  def failure(job)
    page_sysadmin_in_the_middle_of_the_night
  end
end
```

### Silencing polling queries

An idle worker polls for jobs every `sleep_delay` seconds (and, with lock
heartbeats, refreshes its locks), which fills a debug-level SQL log. To keep
those queries out of the log:

```ruby
Delayed::Worker.silence_polling = true
```

or `--silence-polling` / `SILENCE_POLLING=1`. Only the polling thread is
silenced, below `WARN`, while it polls: queries made by jobs, and by workers
finishing them, are logged as usual. The default backend hook silences
`ActiveRecord::Base.logger` (it needs an `ActiveSupport::Logger`); backends
logging elsewhere override `Delayed::Job.silence_polling(&block)`.

### Reporting errors outside of jobs

Job errors go through the `:error` lifecycle callback and the job's `error`
hook. Other errors - a failed reservation or lock heartbeat (e.g. the database
is down), a crashed worker thread or dispatcher, a failing `failure` hook, the
failed recovery of a dead worker process' jobs - are logged; to report them too:

```ruby
Delayed::Worker.on_thread_error = ->(error, info) do
  Sentry.capture_exception(error, extra: info) # info: :context, :dispatcher, :worker, :job
end
```

Errors raised by the handler are logged and ignored. Each such error also
publishes a `thread_error.delayed_job` event (see below).

### Instrumentation

Workers publish `ActiveSupport::Notifications` events named `<event>.delayed_job`:

| Event | Payload |
| --- | --- |
| `start_process`, `stop_process` | `:dispatcher` (name), `:pid`, `:threads`, `:queues`; `stop_process` adds `:error` (what stopped it, or nil) |
| `reserve` (timed) | `:dispatcher`, `:requested` (idle threads), `:reserved` |
| `perform` (timed) | `:job`, `:worker`, `:success` |
| `attempt_failed` | `:job`, `:worker`, `:error`, `:attempts` (including this one) |
| `job_failed` | `:job`, `:worker`, `:error` - the job failed permanently |
| `lock_lost` | `:job`, `:worker`, `:outcome` - the job's lock was taken over, so this run's outcome was discarded |
| `thread_error` | `:error`, `:context`, and `:dispatcher`, `:worker`, `:job` where known - an error outside job handling (see `on_thread_error` above) |
| `interrupt` | `:dispatcher`, `:jobs`, `:reason` - running jobs interrupted by the shutdown timeout or `SIGQUIT` |
| `locks_released` | `:workers`, `:count`, `:reason` (`shutdown` or `process exit`) |
| `fork_replaced` | `:worker`, `:pid`, `:status`, `:new_pid` - the forking parent replaced a worker process that exited |

Timed events also carry `:exception` when their block raised. Events are
published on worker threads; an exception raised by a subscriber is logged and
ignored, so it can't fail or skip a job.

```ruby
ActiveSupport::Notifications.subscribe('job_failed.delayed_job') do |event|
  ErrorTracker.notify(event.payload[:error], job_id: event.payload[:job].id)
end
```

`Delayed::LogSubscriber` logs these events to `Delayed::Worker.logger`
(`reserve` and `perform` at debug level, with their durations). Workers already
log their activity, so it isn't attached by default:

```ruby
Delayed::LogSubscriber.attach_to :delayed_job
```

### Gory Details

The library revolves around a `delayed_jobs` table which looks as follows:

```ruby
create_table :delayed_jobs, :force => true do |table|
  table.integer  :priority, :default => 0      # Allows some jobs to jump to the front of the queue
  table.integer  :attempts, :default => 0      # Provides for retries, but still fail eventually.
  table.text     :handler                      # YAML-encoded string of the object that will do work
  table.text     :last_error                   # reason for last failure (See Note below)
  table.datetime :run_at                       # When to run. Could be Time.zone.now for immediately, or sometime in the future.
  table.datetime :locked_at                    # Set when a client is working on this object
  table.datetime :failed_at                    # Set when all retries have failed (actually, by default, the record is deleted instead)
  table.string   :locked_by                    # Who is working on this object (if locked)
  table.string   :queue                        # The name of the queue this job is in
  table.timestamps
end
```

On error, the job is scheduled again in 5 seconds + N ** 4, where N is the number of attempts or using the job's defined `reschedule_at` instance method.

The default `Delayed::Worker.max_attempts` is 25. After this, the job is either deleted (default), or left in the database with "failed_at" set.
With the default of 25 attempts, the last retry will be 20 days later, with the last interval being almost 100 hours.

The default `Delayed::Worker.max_run_time` is 4.hours. If your job takes longer than that, another computer could pick it up. It's up to you to
make sure your job doesn't exceed this time. You should set this to the longest time you think the job could take.

By default, it will delete failed jobs (and it always deletes successful jobs). If you want to keep failed jobs, set
`Delayed::Worker.destroy_failed_jobs = false`. The failed jobs will be marked with non-null failed_at.

By default all jobs are scheduled with `priority = 0`, which is top priority. You can change this by setting `Delayed::Worker.default_priority` to something else. Lower numbers have higher priority.

The default behavior is to read 5 jobs from the queue when finding an available job. You can configure this by setting `Delayed::Worker.read_ahead`.

By default all jobs will be queued without a named queue. A default named queue can be specified by using `Delayed::Worker.default_queue_name`.

If no jobs are found, the worker sleeps for the amount of time specified by the sleep delay option. Set `Delayed::Worker.sleep_delay = 60` for a 60 second sleep time.

It is possible to disable delayed jobs for testing purposes. Set `Delayed::Worker.delay_jobs = false` to execute all jobs realtime.

`Delayed::Worker.delay_jobs` may also be a `Proc` that decides whether to execute jobs inline on a per-job basis:

```ruby
Delayed::Worker.delay_jobs = ->(job) {
  job.queue != 'inline'
}
```

You may need to raise exceptions on SIGTERM signals, `Delayed::Worker.raise_signal_exceptions = :term` will cause the worker to raise a `SignalException` causing the running job to abort and be unlocked, which makes the job available to other workers. The default for this option is false.

Here is an example of changing job parameters in Rails:

```ruby
# config/initializers/delayed_job_config.rb
Delayed::Worker.destroy_failed_jobs = false
Delayed::Worker.sleep_delay = 60
Delayed::Worker.max_attempts = 3
Delayed::Worker.max_run_time = 5.minutes
Delayed::Worker.read_ahead = 10
Delayed::Worker.default_queue_name = 'default'
Delayed::Worker.delay_jobs = !Rails.env.test?
Delayed::Worker.raise_signal_exceptions = :term
Delayed::Worker.logger = Logger.new(File.join(Rails.root, 'log', 'delayed_job.log'))
```

### Cleaning up

You can invoke `rake jobs:clear` to delete all jobs in the queue.

### Having problems?

Good places to get help are:
* [Google Groups](http://groups.google.com/group/delayed_job) where you can join our mailing list.
* [StackOverflow](http://stackoverflow.com/questions/tagged/delayed-job)
