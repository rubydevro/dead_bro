## [Unreleased]

## [0.2.14] - 2026-05-23

### Added
- `DbConnectionSubscriber`: measures the time threads spend waiting to acquire a connection from the ActiveRecord connection pool and counts checkouts per request. Uses `prepend` on `ActiveRecord::ConnectionAdapters::ConnectionPool#checkout` so the overhead is minimal and the instrumentation is invisible to application code. `db_connection_wait_ms` and `db_connection_checkouts` are included in both request and job payloads.
- Queue duration tracking for web requests via `X-Request-Start` / `X-Queue-Start` headers. Parses both the Heroku microsecond format (`t=<µs>`) and the nginx seconds format (`t=<s.ms>`), and applies a 60 s clock-skew cap so a misconfigured proxy timestamp cannot produce a nonsensical value.
- Queue duration tracking for background jobs: time from `job.enqueued_at` to when `perform` begins is reported as `queue_duration_ms` in every job payload.
- `RedisSubscriber`: prepend-based instrumentation on `Redis::Client` that records every individual command, pipeline, and `MULTI`/`EXEC` block with command name, key, duration in ms, and database index. Falls back to an `ActiveSupport::Notifications` subscription for `redis.*` events emitted by other libraries. Capped at 1 000 events per request to bound memory growth.
- DB connection tracking wired into background jobs: `DbConnectionSubscriber` is started and stopped around job execution in both the normal completion path and the exception handler fallback path, with cleanup in `drain_job_tracking`.

## [0.1.0] - 2025-08-28

- Initial release
