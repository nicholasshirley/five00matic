# frozen_string_literal: true

require "json"

module Five00Matic
  # The Rack face of the tracker: POST /events takes the event hash a
  # before_send hook has and answers with what happened to it; GET /health
  # and /issues report on the store.
  class App
    InvalidPayload = Class.new(StandardError)

    def initialize(config)
      @tracker = Five00Matic.tracker(config)
    end

    def call(env)
      case [env["REQUEST_METHOD"], env["PATH_INFO"]]
      when ["POST", "/events"] then receive(env["rack.input"]&.read.to_s)
      when ["GET", "/health"] then json({ status: "ok", version: VERSION, dry_run: @tracker.destination.dry_run?,
                                          tracked: @tracker.store.size })
      when ["GET", "/issues"] then json(@tracker.store.groups.map(&:to_h))
      else json({ error: "not found" }, status: 404)
      end
    end

    private

    # Delivery runs inline. Its failures are recorded and retried on the next
    # occurrence, so the answer is still 200: the event is durably counted,
    # and the sender (before_send returning nil) has handed off ownership.
    def receive(body)
      action, group = @tracker.track(parse(body))
      json({
        action: action.to_s,
        count: group.count,
        fingerprint: group.fingerprint,
        first_seen: group.first_seen,
        last_seen: group.last_seen,
        issue: group.issue_url,
        issue_error: group.last_error
      })
    rescue InvalidPayload => e
      json({ error: e.message }, status: 400)
    end

    def parse(body)
      data = JSON.parse(body)
      raise InvalidPayload, "unrecognized payload (expected Sentry event JSON)" unless data.is_a?(Hash)

      # The ticket embeds the payload as JSON and the state file keeps parts
      # of it, but JSON.parse accepts what JSON.generate refuses: invalid
      # UTF-8 and numbers like 1e999. The SDK builds its payload with
      # JSON.generate, so anything failing here was not sent by it.
      JSON.generate(data)
      event = Event.new(data)
      raise InvalidPayload, "event has no exception or message" unless event.reportable?

      event
    rescue JSON::ParserError
      raise InvalidPayload, "unrecognized payload (expected Sentry event JSON)"
    rescue JSON::GeneratorError
      raise InvalidPayload, "payload holds invalid UTF-8 or a non-finite number"
    end

    def json(payload, status: 200)
      body = JSON.generate(payload)
      [status, { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s }, [body]]
    end
  end
end
