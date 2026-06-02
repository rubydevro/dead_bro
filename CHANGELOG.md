## [Unreleased]

### Added
- Monitor thread now sends a synchronous heartbeat on startup before the first collection tick. This ensures remote settings — including `monitor_enabled` — are applied from the very first reporting cycle, so Sidekiq workers and other non-web processes that have not yet sent any metrics still receive the correct configuration immediately on boot rather than waiting up to 60 seconds for the first scheduled tick.

## [0.2.21] - 2026-06-02

### Added
- **Per-span timing for the Request Trace view.** Every instrumented event now includes a `start_offset_ms` field — the wall-clock milliseconds from rack entry to when that event started. This powers the waterfall visualisation in the DeadBro dashboard without any configuration changes.
  - `SqlSubscriber`: `start_offset_ms` is computed from `TRACKING_START_TIME_KEY` using the `started` timestamp provided by `ActiveSupport::Notifications`. Stored on both the raw per-query hash and on the first-occurrence aggregate entry (so the bar is positioned at the actual time the query first ran, not a fabricated cumulative offset).
  - `ViewRenderingSubscriber`: same pattern applied to template, partial, and collection render events. `start_offset_ms` is captured for the first render of each unique identifier and stored on the aggregate.
  - `CacheSubscriber`: `start_offset_ms` derived from the `started` `ActiveSupport::Notifications` timestamp, added to every cache event hash and passed through `build_event`.
  - `RedisSubscriber`: `wall_start = Time.now` is captured at the entry point of each instrumented block (`call`, `call_pipeline`, `call_multi`). The monotonic clock is still used for duration accuracy; `wall_start` is used only for the offset relative to `TRACKING_START_TIME_KEY`. Also applied to the `ActiveSupport::Notifications` fallback path in `install_notifications_subscription!`.
  - `ElasticsearchSubscriber`: `start_offset_ms` added to `build_event`; the `record` method (called from `HttpInstrumentation` for Net::HTTP-based ES requests) now accepts a `start_offset_ms:` keyword argument. The `ActiveSupport::Notifications` subscription path (`request.elasticsearch` / `request.elastic_transport`) computes it from `started`.
  - `HttpInstrumentation`: `wall_start = Time.now` captured alongside the existing monotonic `start_time`. `start_offset_ms` is included in the HTTP outgoing payload and forwarded to `ElasticsearchSubscriber.record` for requests routed to an ES host.

## [0.2.20] - 2026-05-29

### Added
- Monitor thread sends a synchronous heartbeat immediately on startup (before the first scheduled collection tick) so that remote settings — including `monitor_enabled` — are applied from the very first reporting cycle. Sidekiq workers and other non-web processes now receive the correct configuration on boot rather than waiting up to 60 seconds for the first tick.
- `gem_version` field added to every heartbeat payload so the dashboard can display and compare the running gem version per application.
- `process_kind` included in all system monitor payloads, linking server metrics to the correct process type.
- `post_heartbeat` now accepts a `sync: true` keyword for situations that require a blocking network call before proceeding (used by the monitor startup path).

## [0.2.19] - 2026-05-28

### Added
- **Error fingerprinting**: every unhandled exception payload now includes a stable `fingerprint` string derived from the exception class, a normalised version of the message (numeric IDs and UUIDs stripped), and the top application stack frame. Identical errors that differ only in record IDs or UUIDs produce the same fingerprint, enabling reliable grouping and deduplication on the server.
- `DeadBro.process_kind` auto-detects the type of the current Ruby process by inspecting `$PROGRAM_NAME` and `/proc/self/cmdline`: returns `"web"` (Puma/Passenger/Unicorn/Falcon), `"worker"` (Sidekiq/GoodJob/SolidQueue/DelayedJob), `"console"`, `"task"`, or `"app"` as a fallback. The value is memoised after the first call.
- `process_kind` included in error event payloads so the backend knows whether an exception came from a web request or a background worker.

## [0.2.18] - 2026-05-27

### Added
- **N+1 detection in the gem**: SQL queries are normalised (bind parameters, numeric literals, and `IN (...)` lists replaced with `?`) and counted per request. When the same normalised query fires 5 or more times, it is flagged as `n_plus_one: true` on its aggregate entry. A backtrace is captured exactly at the N+1 threshold rather than on every execution, keeping overhead low while still pointing to the callsite.
- **SQL aggregation**: instead of shipping a raw array of every query, the gem now groups queries by normalised SQL and sends one aggregate entry per unique pattern with `count`, `total_duration_ms`, `min_duration_ms`, `max_duration_ms`, `total_allocations`, and `cached_count`. This reduces payload size on N+1-heavy requests and makes the SQL breakdown directly usable without server-side grouping.
- **View rendering aggregation**: template, partial, and collection renders are aggregated per identifier (last three path segments). Each entry carries `count`, `total_duration_ms`, `min_duration_ms`, `max_duration_ms`, `rendered_at_min/max`, and cache hit counts. Aggregation happens on the thread-local stack so there is no GC pressure from intermediate arrays.

## [0.2.17] - 2026-05-25

### Added
- `DeadBro.track(error, **context)`: manually report a rescued exception to the DeadBro backend from any `rescue` block. Accepts any `Exception` subclass and optional keyword arguments forwarded as a `:context` hash in the payload. The report includes exception class, message, a 50-frame backtrace, `occurred_at` timestamp, environment, and any captured log lines from the current request. Never raises — APM reporting will not interfere with your application code.

## [0.2.16] - 2026-05-24

### Added
- `ArObjectTracker`: subscribes to Rails' built-in `instantiation.active_record` notification to count the total number of ActiveRecord model instances hydrated during each request or background job. The count is reported as `ar_instantiation_count` in every payload. Uses a thread-local counter with an idempotent `subscribe!` guard, matching the same start/stop lifecycle as `GcTracker`. No monkey-patching required — Rails emits this event natively with a `record_count` field that accumulates correctly across batch loads.

## [0.2.15] - 2026-05-24

### Added
- **`GcTracker`**: records a GC snapshot at the start and end of every request and background job. Reports `gc_minor_runs`, `gc_major_runs`, `gc_allocated_objects`, `gc_time_ms`, and `heap_pages_increase` as a `gc_pressure` hash in every payload. Uses `GC.stat` and `GC::Profiler` with an idempotent subscribe guard; overhead is negligible when no GC cycles occur.
- **`SqlAllocListener`**: measures GC allocation deltas per SQL event by snapshotting `GC.stat[:total_allocated_objects]` in the notification `start` callback and diffing in `finish`. The delta is stored by notification ID and merged into the corresponding query's `allocations` field, allowing the dashboard to surface allocation-heavy queries independently of their duration.

## [0.2.14] - 2026-05-23

### Added
- `DbConnectionSubscriber`: measures the time threads spend waiting to acquire a connection from the ActiveRecord connection pool and counts checkouts per request. Uses `prepend` on `ActiveRecord::ConnectionAdapters::ConnectionPool#checkout` so the overhead is minimal and the instrumentation is invisible to application code. `db_connection_wait_ms` and `db_connection_checkouts` are included in both request and job payloads.
- Queue duration tracking for web requests via `X-Request-Start` / `X-Queue-Start` headers. Parses both the Heroku microsecond format (`t=<µs>`) and the nginx seconds format (`t=<s.ms>`), and applies a 60 s clock-skew cap so a misconfigured proxy timestamp cannot produce a nonsensical value.
- Queue duration tracking for background jobs: time from `job.enqueued_at` to when `perform` begins is reported as `queue_duration_ms` in every job payload.
- `RedisSubscriber`: prepend-based instrumentation on `Redis::Client` that records every individual command, pipeline, and `MULTI`/`EXEC` block with command name, key, duration in ms, and database index. Falls back to an `ActiveSupport::Notifications` subscription for `redis.*` events emitted by other libraries. Capped at 1 000 events per request to bound memory growth.
- DB connection tracking wired into background jobs: `DbConnectionSubscriber` is started and stopped around job execution in both the normal completion path and the exception handler fallback path, with cleanup in `drain_job_tracking`.

## [0.1.0] - 2025-08-28

- Initial release
