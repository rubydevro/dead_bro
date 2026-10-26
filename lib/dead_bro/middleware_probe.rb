# frozen_string_literal: true

module DeadBro
  # Times one Rack middleware — or the router the stack ends in — as a span of
  # the request's tree (see SpanTracker). Rails wraps every middleware in one
  # when it builds the app's middleware stack; the probe reads a clock on the
  # way in and out and allocates nothing.
  class MiddlewareProbe
    attr_reader :span_name, :span_kind

    def initialize(app, name, kind)
      @app = app
      @span_name = name
      @span_kind = kind
    end

    def call(env)
      frame = SpanTracker.rack_enter(self)
      @app.call(env)
    ensure
      SpanTracker.rack_leave(frame) if frame
    end

    # Anything else asked of the middleware goes to it unchanged.
    def respond_to_missing?(method_name, include_private = false)
      @app.respond_to?(method_name, include_private) || super
    end

    def method_missing(method_name, *args, &block)
      if @app.respond_to?(method_name)
        @app.public_send(method_name, *args, &block)
      else
        super
      end
    end
    ruby2_keywords(:method_missing) if respond_to?(:ruby2_keywords, true)

    # ActionDispatch::MiddlewareStack::Middleware#build: one probe per middleware.
    module MiddlewareBuild
      def build(app)
        MiddlewareProbe.wrap(super, inspect, SpanTracker::MIDDLEWARE)
      end
    end

    # ActionDispatch::MiddlewareStack#build: a probe around the endpoint (the
    # app's routes), so routing and controller setup aren't counted as the
    # innermost middleware's own time.
    module StackBuild
      def build(app = nil, &block)
        endpoint = app || block
        return super if endpoint.nil?

        super(MiddlewareProbe.wrap(endpoint, endpoint.class.name, SpanTracker::ENDPOINT))
      end
    end

    def self.wrap(app, name, kind)
      new(app, name.to_s.dup.freeze, kind)
    rescue
      app
    end

    # Must run before Rails builds the middleware stack (the
    # build_middleware_stack initializer); a stack built earlier has no probes.
    def self.install!
      return false unless defined?(::ActionDispatch::MiddlewareStack)

      stack = ::ActionDispatch::MiddlewareStack
      stack.prepend(StackBuild) unless stack.ancestors.include?(StackBuild)
      stack::Middleware.prepend(MiddlewareBuild) unless stack::Middleware.ancestors.include?(MiddlewareBuild)
      true
    rescue
      false
    end
  end
end
