# frozen_string_literal: true

module DeadBro
  # A super sample is one request or job sent whole: nothing recorded for it is
  # capped or cut, nothing is cut from its payload, and it is sent whatever the
  # sample rate. The payload says so with `super_sample: true`.
  #
  # The dashboard asks for them per request type: `super_samples_by_type` holds
  # how many each type still needs. While any are needed, each request and job
  # is drawn with a 1% chance (CHANCE_PERCENT), and a drawn one whose type
  # needs a super sample is sent as one: about 1 in 100 requests of that type.
  # DeadBro stores each super sample it receives and answers with the number
  # still needed. Every process holds that number on its own until the next
  # response, so the low chance also keeps several processes from each sending
  # one at the same moment.
  module SuperSample
    # The request a thread is serving and the job it is running are drawn
    # apart: a job performed inline in a controller action is its own sample.
    REQUEST_KEY = :dead_bro_super_sample_request
    JOB_KEY = :dead_bro_super_sample_job

    CHANCE_PERCENT = 1

    # start_processing.action_controller is the first point of a request where
    # its controller and action are known.
    class RequestListener
      def start(_name, _id, payload)
        SuperSample.start_request(payload)
      end

      def finish(_name, _id, _payload)
      end
    end

    module_function

    # A request enters DeadBro's middleware. The draw is made here, before
    # anything is recorded for the request, so that what runs between the
    # middleware and the controller action isn't capped or cut either.
    def start_tracking
      Thread.current[REQUEST_KEY] = draw?
    rescue *DeadBro::CONTAINED_ERRORS
    end

    # A drawn request goes on as a super sample only when its type needs one.
    def start_request(payload)
      return unless Thread.current[REQUEST_KEY]

      Thread.current[REQUEST_KEY] = needed?("#{payload[:controller]}##{payload[:action]}")
    rescue *DeadBro::CONTAINED_ERRORS
    end

    def start_job(job)
      Thread.current[JOB_KEY] = draw? && needed?("#{job.class.name}#perform")
    rescue *DeadBro::CONTAINED_ERRORS
    end

    # Whether the request (or job) the thread is finishing is a super sample.
    def request?
      Thread.current[REQUEST_KEY] == true
    end

    def job?
      Thread.current[JOB_KEY] == true
    end

    # The request (or job) is over: what the thread runs next has its limits again.
    def finish_request
      Thread.current[REQUEST_KEY] = nil
    end

    def finish_job
      Thread.current[JOB_KEY] = nil
    end

    # True while this thread runs a super sample: nothing it records is capped
    # or cut.
    def active?
      Thread.current[REQUEST_KEY] || Thread.current[JOB_KEY] || false
    end

    # No draw is made while no type needs a super sample.
    def draw?
      !DeadBro.configuration.super_samples_by_type.empty? && rand(1..100) <= CHANCE_PERCENT
    end

    def needed?(type)
      DeadBro.configuration.super_samples_by_type[type].to_i > 0
    end
  end
end
