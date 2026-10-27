# frozen_string_literal: true

module DeadBro
  # Builds a web request's span tree: every span gets an id and the id of the
  # span it ran inside (parent_id), so the dashboard can nest the Request Trace
  # and show each span's total (inclusive) and self (exclusive) time.
  #
  # Nodes are kept for the spans other spans run inside — Rack middleware and
  # the router (MiddlewareProbe), the controller action, view renders,
  # DeadBro.watch blocks and the block a Rails.cache.fetch miss runs — and for
  # SQL queries, and are sent as the request's `spans`. Repeated calls on the
  # same path share one node: a partial rendered 50 times inside one template
  # is one node with count 50, and the query it runs each time is one child
  # node with count 50. Cache, Redis, HTTP, Elasticsearch and transaction
  # events stay in their own lists and carry the parent_id of the span they
  # ran inside; the cache event of a fetch block carries its node's span_id.
  #
  # Node fields: id, parent_id (nil at the top), kind (middleware, endpoint,
  # action, view, watch, cache, sql), name, count, total_ms — the summed
  # duration of the node's calls, nested spans included — and start_ms /
  # end_ms — the first call's start and the last call's end, as offsets from
  # the tracking start like every other start_offset_ms. View nodes add type
  # (template, layout, partial, collection) and cache nodes type generate;
  # SQL nodes carry ref, the id of their sql_queries entry, instead of a name.
  #
  # The middleware chain returns after the controller action has finished, so
  # a request that runs inside it has its payload held until the outermost
  # middleware returns (see .post), and is sent with the middleware spans. If
  # that middleware never returns through its probe, the payload is sent when
  # the thread's next request comes in (see .rack_enter).
  #
  # The tree belongs to the thread that runs the request. ActionController::Live
  # runs the action on a thread of its own, with the request thread's locals
  # copied over; that thread records the action in a tree of its own (see
  # .live_context).
  module SpanTracker
    THREAD_KEY = :dead_bro_span_context

    # Nodes kept per request; past it, a span's time stays in its parent's self
    # time and the request's spans_dropped counts what was left out.
    MAX_NODES = 500
    # Middleware/router frames kept per request (a Rails stack has ~25).
    MAX_RACK_FRAMES = 200
    # Payloads held for one middleware chain: the request's own, and the
    # exceptions app's when Rails dispatches an error to it. Past this a
    # payload is sent right away.
    MAX_PENDING = 10

    MIDDLEWARE = "middleware"
    ENDPOINT = "endpoint"
    ACTION = "action"
    VIEW = "view"
    WATCH = "watch"
    CACHE = "cache"
    SQL = "sql"

    # Frame pushed for a span past MAX_NODES, so leaving it still pops the
    # right frame.
    DROPPED_VIEW = {kind: VIEW}.freeze
    DROPPED_WATCH = {kind: WATCH}.freeze
    DROPPED_CACHE = {kind: CACHE}.freeze

    # Rails.cache.fetch runs its block inside this event when the key misses.
    CACHE_GENERATE_EVENT = "cache_generate.active_support"
    # Fetch blocks whose keys differ only in their digits share a node.
    CACHE_KEY_DIGITS = /\d+/

    VIEW_EVENTS = {
      "render_layout.action_view" => "layout",
      "render_template.action_view" => "template",
      "render_partial.action_view" => "partial",
      "render_collection.action_view" => "collection"
    }.freeze

    # One request's tree, reused by the thread's next request.
    class Context
      attr_reader :nodes, :dropped, :thread
      attr_accessor :pending

      def initialize
        # The thread this tree is recorded on. Another thread holding this
        # context (ActionController::Live copies the request thread's locals)
        # records nothing into it.
        @thread = Thread.current
        # Open spans inside the middleware chain, innermost last: a node Hash
        # or a DROPPED_* marker. The ids are what starts now gets as
        # parent_id; the starts are Float seconds (CLOCK_REALTIME, the clock
        # behind every other offset in the payload).
        @frames = []
        @frame_ids = []
        @frame_starts = []
        # parent_id => {key => node}, per kind, so repeat calls on a path find
        # their node.
        @view_index = {}
        @watch_index = {}
        @cache_index = {}
        @sql_index = {}
        # Each fetch block's event payload => its node, for CacheSubscriber,
        # whose listener for the same event may run before or after ours.
        @cache_payloads = {}.compare_by_identity
        # Middleware frames, as parallel arrays: the chain runs on every
        # request, so recording it allocates nothing. Frame i is span i + 1
        # (the other spans are numbered after MAX_RACK_FRAMES); @rack_current
        # is the innermost open one and @rack_parents each one's enclosing
        # frame.
        @rack_probes = []
        @rack_parents = []
        @rack_starts = []
        @rack_ends = []
        reset
      end

      def reset
        # A new Array: the last one may still be in a payload waiting to be sent.
        @nodes = []
        @frames.clear
        @frame_ids.clear
        @frame_starts.clear
        @view_index.clear
        @watch_index.clear
        @cache_index.clear
        @sql_index.clear
        @cache_payloads.clear
        @rack_probes.clear
        @rack_parents.clear
        @rack_starts.clear
        @rack_ends.clear
        @rack_current = nil
        @next_id = MAX_RACK_FRAMES
        @base = nil
        @tracking = false
        @recording_rack = false
        @action = nil
        @pending = nil
        @dropped = 0
        @finalized = false
      end

      def tracking?
        @tracking
      end

      def idle?
        @frames.empty? && @pending.nil? && !rack_open?
      end

      # Left over from a request whose outermost middleware never returned
      # through its probe — an exception raised into the thread from outside
      # the Rails stack (an outer timeout) while the probe opened or closed its
      # frame: nothing is open or running, or the outermost probe is entered
      # again while its own frame still is.
      def abandoned?(probe)
        return false if idle?

        (@rack_current.nil? && @frames.empty?) || (@rack_current == 0 && @rack_probes[0].equal?(probe))
      end

      def current_id
        @frame_ids.last || (@rack_current && @rack_current + 1)
      end

      # The tracking start (TRACKING_START_TIME_KEY), which every offset is
      # measured from.
      def start_tracking(base)
        @base = base
        @tracking = true
      end

      def stop_tracking
        @tracking = false
      end

      # True while the outermost middleware hasn't returned yet.
      def rack_open?
        !@rack_ends.empty? && @rack_ends[0].nil?
      end

      def start_rack
        @recording_rack = true
      end

      # A Rack app called from inside the action isn't recorded: middleware
      # frames are the outermost spans.
      def rack_enter(probe, now)
        return nil unless @recording_rack && @frames.empty?

        i = @rack_probes.size
        return nil if i >= MAX_RACK_FRAMES

        @rack_probes << probe
        @rack_parents << @rack_current
        @rack_starts << now
        @rack_ends << nil
        @rack_current = i
        i
      end

      def rack_leave(i, now)
        @rack_ends[i] = now
        @rack_current = @rack_parents[i]
        # Anything still open inside it never finished.
        pop_to(0) unless @frames.empty?
      end

      def enter_action(now)
        node = new_node(ACTION, current_id)
        return nil unless node

        @action = node
        push(node, node[:id], now)
        node
      end

      # Closed with the times process_action reports, which every listener of
      # the event sees, rather than when this listener happens to run.
      def finish_action(started, finished)
        j = innermost(ACTION)
        return unless j

        node = @frames[j]
        pop_to(j)
        add_call(node, started, finished)
      end

      def enter_view(identifier, type, now)
        key = identifier || type
        node = node_for(VIEW, @view_index, key) do |created|
          created[:name] = DeadBro::ViewRenderingSubscriber.safe_identifier(identifier)
          created[:type] = type
        end
        push(node || DROPPED_VIEW, node ? node[:id] : current_id, now)
      end

      def leave_view(now)
        j = innermost(VIEW)
        leave_frame(j, now) if j
      end

      def enter_watch(label, now)
        node = node_for(WATCH, @watch_index, label) { |created| created[:name] = label }
        frame = node || DROPPED_WATCH
        push(frame, node ? node[:id] : current_id, now)
        frame
      end

      def leave_watch(frame, now)
        j = @frames.size - 1
        j -= 1 while j >= 0 && !@frames[j].equal?(frame)
        leave_frame(j, now) if j >= 0
      end

      # A Rails.cache.fetch miss: the block it runs nests in this span. Keys
      # that differ only in their digits share a node, named by that pattern.
      def enter_cache_generate(payload, key, now)
        pattern = key.gsub(CACHE_KEY_DIGITS, "?")
        node = node_for(CACHE, @cache_index, pattern) do |created|
          created[:name] = key
          created[:type] = "generate"
        end
        if node
          node[:name] = pattern unless node[:name] == key
          @cache_payloads[payload] = node
        end
        push(node || DROPPED_CACHE, node ? node[:id] : current_id, now)
      end

      def leave_cache_generate(now)
        j = innermost(CACHE)
        leave_frame(j, now) if j
      end

      def cache_node(payload)
        @cache_payloads[payload]
      end

      def sql(key, ref, started, finished)
        node = node_for(SQL, @sql_index, key) { |created| created[:ref] = ref }
        add_call(node, started, finished) if node
      end

      # Rounds the totals and turns the middleware frames into nodes. Once per
      # request, right before the payload is sent.
      def finalize(action_name)
        return if @finalized || @base.nil?

        @finalized = true
        @action[:name] ||= action_name if @action
        @nodes.each { |node| node[:total_ms] = node[:total_ms].round(3) }
        @rack_probes.each_with_index do |probe, i|
          start = @rack_starts[i]
          finish = @rack_ends[i] || open_frame_end(start)
          parent = @rack_parents[i]
          @nodes << {
            id: i + 1,
            parent_id: parent && parent + 1,
            kind: probe.span_kind,
            name: probe.span_name,
            count: 1,
            total_ms: ((finish - start) * 1000.0).round(3),
            start_ms: offset_ms(start),
            end_ms: offset_ms(finish)
          }
        end
      end

      private

      def push(frame, id, now)
        @frames << frame
        @frame_ids << id
        @frame_starts << now
      end

      # Pops frame j and every frame still open inside it.
      def pop_to(j)
        (@frames.size - j).times do
          @frames.pop
          @frame_ids.pop
          @frame_starts.pop
        end
      end

      # The innermost open frame of a kind (a node or a DROPPED_* marker).
      # A loop rather than rindex with a block, which allocates.
      def innermost(kind)
        j = @frames.size - 1
        while j >= 0
          frame = @frames[j]
          return j if frame.is_a?(Hash) && frame[:kind] == kind

          j -= 1
        end
        nil
      end

      def leave_frame(j, now)
        frame = @frames[j]
        start = @frame_starts[j]
        pop_to(j)
        add_call(frame, start, now) unless frame.frozen?
      end

      # The node for key under the innermost open span, created on first use;
      # nil past MAX_NODES.
      def node_for(kind, index, key)
        parent_id = current_id
        by_key = (index[parent_id] ||= {})
        node = by_key[key]
        return node if node

        node = new_node(kind, parent_id)
        return nil unless node

        yield node
        by_key[key] = node
      end

      def new_node(kind, parent_id)
        if @nodes.size >= MAX_NODES
          @dropped += 1
          return nil
        end

        node = {id: (@next_id += 1), parent_id: parent_id, kind: kind, count: 0, total_ms: 0.0, start_ms: nil, end_ms: nil}
        @nodes << node
        node
      end

      def add_call(node, started, finished)
        node[:count] += 1
        node[:total_ms] += (finished - started) * 1000.0
        node[:start_ms] ||= offset_ms(started)
        node[:end_ms] = offset_ms(finished)
      end

      def offset_ms(time)
        ((time - @base) * 1000.0).round(3)
      end

      # A frame sent while still open (its middleware never returned through
      # the probe) ends where the last frame that did close ended.
      def open_frame_end(start)
        finish = start
        @rack_ends.each { |time| finish = time if time && time > finish }
        finish
      end
    end

    # Pushes and pops the view spans; start/finish listeners, so a view's
    # children see it as their parent while it renders.
    class ViewListener
      def initialize(type)
        @type = type
      end

      def start(_name, _id, payload)
        SpanTracker.enter_view(payload[:identifier], @type)
      end

      def finish(_name, _id, _payload)
        SpanTracker.leave_view
      end
    end

    # start_processing.action_controller fires right before
    # process_action.action_controller starts: the action span opens here and
    # Subscriber closes it.
    class ActionListener
      def start(_name, _id, _payload)
        SpanTracker.enter_action
      end

      def finish(_name, _id, _payload)
      end
    end

    # cache_generate wraps the block of a Rails.cache.fetch miss, so what the
    # block runs nests in its span instead of sitting next to it.
    class CacheGenerateListener
      def start(_name, _id, payload)
        SpanTracker.enter_cache_generate(payload)
      end

      def finish(_name, _id, _payload)
        SpanTracker.leave_cache_generate
      end
    end

    module_function

    def subscribe!
      return unless defined?(ActiveSupport::Notifications)

      VIEW_EVENTS.each do |event_name, type|
        ActiveSupport::Notifications.subscribe(event_name, ViewListener.new(type))
      end
      ActiveSupport::Notifications.subscribe("start_processing.action_controller", ActionListener.new)
      ActiveSupport::Notifications.subscribe(CACHE_GENERATE_EVENT, CacheGenerateListener.new)
    rescue
      # Never raise from instrumentation install
    end

    def now
      Process.clock_gettime(Process::CLOCK_REALTIME)
    end

    # This thread's context, created on first use — and in place of one
    # copied from another thread.
    def context
      own_context || (Thread.current[THREAD_KEY] = Context.new)
    end

    def own_context
      ctx = Thread.current[THREAD_KEY]
      ctx if ctx && ctx.thread.equal?(Thread.current)
    end

    # The context of a request being tracked on this thread, else nil.
    def tracking_context
      ctx = own_context
      ctx if ctx&.tracking?
    end

    # ActionController::Live runs the action on a thread of its own, with the
    # request thread's locals copied over — that thread's context and the
    # tracking start among them. The request thread leaves the middleware
    # chain once the response is committed, while the action may still run,
    # so the action thread records the action in a context of its own,
    # measured from the same tracking start. Nil anywhere else.
    def live_context
      copied = Thread.current[THREAD_KEY]
      return nil if copied.nil? || copied.thread.equal?(Thread.current)

      tracking_start = Thread.current[DeadBro::TRACKING_START_TIME_KEY]
      return nil unless tracking_start

      ctx = Thread.current[THREAD_KEY] = Context.new
      ctx.start_tracking(tracking_start.to_f)
      ctx
    end

    # The id of the span running now — the parent_id of an event recorded now.
    def current_id
      tracking_context&.current_id
    end

    # Called by SqlTrackingMiddleware once tracking is set up. Without
    # MiddlewareProbe frames around it (no Rails middleware stack) the request
    # starts here.
    def start_request(tracking_start)
      ctx = context
      ctx.reset if ctx.idle?
      ctx.start_tracking(tracking_start.to_f)
    rescue *DeadBro::CONTAINED_ERRORS
    end

    def stop_request
      own_context&.stop_tracking
    rescue *DeadBro::CONTAINED_ERRORS
    end

    # Returns a frame token for rack_leave, or nil when nothing is recorded.
    def rack_enter(probe)
      config = DeadBro.configuration
      return nil unless config.enabled

      ctx = own_context
      if ctx&.abandoned?(probe)
        # Send what the abandoned request held, and start over — also while
        # the dashboard has middleware spans off, so it doesn't linger.
        begin
          flush(ctx)
        ensure
          ctx.reset
        end
      end
      return nil unless config.middleware_spans_active?

      ctx ||= context
      if ctx.idle?
        ctx.reset
        ctx.start_rack
      end
      ctx.rack_enter(probe, now)
    rescue *DeadBro::CONTAINED_ERRORS
      nil
    end

    # Leaving the outermost frame (0) sends the payloads held for it.
    def rack_leave(frame)
      ctx = own_context
      return unless ctx

      ctx.rack_leave(frame, now)
      return unless frame == 0

      begin
        flush(ctx)
      ensure
        ctx.reset
      end
    rescue *DeadBro::CONTAINED_ERRORS
    end

    def enter_action
      (tracking_context || live_context)&.enter_action(now)
    rescue *DeadBro::CONTAINED_ERRORS
    end

    def finish_action(started, finished)
      tracking_context&.finish_action(started.to_f, finished.to_f)
    rescue *DeadBro::CONTAINED_ERRORS
    end

    def enter_view(identifier, type)
      tracking_context&.enter_view(identifier, type, now)
    rescue *DeadBro::CONTAINED_ERRORS
    end

    def leave_view
      tracking_context&.leave_view(now)
    rescue *DeadBro::CONTAINED_ERRORS
    end

    # Returns the frame to pass to leave_watch, nil when not tracking.
    def enter_watch(label)
      tracking_context&.enter_watch(label, now)
    rescue *DeadBro::CONTAINED_ERRORS
      nil
    end

    def leave_watch(frame)
      return unless frame

      tracking_context&.leave_watch(frame, now)
    rescue *DeadBro::CONTAINED_ERRORS
    end

    def enter_cache_generate(payload)
      ctx = tracking_context
      return unless ctx

      key = defined?(DeadBro::CacheSubscriber) ? DeadBro::CacheSubscriber.safe_key(payload[:key]) : payload[:key]
      ctx.enter_cache_generate(payload, key.to_s, now)
    rescue *DeadBro::CONTAINED_ERRORS
    end

    def leave_cache_generate
      tracking_context&.leave_cache_generate(now)
    rescue *DeadBro::CONTAINED_ERRORS
    end

    # The node of a fetch block's cache_generate event, by the event's
    # payload; nil for every other event.
    def cache_node(payload)
      tracking_context&.cache_node(payload)
    rescue *DeadBro::CONTAINED_ERRORS
      nil
    end

    # A query of the request's own SQL tracking (sql_depth 1: an inline job's
    # queries go to the job's payload, whose sql_queries ids are its own).
    def sql(key, ref, started, finished, sql_depth)
      return unless sql_depth == 1

      tracking_context&.sql(key, ref, started.to_f, finished.to_f)
    rescue *DeadBro::CONTAINED_ERRORS
    end

    # The request's nodes for the payload (finished by .post), or nil when the
    # request isn't being tracked — e.g. the exceptions app Rails dispatches to
    # after DeadBro's middleware has returned, whose context still holds the
    # failed request's tree.
    def payload_spans
      ctx = tracking_context
      return nil unless ctx && !ctx.nodes.empty?

      ctx.nodes
    end

    def payload_spans_dropped
      ctx = tracking_context
      ctx.dropped if ctx && ctx.dropped > 0
    end

    # Sends a request's payload. While the middleware chain is still running
    # the payload is held and sent when its outermost middleware returns, with
    # the middleware spans closed.
    def post(client, event_name, payload, action_name)
      ctx = own_context
      if ctx&.rack_open? && (ctx.pending.nil? || ctx.pending.size < MAX_PENDING)
        (ctx.pending ||= []) << [client, event_name, payload, action_name]
      else
        ctx&.finalize(action_name)
        client.post_metric(event_name: event_name, payload: payload, force: true)
      end
    end

    def flush(ctx)
      pending = ctx.pending
      return unless pending

      ctx.pending = nil
      pending.each do |client, event_name, payload, action_name|
        ctx.finalize(action_name)
        client.post_metric(event_name: event_name, payload: payload, force: true)
      end
    end
  end
end
