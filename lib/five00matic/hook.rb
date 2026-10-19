# frozen_string_literal: true

module Five00Matic
  # The sentry-ruby before_send callable. Each error event is scrubbed and
  # handed to the tracker, which delivers it or queues its delivery,
  # in-process on the thread the SDK sends from; what Sentry still gets
  # depends on the mode:
  #
  #   :shadow   the event, every time: Sentry sees everything it did before,
  #             and GitHub gets tickets besides
  #   :replace  nil once the tracker has counted the event, so Sentry never
  #             sees it; the event itself when the tracker could not take it
  #
  # A delivery that fails is not a failure of the tracker: it is recorded
  # on the group and retried. Anything else that goes wrong in the tracker
  # is logged, and the event goes to Sentry as if there were no hook.
  class Hook
    MODES = %i[shadow replace].freeze
    # Its failures go to Sentry untracked: tracking one would queue another
    # delivery, which could fail the same way.
    DELIVERY_JOB = "Five00Matic::DeliveryJob"

    def initialize(tracker:, scrubber: Scrubber.new, mode: :shadow, logger: nil)
      raise ArgumentError, "mode must be one of #{MODES.join(', ')}, got #{mode.inspect}" unless MODES.include?(mode)

      @tracker = tracker
      @scrubber = scrubber
      @mode = mode
      @logger = logger
    end

    # The SDK passes its Sentry::ErrorEvent and a hint; anything answering
    # to_json_compatible with the event hash will do.
    def call(event, _hint = nil)
      payload = event.to_json_compatible
      return event if Event.new(payload).job_class == DELIVERY_JOB

      tracked = Event.new(@scrubber.scrub(payload))
      return event unless tracked.reportable?

      @tracker.track(tracked)
      @mode == :replace ? nil : event
    rescue StandardError => e
      log("#{e.class}: #{e.message}")
      event
    end

    private

    def log(message)
      text = "[five00matic] #{message}"
      @logger ? @logger.error(text) : warn(text)
    end
  end
end
