# frozen_string_literal: true

module DeadBro
  module MemoryDetails
    # Maps Ruby internal ObjectSpace type codes to human-readable names.
    # Types omitted here are filtered out (internal noise).
    OBJECT_TYPE_NAMES = {
      T_STRING: "String",
      T_ARRAY: "Array",
      T_HASH: "Hash",
      T_OBJECT: "Object",
      T_DATA: "C Extension",
      T_CLASS: "Class",
      T_MODULE: "Module",
      T_STRUCT: "Struct",
      T_MATCH: "MatchData",
      T_REGEXP: "Regexp",
      T_SYMBOL: "Symbol",
      T_FLOAT: "Float",
      T_FILE: "File",
      T_BIGNUM: "Integer (big)"
    }.freeze

    # Noise types never shown to users.
    SKIP_TYPES = %i[FREE T_IMEMO TOTAL T_NODE T_ICLASS T_ZOMBIE T_MOVED].freeze

    def self.format_object_breakdown(deltas)
      result = {}
      deltas.each do |type, count|
        next if SKIP_TYPES.include?(type)
        next unless count.positive?
        name = OBJECT_TYPE_NAMES[type] || type.to_s.sub(/\AT_/, "")
        result[name] = count
      end
      result.sort_by { |_, v| -v }.to_h
    end

    def self.build(gc_before:, gc_after:, memory_before_mb:, memory_after_mb:,
                   object_counts_before:, object_counts_after:, large_objects:)
      memory_delta_mb = (memory_after_mb - memory_before_mb).round(2)
      gc_collections = (gc_after[:count] || 0) - (gc_before[:count] || 0)
      heap_pages_added = (gc_after[:heap_allocated_pages] || 0) - (gc_before[:heap_allocated_pages] || 0)
      new_objects = (gc_after[:total_allocated_objects] || 0) - (gc_before[:total_allocated_objects] || 0)

      raw_deltas = {}
      if object_counts_before.any? && object_counts_after.any?
        keys = (object_counts_before.keys + object_counts_after.keys).uniq
        keys.each do |k|
          diff = (object_counts_after[k] || 0) - (object_counts_before[k] || 0)
          raw_deltas[k] = diff unless diff.zero?
        end
        raw_deltas = raw_deltas.sort_by { |_, v| -v.abs }.first(20).to_h
      end

      warnings = []
      warnings << "Memory grew #{memory_delta_mb}MB — possible leak or large allocation" if memory_delta_mb > 20
      warnings << "GC ran #{gc_collections} times — many short-lived objects being created" if gc_collections > 5
      warnings << "Heap grew by #{heap_pages_added} pages — Ruby needed more memory from the OS" if heap_pages_added > 10
      warnings << "#{large_objects.length} object(s) over 1MB found in memory" if large_objects.any?

      {
        gc_collections: gc_collections,
        heap_pages_added: heap_pages_added,
        new_objects: new_objects,
        object_breakdown: format_object_breakdown(raw_deltas),
        large_objects: large_objects,
        warnings: warnings
      }
    end
  end
end
