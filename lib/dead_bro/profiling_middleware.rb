# frozen_string_literal: true

module DeadBro
  # Starts the stackprof sampling profiler for requests selected by
  # Configuration#profile_active? and wraps controller execution. The profile is
  # stopped + collected by the process_action subscriber (so its boundary lines
  # up with controller + view rendering, like the other request trackers); this
  # middleware only starts it and acts as a safety net for requests that never
  # reach a controller (assets, early 404s, errors) so the global profiler is
  # never left running across requests on a reused thread.
  class ProfilingMiddleware
    def initialize(app)
      @app = app
    end

    def call(env)
      started = false

      begin
        if !DeadBro.configuration.skip_tracking? && DeadBro.configuration.profile_active?
          mode = DeadBro::Profiler.pick_mode
          started = DeadBro::Profiler.start(mode)
          Thread.current[DeadBro::Profiler::MODE_KEY] = mode if started
        end
      rescue
        # Never let profiler setup interfere with the request.
        started = false
      end

      @app.call(env)
    ensure
      # If the subscriber already collected the profile, MODE_KEY is cleared and
      # this is a no-op. Otherwise (no process_action fired) discard it here.
      if started && Thread.current[DeadBro::Profiler::MODE_KEY]
        DeadBro::Profiler.discard
      end
    end
  end
end
