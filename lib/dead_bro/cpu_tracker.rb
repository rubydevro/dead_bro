# frozen_string_literal: true

module DeadBro
  module CpuTracker
    THREAD_KEY = :dead_bro_cpu_start

    def self.start_request_tracking
      Thread.current[THREAD_KEY] = thread_cpu_ms
    end

    def self.stop_request_tracking
      before = Thread.current[THREAD_KEY]
      return nil if before.nil?
      after = thread_cpu_ms
      return nil if after.nil?
      (after - before).round(2)
    ensure
      Thread.current[THREAD_KEY] = nil
    end

    def self.thread_cpu_ms
      Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID, :millisecond)
    rescue
      nil
    end
  end
end
