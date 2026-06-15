# frozen_string_literal: true

# ObjectSpace.memsize_of / trace_object_allocations_* / allocation_source* all
# live in the `objspace` stdlib extension, which is NOT loaded by default.
# Requiring it only defines the methods — it does not start any tracing or add
# runtime overhead until we explicitly call trace_object_allocations_start.
begin
  require "objspace"
rescue LoadError
  # Not available on this Ruby — available? will report false.
end

module DeadBro
  # Deep, opt-in memory diagnostics that answer "what code allocated this?".
  # Only active when allocation tracking is on (see Configuration
  # #allocation_tracking_active?), because turning on object allocation tracing
  # adds ~2-5ms of per-request overhead.
  #
  # Two complementary breakdowns, both produced from a single ObjectSpace walk
  # after the request finishes:
  #
  #   * by_type_bytes — total *retained bytes* per Ruby class. This catches the
  #     "death by a million small strings" pattern (e.g. a deserialized
  #     Elasticsearch response) that MemoryTrackingSubscriber's >1MB
  #     single-object scan structurally misses, because it sums bytes per type
  #     instead of flagging individually-large objects.
  #
  #   * by_source — top allocation sites (file:line) by retained bytes. This is
  #     the gold-standard "this line allocated 300MB" attribution, available
  #     because trace_object_allocations was running for the request.
  module AllocationSourceSampler
    # Fraction of live objects inspected during the post-request walk. Reported
    # back as sample_rate so the consumer can extrapolate to the full heap.
    SAMPLE_RATE = 0.10
    MAX_RESULTS = 20
    # Only report a type if its sampled retained bytes clear this floor (keeps
    # the breakdown to things that actually matter).
    LARGE_TYPE_MIN_BYTES = 100_000
    # Skip the walk entirely below this growth — no point profiling a request
    # that didn't move memory. Gates the expensive path even when the flag is on.
    DEFAULT_MIN_GROWTH_MB = 50

    def self.available?
      defined?(ObjectSpace) &&
        ObjectSpace.respond_to?(:trace_object_allocations_start) &&
        ObjectSpace.respond_to?(:memsize_of)
    rescue StandardError
      false
    end

    # Begin recording allocation source locations. Must be called before the
    # request allocates the objects we want to attribute.
    def self.start
      return unless available?
      ObjectSpace.trace_object_allocations_start
    rescue StandardError
      # Best-effort only.
    end

    # Stop and discard recorded allocation data. Call this AFTER analyze, since
    # clearing wipes the source locations analyze reads.
    def self.stop
      return unless available?
      ObjectSpace.trace_object_allocations_stop
      ObjectSpace.trace_object_allocations_clear
    rescue StandardError
      # Best-effort only.
    end

    # Walk live objects once and build the two breakdowns. Returns {} when
    # tracing is unavailable, or {skipped: ...} when growth was below threshold.
    def self.analyze(memory_growth_mb: nil, min_growth_mb: DEFAULT_MIN_GROWTH_MB)
      return {} unless available?
      if memory_growth_mb && memory_growth_mb < min_growth_mb
        return {skipped: "memory_growth_below_threshold", min_growth_mb: min_growth_mb}
      end

      by_type = Hash.new { |h, k| h[k] = {count: 0, bytes: 0} }
      by_source = Hash.new { |h, k| h[k] = {count: 0, bytes: 0} }

      ObjectSpace.each_object do |obj|
        next unless rand < SAMPLE_RATE

        size = begin
          ObjectSpace.memsize_of(obj)
        rescue StandardError
          0
        end
        next unless size && size > 0

        klass = begin
          obj.class.name
        rescue StandardError
          nil
        end || "Unknown"
        type_bucket = by_type[klass]
        type_bucket[:count] += 1
        type_bucket[:bytes] += size

        file = begin
          ObjectSpace.allocation_sourcefile(obj)
        rescue StandardError
          nil
        end
        next unless file

        line = begin
          ObjectSpace.allocation_sourceline(obj)
        rescue StandardError
          nil
        end
        source_bucket = by_source["#{file}:#{line}"]
        source_bucket[:count] += 1
        source_bucket[:bytes] += size
      end

      {
        sample_rate: SAMPLE_RATE,
        by_type_bytes: top_by_bytes(by_type, LARGE_TYPE_MIN_BYTES),
        by_source: top_by_bytes(by_source, 0)
      }
    rescue StandardError
      {}
    end

    def self.top_by_bytes(hash, min_bytes)
      hash.select { |_, v| v[:bytes] >= min_bytes }
        .sort_by { |_, v| -v[:bytes] }
        .first(MAX_RESULTS)
        .map do |key, v|
          {
            name: key,
            count: v[:count],
            bytes: v[:bytes],
            mb: (v[:bytes] / 1_000_000.0).round(2)
          }
        end
    end
  end
end
