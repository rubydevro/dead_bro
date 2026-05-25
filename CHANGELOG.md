## [Unreleased]

## [0.2.17] - 2026-05-25

### Added
- `DeadBro.track(error, **context)`: manually report a rescued exception to the DeadBro backend from any `rescue` block. Accepts any `Exception` subclass and optional keyword arguments forwarded as a `:context` hash in the payload. The report includes exception class, message, a 50-frame backtrace, `occurred_at` timestamp, environment, and any captured log lines from the current request. Never raises — APM reporting will not interfere with your application code.

## [0.2.16] - 2026-05-24

### Added
- `ArObjectTracker`: subscribes to Rails' built-in `instantiation.active_record` notification to count the total number of ActiveRecord model instances hydrated during each request or background job. The count is reported as `ar_instantiation_count` in every payload. Uses a thread-local counter with an idempotent `subscribe!` guard, matching the same start/stop lifecycle as `GcTracker`. No monkey-patching required — Rails emits this event natively with a `record_count` field that accumulates correctly across batch loads.

## [0.2.14] - 2026-05-23

### Added
- `DbConnectionSubscriber`: measures the time threads spend waiting to acquire a connection from the ActiveRecord connection pool and counts checkouts per request. Uses `prepend` on `ActiveRecord::ConnectionAdapters::ConnectionPool#checkout` so the overhead is minimal and the instrumentation is invisible to application code. `db_connection_wait_ms` and `db_connection_checkouts` are included in both request and job payloads.
- Queue duration tracking for web requests via `X-Request-Start` / `X-Queue-Start` headers. Parses both the Heroku microsecond format (`t=<µs>`) and the nginx seconds format (`t=<s.ms>`), and applies a 60 s clock-skew cap so a misconfigured proxy timestamp cannot produce a nonsensical value.
- Queue duration tracking for background jobs: time from `job.enqueued_at` to when `perform` begins is reported as `queue_duration_ms` in every job payload.
- `RedisSubscriber`: prepend-based instrumentation on `Redis::Client` that records every individual command, pipeline, and `MULTI`/`EXEC` block with command name, key, duration in ms, and database index. Falls back to an `ActiveSupport::Notifications` subscription for `redis.*` events emitted by other libraries. Capped at 1 000 events per request to bound memory growth.
- DB connection tracking wired into background jobs: `DbConnectionSubscriber` is started and stopped around job execution in both the normal completion path and the exception handler fallback path, with cleanup in `drain_job_tracking`.

## [0.1.0] - 2025-08-28

- Initial release
