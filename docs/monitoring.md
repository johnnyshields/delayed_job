# Monitoring Delayed Job

The most important signal is **how long the oldest runnable job has been
waiting**: it rises whatever the cause - dead workers, a crash loop, a database
outage, stuck jobs or too little capacity. Alert on it first; use the signals
below to find out why.

## Failure scenarios

| Failure | What happens automatically | Signal |
|---|---|---|
| Launcher dies | Children finish their jobs and exit; nothing restarts the launcher | Supervisor; no workers polling |
| Child process dies | Its jobs count a failed attempt and are rescheduled; it is replaced | `child_exited` with a failure status |
| Child crash loop | Replaced after 1s, 2s, 4s… up to 60s | `child_exited` with `respawn_in > 0` |
| Worker thread crashes | Its child process stops, then as above | `thread_error` (`Worker thread`) |
| Database unreachable | Retried; after 10 failed polls in a row the child exits and is replaced | `thread_error` (`Reservation`) |
| Lock heartbeat failing | Retried; stops after 5 failures in a row | `thread_error` (`Lock heartbeat`) |
| Job stuck (native code) | With heartbeats, its lock lapses after `lock_timeout` and another worker runs it | `job_stuck`; later `lock_lost` |
| Job ran twice (lock taken over) | The later run's outcome is kept | `lock_lost` |
| Job fails | Retried with back-off; fails permanently after `max_attempts` | `attempt_failed`, `job_failed` |
| Shutdown overran | Running jobs interrupted and released | `interrupt` |
| Fork fails | Retried with back-off | `thread_error` (`Forking`) |

## Errors outside jobs

```ruby
# config/initializers/delayed_job.rb
Delayed::Worker.on_thread_error = ->(error, info) do
  Sentry.capture_exception(error, tags: { dj_context: info[:context] }, extra: info.except(:job))
end
```

`info[:context]` is one of `Reservation`, `Lock heartbeat`, `Worker thread`,
`Dispatcher`, `Failure hook`, `Recovering jobs`, `Releasing interrupted jobs`,
`Forking`. Report job errors through an `:error` lifecycle callback or the
`attempt_failed` event.

## Metrics from events

Workers publish `ActiveSupport::Notifications` events named
`<event>.delayed_job` (payloads are listed in the README). A subscriber that
raises is logged and ignored. Subscribe in an initializer, so that child
processes inherit it:

```ruby
ActiveSupport::Notifications.subscribe(/\.delayed_job\z/) do |event|
  name = event.name.delete_suffix('.delayed_job')
  p = event.payload
  case name
  when 'perform'
    METRICS.timing('dj.perform', event.duration, tags: ["job:#{p[:job].name}", "success:#{p[:success]}"])
  when 'attempt_failed', 'job_failed', 'lock_lost', 'job_stuck'
    METRICS.increment("dj.#{name}", tags: ["job:#{p[:job].name}"])
  when 'thread_error'
    METRICS.increment('dj.thread_error', tags: ["context:#{p[:context]}"])
  when 'child_exited'
    METRICS.increment('dj.child_exited', tags: ["clean:#{p[:status].success?}", "delayed:#{p[:respawn_in].to_i > 0}"])
  when 'child_spawned', 'interrupt', 'locks_released'
    METRICS.increment("dj.#{name}")
  end
end
```

`METRICS` stands for your metrics client (StatsD, Datadog, Prometheus...). To
log every event instead, attach the bundled subscriber:
`Delayed::LogSubscriber.attach_to :delayed_job`.

## Queue health from the database

Collect these from outside the workers (cron or a metrics agent), so they keep
reporting when every worker is down:

```ruby
now = Delayed::Job.db_time_now
waiting = Delayed::Job.where(failed_at: nil, locked_at: nil).where('run_at <= ?', now)
expiry = Delayed::Worker.lock_heartbeat_interval ? Delayed::Worker.lock_timeout : Delayed::Worker.max_run_time

METRICS.gauge('dj.backlog', waiting.count)
METRICS.gauge('dj.oldest_waiting_seconds', (now - (waiting.minimum(:run_at) || now)).to_i)
METRICS.gauge('dj.held', Delayed::Job.where(failed_at: nil).where.not(locked_at: nil).count)
METRICS.gauge('dj.failed', Delayed::Job.where.not(failed_at: nil).count)
METRICS.gauge('dj.stale_locks', Delayed::Job.where(failed_at: nil).where('locked_at < ?', now - expiry).count)
```

Group by `queue` if you use pools. With Mongoid, use the equivalent criteria.

`held` counts locked jobs: those running and, with `--prefetch`, those queued
behind them. The database can't tell the two apart; the number running is the
`busy` count in each process's title (see below), and the rest are queued.

## Alerts

| Alert | Condition |
|---|---|
| Queue stalled | `oldest_waiting_seconds` above your latency target, per queue |
| No workers | No launcher process, or no `perform`/`reserve` events for 5 minutes while the backlog is > 0 |
| Crash loop | `child_exited` with `respawn_in > 0` for 10 minutes |
| Infrastructure | Any `thread_error` with context `Reservation`, `Lock heartbeat`, `Forking` or `Recovering jobs` |
| Stuck jobs | Any `job_stuck`, or `stale_locks > 0` |
| Duplicate runs | Any `lock_lost` (raise `LOCK_TIMEOUT`) |
| Failures | Rise in the `job_failed` rate or the `failed` count |
| Slow shutdowns | `interrupt` outside deploys |

## On the host

`ps` shows each child process's state live, e.g.
`delayed_job.0: 3/4 busy, queues=mail` or `delayed_job.1: stopping, 1/4 busy, queues=*`.
A child stuck at full capacity while its queue grows means long or stuck jobs.

The launcher logs every child process start and exit, and each quick death
before a delayed respawn: `Child process delayed_job.2 (pid 812) died 0.4s
after starting (3 time(s) in a row); waiting 4s before replacing it`.

## Liveness probes

The default probe (process alive) is usually enough with the queue alerts
above. For a deeper per-process probe, touch a file on `reserve` and `perform`
events and check its age - but a process whose threads are all busy with long
jobs doesn't poll, so allow more than your longest normal job.
