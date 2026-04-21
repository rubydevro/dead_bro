# frozen_string_literal: true

require "thread"

module DeadBro
  # Background worker pool that runs HTTP posts for Client off the request
  # thread. Replaces the previous `Thread.new` per metric. One shared pool per
  # process; re-initializes after fork (Puma, Unicorn).
  class Dispatcher
    DEFAULT_QUEUE_SIZE = 500
    DEFAULT_WORKERS = 2
    SHUTDOWN = Object.new

    class << self
      def instance
        @instance ||= new
      end

      # Exposed for tests.
      def reset!
        @instance&.shutdown
        @instance = nil
      end

      # Test hook — when true, `dispatch` runs the block inline on the caller
      # thread instead of handing it to a worker. Keeps specs deterministic
      # without having to stub `Thread.new` or poll for queue drain.
      attr_accessor :inline
    end

    def initialize(queue_size: DEFAULT_QUEUE_SIZE, workers: DEFAULT_WORKERS)
      @queue_size = queue_size
      @worker_count = workers
      @mutex = Mutex.new
      @dropped = 0
      @shutting_down = false
      boot_workers(Process.pid)
      install_at_exit_hook
    end

    # Schedule a block for background execution. Never blocks the caller: if the
    # queue is full the job is dropped and `dropped_count` is incremented.
    def dispatch(&block)
      return false unless block_given?
      return false if @shutting_down

      if self.class.inline
        begin
          block.call
        rescue
          # Match worker semantics — swallow job errors.
        end
        return true
      end

      ensure_workers_alive!
      @queue.push(block, true) # non-blocking
      true
    rescue ThreadError
      @mutex.synchronize { @dropped += 1 }
      false
    end

    def dropped_count
      @mutex.synchronize { @dropped }
    end

    def shutdown
      return if @shutting_down
      @shutting_down = true
      workers = @workers || []
      workers.length.times do
        begin
          @queue.push(SHUTDOWN)
        rescue
        end
      end
      workers.each do |t|
        begin
          t.join(2)
        rescue
        end
      end
    end

    private

    def boot_workers(pid)
      @pid = pid
      @queue = SizedQueue.new(@queue_size)
      @workers = Array.new(@worker_count) do
        t = Thread.new { run }
        begin
          t.name = "dead_bro-dispatcher"
        rescue
        end
        t.abort_on_exception = false
        t
      end
    end

    def ensure_workers_alive!
      return if @pid == Process.pid && @workers && @workers.all?(&:alive?)

      @mutex.synchronize do
        return if @pid == Process.pid && @workers && @workers.all?(&:alive?)
        # Post-fork (new PID) or a worker died — bring up a fresh pool.
        boot_workers(Process.pid)
        @shutting_down = false
      end
    end

    def install_at_exit_hook
      at_exit { shutdown }
    rescue
    end

    def run
      loop do
        job = @queue.pop
        break if job.equal?(SHUTDOWN)
        begin
          job.call
        rescue
          # Never let a job crash the worker.
        end
      end
    end
  end
end
