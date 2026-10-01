# frozen_string_literal: true

module DeadBro
  # Sidekiq server middleware for jobs that include Sidekiq::Job directly. They
  # never go through ActiveJob, so JobSubscriber's perform.active_job never fires
  # for them and their runs — successful or not — went unreported. ActiveJob jobs
  # that Sidekiq runs arrive wrapped (job["wrapped"] names the real class) and are
  # left to JobSubscriber, so no run is reported twice.
  class SidekiqServerMiddleware
    EVENT_NAME = "perform.sidekiq"

    def self.install!
      return unless defined?(::Sidekiq) && ::Sidekiq.respond_to?(:configure_server)

      # Runs its block only in the Sidekiq server process.
      ::Sidekiq.configure_server do |config|
        config.server_middleware { |chain| chain.add(DeadBro::SidekiqServerMiddleware) }
      end
    rescue
      # Never raise from instrumentation install
    end

    def call(_job_instance, job, queue)
      # Disabled, Client#post_metric would drop the payload anyway.
      return yield if job["wrapped"] || !DeadBro.configuration.enabled

      started = Time.now
      DeadBro::JobSubscriber.start_job_tracking
      exception = nil
      begin
        yield
      rescue Exception => e # recorded, then re-raised untouched
        exception = e
        raise
      ensure
        report(job, queue, started, exception)
      end
    end

    private

    def report(job, queue, started, exception)
      DeadBro::JobSubscriber.report_job(
        client: DeadBro.client,
        event_name: EVENT_NAME,
        job_class_name: job["class"].to_s,
        job_id: job["jid"],
        queue_name: queue || job["queue"],
        arguments: job["args"],
        enqueued_at: job["enqueued_at"],
        started: started,
        finished: Time.now,
        exception: exception
      )
    rescue
      # Never raise into the job, nor mask its own exception
    end
  end
end
