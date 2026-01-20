# frozen_string_literal: true

module DeadBro
  class JobQueueMonitor
    def initialize(client: DeadBro.client)
      @client = client
      @thread = nil
      @running = false
    end

    def start
      return if @running
      return unless DeadBro.configuration.job_queue_monitoring_enabled
      return unless DeadBro.configuration.enabled

      @running = true
      @thread = Thread.new do
        Thread.current.abort_on_exception = false
        loop do
          break unless @running

          begin
            stats = collect_queue_stats
            @client.post_job_stats(stats) if stats
          rescue => e
            log_error("Error collecting job queue stats: #{e.message}")
          end

          # Sleep for 60 seconds (1 minute)
          sleep(120)
        end
      end

      @thread
    end

    def stop
      @running = false
      @thread&.join(5) # Wait up to 5 seconds for thread to finish
      @thread = nil
    end

    private

    def collect_queue_stats
      stats = {
        timestamp: Time.now.utc.iso8601,
        queue_system: detect_queue_system,
        environment: Rails.env,
        queues: {}
      }

      case stats[:queue_system]
      when :sidekiq
        stats[:queues] = collect_sidekiq_stats
      when :solid_queue
        stats[:queues] = collect_solid_queue_stats
      when :delayed_job
        stats[:queues] = collect_delayed_job_stats
      when :good_job
        stats[:queues] = collect_good_job_stats
      else
        return nil # Unknown queue system, don't send stats
      end

      stats
    end

    def detect_queue_system
      return :sidekiq if defined?(Sidekiq)
      return :solid_queue if defined?(SolidQueue)
      return :delayed_job if defined?(Delayed::Job)
      return :good_job if defined?(GoodJob)
      :unknown
    end

    def collect_sidekiq_stats
      return {} unless defined?(Sidekiq)

      stats = {
        total_queued: 0,
        total_busy: 0,
        queues: {}
      }

      begin
        # Get queue sizes - try to access Queue class (will trigger autoload if needed)
        begin
          queue_class = Sidekiq.const_get(:Queue)
          if queue_class.respond_to?(:all)
            queue_class.all.each do |queue|
              queue_name = queue.name
              size = queue.size
              stats[:queues][queue_name] = {
                queued: size,
                busy: 0,
                scheduled: 0,
                retries: 0
              }
              stats[:total_queued] += size
            end
          end
        rescue NameError => e
          log_error("Sidekiq::Queue not available: #{e.message}")
        rescue => e
          log_error("Error accessing Sidekiq::Queue: #{e.message}")
        end

        # Get busy workers
        begin
          workers_class = Sidekiq.const_get(:Workers)
          workers = workers_class.new
          workers.each do |process_id, thread_id, work|
            next unless work
            queue_name = work["queue"] || "default"
            stats[:queues][queue_name] ||= { queued: 0, busy: 0, scheduled: 0, retries: 0 }
            stats[:queues][queue_name][:busy] += 1
            stats[:total_busy] += 1
          end
        rescue NameError
          # Workers class not available, try fallback
          if Sidekiq.respond_to?(:workers)
            # Fallback for older Sidekiq versions
            begin
              workers = Sidekiq.workers
              if workers.respond_to?(:each)
                workers.each do |worker|
                  queue_name = worker.respond_to?(:queue) ? worker.queue : "default"
                  stats[:queues][queue_name] ||= { queued: 0, busy: 0, scheduled: 0, retries: 0 }
                  stats[:queues][queue_name][:busy] += 1
                  stats[:total_busy] += 1
                end
              end
            rescue => e
              log_error("Error getting Sidekiq workers (fallback): #{e.message}")
            end
          end
        rescue => e
          log_error("Error getting Sidekiq workers: #{e.message}")
        end

        # Get scheduled jobs
        begin
          scheduled_set_class = Sidekiq.const_get(:ScheduledSet)
          scheduled_set = scheduled_set_class.new
          stats[:total_scheduled] = scheduled_set.size
        rescue NameError
          # ScheduledSet not available, skip
        rescue => e
          log_error("Error getting Sidekiq scheduled jobs: #{e.message}")
        end

        # Get retries
        begin
          retry_set_class = Sidekiq.const_get(:RetrySet)
          retry_set = retry_set_class.new
          stats[:total_retries] = retry_set.size
        rescue NameError
          # RetrySet not available, skip
        rescue => e
          log_error("Error getting Sidekiq retries: #{e.message}")
        end

        # Get dead jobs
        begin
          dead_set_class = Sidekiq.const_get(:DeadSet)
          dead_set = dead_set_class.new
          stats[:total_dead] = dead_set.size
        rescue NameError
          # DeadSet not available, skip
        rescue => e
          log_error("Error getting Sidekiq dead jobs: #{e.message}")
        end

        # Get process info
        begin
          process_set_class = Sidekiq.const_get(:ProcessSet)
          process_set = process_set_class.new
          stats[:processes] = process_set.size
        rescue NameError
          # ProcessSet not available, skip
        rescue => e
          log_error("Error getting Sidekiq processes: #{e.message}")
        end
      rescue => e
        log_error("Error collecting Sidekiq stats: #{e.message}")
        log_error("Backtrace: #{e.backtrace.first(5).join("\n")}")
      end

      stats
    end

    def collect_solid_queue_stats
      return {} unless defined?(SolidQueue)

      stats = {
        total_queued: 0,
        total_busy: 0,
        queues: {}
      }

      begin
        # Solid Queue uses ActiveJob and stores jobs in a database table
        if defined?(ActiveRecord) && ActiveRecord::Base.connected? && ActiveRecord::Base.connection.table_exists?("solid_queue_jobs")
          # Get queued jobs grouped by queue
          result = ActiveRecord::Base.connection.execute(
            "SELECT queue_name, COUNT(*) as count FROM solid_queue_jobs WHERE finished_at IS NULL GROUP BY queue_name"
          )

          parse_query_result(result).each do |row|
            queue_name = (row["queue_name"] || row[:queue_name] || "default").to_s
            count = (row["count"] || row[:count] || 0).to_i
            stats[:queues][queue_name] = {
              queued: count,
              busy: 0,
              scheduled: 0,
              retries: 0
            }
            stats[:total_queued] += count
          end

          # Get busy jobs (claimed but not finished)
          result = ActiveRecord::Base.connection.execute(
            "SELECT queue_name, COUNT(*) as count FROM solid_queue_jobs WHERE finished_at IS NULL AND claimed_at IS NOT NULL GROUP BY queue_name"
          )

          parse_query_result(result).each do |row|
            queue_name = (row["queue_name"] || row[:queue_name] || "default").to_s
            count = (row["count"] || row[:count] || 0).to_i
            stats[:queues][queue_name] ||= { queued: 0, busy: 0, scheduled: 0, retries: 0 }
            stats[:queues][queue_name][:busy] = count
            stats[:total_busy] += count
          end

          # Get scheduled jobs
          result = ActiveRecord::Base.connection.execute(
            "SELECT COUNT(*) as count FROM solid_queue_jobs WHERE scheduled_at > NOW()"
          )
          scheduled_count = parse_query_result(result).first
          stats[:total_scheduled] = (scheduled_count&.dig("count") || scheduled_count&.dig(:count) || 0).to_i

          # Get failed jobs
          if ActiveRecord::Base.connection.table_exists?("solid_queue_failed_jobs")
            result = ActiveRecord::Base.connection.execute(
              "SELECT COUNT(*) as count FROM solid_queue_failed_jobs"
            )
            failed_count = parse_query_result(result).first
            stats[:total_failed] = (failed_count&.dig("count") || failed_count&.dig(:count) || 0).to_i
          end
        end
      rescue => e
        log_error("Error collecting Solid Queue stats: #{e.message}")
      end

      stats
    end

    def collect_delayed_job_stats
      return {} unless defined?(Delayed::Job)

      stats = {
        total_queued: 0,
        total_busy: 0,
        queues: {}
      }

      begin
        # Delayed Job uses a single table
        if defined?(ActiveRecord) && ActiveRecord::Base.connected? && ActiveRecord::Base.connection.table_exists?("delayed_jobs")
          # Get queued jobs
          queued = Delayed::Job.where("locked_at IS NULL AND attempts < max_attempts").count
          stats[:total_queued] = queued
          stats[:queues]["default"] = {
            queued: queued,
            busy: 0,
            scheduled: 0,
            retries: 0
          }

          # Get busy jobs (locked)
          busy = Delayed::Job.where("locked_at IS NOT NULL AND locked_by IS NOT NULL").count
          stats[:total_busy] = busy
          stats[:queues]["default"][:busy] = busy

          # Get failed jobs
          failed = Delayed::Job.where("attempts >= max_attempts").count
          stats[:total_failed] = failed
        end
      rescue => e
        log_error("Error collecting Delayed Job stats: #{e.message}")
      end

      stats
    end

    def collect_good_job_stats
      return {} unless defined?(GoodJob)

      stats = {
        total_queued: 0,
        total_busy: 0,
        queues: {}
      }

      begin
        # Good Job uses ActiveJob and stores jobs in a database table
        if defined?(ActiveRecord) && ActiveRecord::Base.connected? && ActiveRecord::Base.connection.table_exists?("good_jobs")
          # Get queued jobs grouped by queue
          result = ActiveRecord::Base.connection.execute(
            "SELECT queue_name, COUNT(*) as count FROM good_jobs WHERE finished_at IS NULL GROUP BY queue_name"
          )

          parse_query_result(result).each do |row|
            queue_name = (row["queue_name"] || row[:queue_name] || "default").to_s
            count = (row["count"] || row[:count] || 0).to_i
            stats[:queues][queue_name] = {
              queued: count,
              busy: 0,
              scheduled: 0,
              retries: 0
            }
            stats[:total_queued] += count
          end

          # Get busy jobs (running)
          result = ActiveRecord::Base.connection.execute(
            "SELECT queue_name, COUNT(*) as count FROM good_jobs WHERE finished_at IS NULL AND performed_at IS NOT NULL GROUP BY queue_name"
          )

          parse_query_result(result).each do |row|
            queue_name = (row["queue_name"] || row[:queue_name] || "default").to_s
            count = (row["count"] || row[:count] || 0).to_i
            stats[:queues][queue_name] ||= { queued: 0, busy: 0, scheduled: 0, retries: 0 }
            stats[:queues][queue_name][:busy] = count
            stats[:total_busy] += count
          end

          # Get scheduled jobs
          result = ActiveRecord::Base.connection.execute(
            "SELECT COUNT(*) as count FROM good_jobs WHERE scheduled_at > NOW()"
          )
          scheduled_count = parse_query_result(result).first
          stats[:total_scheduled] = (scheduled_count&.dig("count") || scheduled_count&.dig(:count) || 0).to_i

          # Get failed jobs
          result = ActiveRecord::Base.connection.execute(
            "SELECT COUNT(*) as count FROM good_jobs WHERE finished_at IS NOT NULL AND error IS NOT NULL"
          )
          failed_count = parse_query_result(result).first
          stats[:total_failed] = (failed_count&.dig("count") || failed_count&.dig(:count) || 0).to_i
        end
      rescue => e
        log_error("Error collecting Good Job stats: #{e.message}")
      end

      stats
    end

    def parse_query_result(result)
      # Handle different database adapter result formats
      if result.respond_to?(:each)
        # PostgreSQL PG::Result or similar
        if result.respond_to?(:values)
          # Convert to array of hashes
          columns = result.fields rescue result.column_names rescue []
          result.values.map do |row|
            columns.each_with_index.each_with_object({}) do |(col, idx), hash|
              hash[col.to_s] = row[idx]
              hash[col.to_sym] = row[idx]
            end
          end
        elsif result.is_a?(Array)
          # Already an array
          result
        else
          # Try to convert to array
          result.to_a
        end
      else
        []
      end
    rescue => e
      log_error("Error parsing query result: #{e.message}")
      []
    end

    def log_error(message)
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger.error("[DeadBro::JobQueueMonitor] #{message}")
      else
        $stderr.puts("[DeadBro::JobQueueMonitor] #{message}")
      end
    end
  end
end
