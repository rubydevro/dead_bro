# frozen_string_literal: true

module DeadBro
  # The per-request event Arrays of the cache, Redis, Elasticsearch and
  # outgoing-HTTP trackers. Most requests record none of some of these, so a
  # buffer that stays empty isn't handed to the payload: stop returns NONE and
  # parks the empty Array on the thread for the next request's start, which
  # then allocates nothing for it.
  module EventBuffer
    NONE = [].freeze
    # Thread-local key of each buffer's parked Array, built once per key.
    SPARE_KEYS = Hash.new { |keys, key| keys[key] = :"#{key}_spare" }

    module_function

    def start(key)
      spare = SPARE_KEYS[key]
      Thread.current[key] = Thread.current[spare] || []
      Thread.current[spare] = nil
    end

    # The request's events (NONE if it recorded none); tracking for key stops.
    def stop(key)
      events = Thread.current[key]
      Thread.current[key] = nil
      return NONE if events.nil?
      return events unless events.empty?

      Thread.current[SPARE_KEYS[key]] = events
      NONE
    end
  end
end
