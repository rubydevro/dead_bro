# DeadBro (Beta Version)

Minimal APM for Rails apps. Automatically measures each controller action's total time, tracks SQL queries, monitors view rendering performance, tracks memory usage and detects leaks, monitors background jobs, and posts metrics to DeadBro.

**Current versions:** almost everything (sampling, exclusions, SQL EXPLAIN, memory toggles, control-plane collectors, enable/disable, and more) is configured in the [DeadBro](https://www.deadbro.com) web app. The API returns those settings on successful requests and the gem applies them in memory—no need to mirror them in Ruby unless you want optional code-based overrides.

To use the gem you need a free account with [DeadBro - Rails APM](https://www.deadbro.com).

## Installation

Add to your Gemfile:

```ruby
gem "dead_bro", git: "https://github.com/rubydevro/dead_bro.git"
```

Then run the install generator to create the initializer:

```sh
bin/rails generate dead_bro:install
```

This creates `config/initializers/dead_bro.rb`. Set `DEAD_BRO_API_KEY` in your environment and you're done.

## Usage

By default, if Rails is present, DeadBro auto-subscribes to `process_action.action_controller` and posts metrics asynchronously.

### Required: API key in your app

The install generator above creates `config/initializers/dead_bro.rb` for you. If you prefer to add it manually, create the file and set your API key from the environment, [Rails credentials](https://guides.rubyonrails.org/security.html#custom-credentials), or another secret store:

```ruby
DeadBro.configure do |config|
  config.api_key = ENV["DEAD_BRO_API_KEY"]
end
```

That is enough to start shipping metrics. Create or copy the key from your DeadBro account, then wire it into `DEAD_BRO_API_KEY` (or assign `config.api_key` directly).

### Deploy / release tracking (ECS, Kubernetes, autoscaling groups)

DeadBro sends a **`revision`** string on every payload so charts and deploys group metrics by release. If you do **not** configure a stable value, the gem generates a UUID **once per Ruby process**. With multiple containers or EC2 instances, each replica then looks like a separate deployment.

**Use one shared identifier for every task in the same rollout**, for example:

- Set `DEAD_BRO_DEPLOY_ID` (or `dead_bro_DEPLOY_ID`) in the task definition / pod spec to your **git SHA**, **image digest**, or CD **release id** injected at build or deploy time.
- Or set it in Ruby (this wins over environment variables when non-blank):

```ruby
DeadBro.configure do |config|
  config.deploy_id = ENV.fetch("GIT_SHA") { raise "Set GIT_SHA in the task definition" }
end
```

The gem also checks these environment variables in order (first non-empty wins): `DEAD_BRO_DEPLOY_ID`, `dead_bro_DEPLOY_ID`, `GIT_REV`, `GIT_COMMIT`, `GIT_COMMIT_SHA`, `GIT_SHA`, `CODEBUILD_RESOLVED_SOURCE_REVISION`, `HEROKU_SLUG_COMMIT`, `RENDER_GIT_COMMIT`, `DD_VERSION`, `APP_REVISION`, `RELEASE_VERSION`, `SOURCE_VERSION`.

For **Amazon ECS**, add one of these variables in your task definition from CodeBuild, GitHub Actions, or your pipeline so all tasks in the service share the same value for that image version.

### Dashboard configuration

Use the DeadBro UI to turn features on or off, set sample rates, define controller/job inclusions and exclusions, tune slow-query EXPLAIN, enable queue and system metrics, and adjust related limits. After you deploy the initializer above, those choices take effect when the gem receives them from the API (typically on the next successful metric or heartbeat response).

### Optional local flags

You can still set `config.enabled` in Ruby if you need to force the integration off in a given environment before any remote settings arrive; otherwise the dashboard can control `enabled` like other remote settings.

## Request Sampling, Exclusions & Whitelisting

To control data volume, DeadBro supports request sampling (track a percentage of requests), excluding specific controllers/jobs from tracking, and whitelisting (tracking *only* specific controllers/jobs). All of this is configured in the DeadBro dashboard — sample rate, `excluded_controllers`/`excluded_jobs`, and `exclusive_controllers`/`exclusive_jobs` patterns (wildcards like `Admin::*` and `Admin::*#*` supported). Exclusion always takes precedence over whitelisting when a pattern matches both.

## SQL Query Tracking

DeadBro automatically tracks SQL queries executed during each request and job. Each request will include a `sql_queries` array containing:
- `sql` - The SQL query (always sanitized)
- `name` - Query name (e.g., "User Load", "User Update")
- `duration_ms` - Query execution time in milliseconds
- `cached` - Whether the query was cached
- `connection_id` - Database connection ID
- `trace` - Call stack showing where the query was executed
- `explain_plan` - Query execution plan (when EXPLAIN capture is enabled, see below)

## Automatic EXPLAIN for Slow Queries

DeadBro can automatically capture the query plan (`EXPLAIN`) of slow SELECT queries to help you understand query performance and identify optimization opportunities.

### Safety guarantees

- **Plan-only, never executed**: DeadBro runs plain `EXPLAIN` (never `EXPLAIN ANALYZE`), which asks the database for its plan without executing the statement. Your queries are never re-run and your data is never touched.
- **SELECT-only allowlist**: only `SELECT` statements (and read-only `WITH ... SELECT` CTEs) are ever explained. INSERT/UPDATE/DELETE, DDL, and multi-statement strings are always skipped.
- **Local opt-in required**: the feature is off unless you enable it in your own `DeadBro.configure` block. The DeadBro backend can remotely *disable* it (e.g. plan gating), but can never switch it on.
- **Value scrubbing**: quoted string literals echoed in plan text (e.g. `Filter: email = 'a@b.com'`) are replaced with `?` before the plan leaves your app.
- **Bounded overhead**: plans are captured on background threads (max 3 concurrent per request); at request end DeadBro waits at most 0.5s for stragglers, then drops them.

### Configuration

- **`explain_analyze_enabled`** (default: `false`) — this is the one setting that must be turned on in Ruby; the dashboard toggle can only turn capture *off*, never on, as an extra safety rail:

  ```ruby
  DeadBro.configure do |config|
    config.explain_analyze_enabled = true
  end
  ```

- Everything else — the `slow_query_threshold_ms` cutoff and enabling/disabling the feature — is managed from the dashboard.

When a slow query is detected, the `explain_plan` field in the SQL query data contains the database's `EXPLAIN` (or `EXPLAIN QUERY PLAN` on SQLite) output — the planner's chosen strategy, estimated costs and row counts — useful for spotting missing indexes or unexpected sequential scans. Because the statement is never executed, plans show estimates rather than actual runtimes.

## View Rendering Tracking

DeadBro automatically tracks view rendering performance for each request. This includes:

- **Individual view events**: Templates, partials, and collections rendered
- **Performance metrics**: Rendering times for each view component
- **Cache analysis**: Cache hit rates for partials and collections
- **Slow view detection**: Identification of the slowest rendering views
- **Frequency analysis**: Most frequently rendered views

## Memory Tracking & Leak Detection

DeadBro automatically tracks memory usage and detects memory leaks with minimal performance impact. This includes:

### Performance-Optimized Memory Tracking

By default, DeadBro uses **lightweight memory tracking** that has minimal performance impact:

- **Memory Usage Monitoring**: Track memory consumption per request (using GC stats, not system calls)
- **Memory Leak Detection**: Detect growing memory patterns over time
- **GC Efficiency Analysis**: Monitor garbage collection effectiveness
- **Zero Allocation Tracking**: No object allocation tracking by default (can be enabled)

`memory_tracking_enabled`, `allocation_tracking_enabled`, and `allocation_sample_rate` are all managed from the dashboard.

**Performance Impact:**
- **Lightweight mode** (`memory_tracking_enabled`, ~0.1ms overhead per request): RSS before/after, GC pressure, the retained-vs-transient signals (`heap_live_slots_growth`, `malloc_increase_bytes`), and per-phase allocation attribution (`allocation_phases` — which of `sql`/`view`/`elasticsearch` allocated the request's objects).
- **Allocation tracking** (`allocation_tracking_enabled`, ~2-5ms overhead per request — only enable when needed): adds by-bytes object-type breakdown (`memsize_by_type`) and allocation-source attribution (`allocation_sources`, `file:line`) using the `objspace` extension, which is loaded only on this path. Use `allocation_sample_rate` to spread that cost across a fraction of traffic.

## Job Tracking

DeadBro automatically tracks ActiveJob background jobs when ActiveJob is available. Each job execution is tracked with:

- `job_class` - The job class name (e.g., "UserMailer::WelcomeEmail")
- `job_id` - Unique job identifier
- `queue_name` - The queue the job was processed from
- `arguments` - Sanitized job arguments (sensitive data filtered)
- `duration_ms` - Job execution time in milliseconds
- `status` - "completed" or "failed"
- `sql_queries` - Array of SQL queries executed during the job
- `exception_class` - Exception class name (for failed jobs)
- `message` - Exception message (for failed jobs)
- `backtrace` - Exception backtrace (for failed jobs)

## Control Plane Metrics (Queues, DB, Process, System)

DeadBro includes a lightweight **control plane metrics** job that runs periodically (by default once per minute via `DeadBro::JobQueueMonitor`) and sends a single JSON payload summarizing:

- **Sidekiq / job queues**: global stats (`processed`, `failed`, `enqueued`, `scheduled_size`, `retry_size`, `dead_size`, `workers_size`, `processes_size`), and per-queue entries with `name`, `size`, and `latency_s`.
- **Database (best effort)**: connection pool stats and a simple `ping_ms` latency when `ActiveRecord` is available and connected.
- **Process / Rails**: `pid`, `hostname`, uptime, Ruby/Rails versions, environment, GC stats, RSS (`rss_bytes`), thread and file descriptor counts (on Linux).
- **System (Linux best effort)**: CPU percentage over the last interval (normalised 0–100), memory used/total/available, plus filesystem and network summaries.

Everything is **best effort** and designed to be **safe and low overhead**:

- Collection never raises; failures are reported as `{error_class, error_message}` under the respective section key.
- No sensitive data is sent (no job arguments, env vars, CLI args, or full SQL text in these control-plane metrics).
- CPU and network *rates* require two samples; on the first run you may see `nil` for `cpu_pct` or network `*_bytes_per_s` fields until a second sample is available.

### Configuration

Enable or disable the job queue monitor and the individual collectors (`enable_db_stats`, `enable_process_stats`, `enable_system_stats`), plus `disk_paths` and `interfaces_ignore`, from the DeadBro dashboard.

### Example Payload Shape

The control plane job sends a single JSON payload roughly shaped like:

```json
{
  "ts": "2025-01-01T12:00:00Z",
  "app_name": "MyApp",
  "env": "production",
  "host": "app-1",
  "pid": 12345,
  "versions": {
    "ruby": "3.1.2",
    "rails": "7.1.0",
    "sidekiq": "7.3.0"
  },
  "queue_system": "sidekiq",
  "sidekiq": {
    "processed": 1000,
    "failed": 5,
    "enqueued": 42,
    "scheduled_size": 3,
    "retry_size": 2,
    "dead_size": 1,
    "workers_size": 4,
    "processes_size": 2,
    "memory_rss_bytes": 123456789,
    "queues": [
      {"name": "default", "size": 10, "latency_s": 0.5}
    ]
  },
  "db": {
    "available": true,
    "pool": {
      "size": 5,
      "connections": 3,
      "busy": 1,
      "num_waiting": 0
    },
    "ping_ms": 2.1
  },
  "process": {
    "pid": 12345,
    "hostname": "app-1",
    "uptime_s": 3600.5,
    "rss_bytes": 123456789,
    "thread_count": 20,
    "fd_count": 128,
    "gc": {
      "heap_live_slots": 123_456,
      "heap_free_slots": 12_345,
      "total_allocated_objects": 1_234_567,
      "major_gc_count": 10,
      "minor_gc_count": 50
    }
  },
  "system": {
    "cpu_pct": 12.3,
    "mem_used_bytes": 987654321,
    "mem_total_bytes": 2147483648,
    "mem_available_bytes": 1153433600,
    "disk": {
      "paths": [
        {
          "path": "/",
          "disk_total_bytes": 107374182400,
          "disk_free_bytes": 53687091200,
          "disk_available_bytes": 53687091200
        }
      ]
    },
    "net": {
      "available": true,
      "interfaces": [
        {
          "name": "eth0",
          "rx_bytes": 123456,
          "tx_bytes": 654321,
          "rx_bytes_per_s": 1000.0,
          "tx_bytes_per_s": 500.0
        }
      ]
    }
  }
}
```

Not all fields will be present in all environments; unsupported or unavailable metrics may be `null` or omitted, and any hard failures are captured in `error_class` / `error_message` fields per section.


## One-Off Analysis with `DeadBro.analyze`

Use `DeadBro.analyze` to profile any block of code inline — useful in the Rails console, rake tasks, or debug sessions. It tracks execution time, SQL queries, and memory usage without sending data to the DeadBro backend.

```ruby
result = DeadBro.analyze("load active users") do
  User.where(active: true).includes(:profile).to_a
end
```

Returns a `DeadBro::AnalysisResult` struct.

### Return Value

`DeadBro::AnalysisResult` exposes:

| Member | Type | Description |
|---|---|---|
| `label` | String | Label passed to the block |
| `total_time_ms` | Float | Wall time of the block |
| `sql_count` | Integer | Number of SQL queries executed |
| `sql_time_ms` | Float | Total SQL execution time |
| `sql_queries` | Array | Per-query breakdown (see below) |
| `memory_before_mb` | Float | RSS before block |
| `memory_after_mb` | Float | RSS after block |
| `memory_delta_mb` | Float | Memory change |
| `memory_details` | Hash | GC stats, new objects, heap pages |

**`sql_queries` is intentionally excluded from `inspect`/`to_s`** to avoid flooding the console with a long array. Access it explicitly when needed:

```ruby
result             # => #<DeadBro::AnalysisResult label="load active users" total_time_ms=42.3 ...>
result.sql_queries # => [{sql: "SELECT ...", query_type: "SELECT", count: 3, total_time_ms: 12.1}, ...]
```

### Options

```ruby
DeadBro.analyze("my block", verbose: true) do
  # verbose: true lowers the Rails log level to DEBUG and enables
  # ActiveRecord.verbose_query_logs for the duration of the block
  MyService.call
end
```

### Helper methods

```ruby
result.most_queries    # top 5 query patterns by execution count
result.longest_queries # top 5 query patterns by total_time_ms
```

Both return an array of query hashes (same shape as `sql_queries`):

- `sql` — normalized SQL (literals replaced, whitespace collapsed)
- `query_type` — e.g. `"SELECT"`, `"INSERT"`, `"UPDATE"`
- `count` — how many times this pattern ran
- `total_time_ms` — combined time across all occurrences

### `sql_queries` fields

`result.sql_queries` returns the full list. Each entry is a hash with the same fields as above.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rubydevro/dead_bro.
