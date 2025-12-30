# DeadBro (Beta Version)

Minimal APM for Rails apps. Automatically measures each controller action's total time, tracks SQL queries, monitors view rendering performance, tracks memory usage and detects leaks, monitors background jobs, and posts metrics to a remote endpoint with an API key read from your app's settings/credentials/env.

To use the gem you need to have a free account with [DeadBro - Rails APM](https://www.deadbro.com)

## Installation

Add to your Gemfile:

```ruby
gem "dead_bro", git: "https://github.com/rubydevro/dead_bro.git"
```

## Usage

By default, if Rails is present, DeadBro auto-subscribes to `process_action.action_controller` and posts metrics asynchronously.

### Configuration settings

You can set via an initializer:


```ruby
DeadBro.configure do |cfg|
  cfg.api_key = ENV["dead_bro_API_KEY"]
  cfg.enabled = true
end
```

## Request Sampling

DeadBro supports configurable request sampling to reduce the volume of metrics sent to your APM endpoint, which is useful for high-traffic applications.

### Configuration

Set the sample rate as a percentage (1-100):

```ruby
# Track 50% of requests
DeadBro.configure do |config|
  config.sample_rate = 50
end

# Track 10% of requests (useful for high-traffic apps)
DeadBro.configure do |config|
  config.sample_rate = 10
end

# Track all requests (default)
DeadBro.configure do |config|
  config.sample_rate = 100
end
```

### How It Works

- **Random Sampling**: Each request has a random chance of being tracked based on the sample rate
- **Consistent Per-Request**: The sampling decision is made once per request and applies to all metrics for that request
- **Debug Logging**: Skipped requests do not count towards the montly limit
- **Error Tracking**: Errors are still tracked regardless of sampling

### Use Cases

- **High-Traffic Applications**: Reduce APM data volume and costs
- **Development/Staging**: Sample fewer requests to reduce noise
- **Performance Testing**: Track a subset of requests during load testing
- **Cost Optimization**: Balance monitoring coverage with data costs


## Excluding Controllers and Jobs

You can exclude specific controllers and jobs from APM tracking.

### Configuration


```ruby
DeadBro.configure do |config|
  config.excluded_controllers = [
    "HealthChecksController",
    "Admin::*" # wildcard supported
  ]

  config.excluded_controller_actions = [
    "UsersController#show",
    "Admin::ReportsController#index",
    "Admin::*#*" # wildcard supported for controller and action
  ]

  config.excluded_jobs = [
    "ActiveStorage::AnalyzeJob",
    "Admin::*"
  ]
end
```

Notes:
- Wildcards `*` are supported for controller and action (e.g., `Admin::*#*`).
- Matching is done against full names like `UsersController`, `Admin::ReportsController#index`, `MyJob`.

## Exclusive Tracking (Whitelist Mode)

You can configure DeadBro to **only** track specific controllers, actions, or jobs. This is useful when you want to focus monitoring on a subset of your application.

### Configuration

```ruby
DeadBro.configure do |config|
  # Only track these specific controller actions
  config.exclusive_controller_actions = [
    "UsersController#show",
    "UsersController#index",
    "Admin::ReportsController#*", # all actions in this controller
    "Api::*#*" # all actions in all Api controllers
  ]

  # Only track these specific jobs
  config.exclusive_jobs = [
    "PaymentProcessingJob",
    "EmailDeliveryJob",
    "Admin::*" # all jobs in Admin namespace
  ]
end
```

### How It Works

- **If `exclusive_controller_actions` or `exclusive_jobs` is empty/not defined**: All controllers/actions/jobs are tracked (default behavior)
- **If `exclusive_controller_actions` or `exclusive_jobs` is defined with values**: Only matching controllers/actions/jobs are tracked
- **Exclusion takes precedence**: If something is in both `excluded_*` and `exclusive_*`, it will be excluded (exclusion is checked first)

### Use Cases

- **Focus on Critical Paths**: Monitor only your most important endpoints
- **Cost Optimization**: Track only specific high-value operations
- **Debugging**: Temporarily focus on specific controllers/jobs during investigation
- **Compliance**: Track only operations that require monitoring for compliance reasons

### Environment Variables

You can also configure exclusive tracking via environment variables:

```bash
# Comma-separated list of controller#action patterns
dead_bro_EXCLUSIVE_CONTROLLER_ACTIONS="UsersController#show,Admin::*#*"

# Comma-separated list of job patterns
dead_bro_EXCLUSIVE_JOBS="PaymentProcessingJob,EmailDeliveryJob"
```

## SQL Query Tracking

DeadBro automatically tracks SQL queries executed during each request and job. Each request will include a `sql_queries` array containing:
- `sql` - The SQL query (always sanitized)
- `name` - Query name (e.g., "User Load", "User Update")
- `duration_ms` - Query execution time in milliseconds
- `cached` - Whether the query was cached
- `connection_id` - Database connection ID
- `trace` - Call stack showing where the query was executed
- `explain_plan` - Query execution plan (when EXPLAIN ANALYZE is enabled, see below)

## Automatic EXPLAIN ANALYZE for Slow Queries

DeadBro can automatically run `EXPLAIN ANALYZE` on slow SQL queries to help you understand query performance and identify optimization opportunities. This feature runs in the background and doesn't block your application requests.

### How It Works

- **Automatic Detection**: When a query exceeds the configured threshold, DeadBro automatically captures its execution plan
- **Background Execution**: EXPLAIN ANALYZE runs in a separate thread using a dedicated database connection, so it never blocks your application
- **Database Support**: Works with PostgreSQL, MySQL, SQLite, and other databases
- **Smart Filtering**: Automatically skips transaction queries (BEGIN, COMMIT, ROLLBACK) and other queries that don't benefit from EXPLAIN

### Configuration

- **`explain_analyze_enabled`** (default: `false`) - Set to `true` to enable automatic EXPLAIN ANALYZE
- **`slow_query_threshold_ms`** (default: `500`) - Queries taking longer than this threshold will have their execution plan captured

### Example Configuration

```ruby
DeadBro.configure do |config|
  config.api_key = ENV['dead_bro_API_KEY']
  config.enabled = true
  
  # Enable EXPLAIN ANALYZE for queries slower than 500ms
  config.explain_analyze_enabled = true
  config.slow_query_threshold_ms = 500
  
  # Or use a higher threshold for production
  # config.slow_query_threshold_ms = 1000  # Only explain queries > 1 second
end
```

### What You Get

When a slow query is detected, the `explain_plan` field in the SQL query data will contain:
- **PostgreSQL**: Full EXPLAIN ANALYZE output with buffer usage statistics
- **MySQL**: EXPLAIN ANALYZE output showing actual execution times
- **SQLite**: EXPLAIN QUERY PLAN output
- **Other databases**: Standard EXPLAIN output

This execution plan helps you:
- Identify missing indexes
- Understand query execution order
- Spot full table scans
- Optimize JOIN operations
- Analyze buffer and cache usage (PostgreSQL)

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

### Configuration Options

```ruby
# In your Rails configuration
DeadBro.configure do |config|
  config.memory_tracking_enabled = true        # Enable lightweight memory tracking (default: true)
  config.allocation_tracking_enabled = false   # Enable detailed allocation tracking (default: false)
  
  # Sampling configuration
  config.sample_rate = 100                     # Percentage of requests to track (1-100, default: 100)
end
```

**Performance Impact:**
- **Lightweight mode**: ~0.1ms overhead per request
- **Allocation tracking**: ~2-5ms overhead per request (only enable when needed)

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


## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/rubydevro/dead_bro.
