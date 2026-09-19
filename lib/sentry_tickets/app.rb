# frozen_string_literal: true

require "json"

module SentryTickets
  # The deliverable: POST /events accepts the event hash a before_send hook
  # has, and answers with what happened to it.
  class App
    InvalidPayload = Class.new(StandardError)

    def initialize(config, store: nil, github: nil)
      @store = store || Store.new(data_dir: config.data_dir, notice_interval: config.notice_interval)
      @github = github || GitHubSync.new(
        repo: config.repo,
        token: config.token,
        labels: config.labels,
        api_base: config.api_base,
        outbox_dir: File.join(config.data_dir, "outbox")
      )
      # Serializes ingest -> deliver per fingerprint. The standalone server
      # (bin/serve.rb) handles each connection on its own thread, and without
      # this two concurrent first occurrences of one error would both see
      # :opened and create duplicate GitHub issues.
      @locks = {}
      @locks_mutex = Mutex.new
    end

    attr_reader :store, :github

    def call(env)
      method = env["REQUEST_METHOD"]
      path = env["PATH_INFO"]

      if method == "POST" && path == "/events"
        handle_events(env)
      elsif method == "GET" && path == "/health"
        json({ status: "ok", version: SentryTickets::VERSION,
               dry_run: @github.dry_run?, tracked: @store.tracked })
      elsif method == "GET" && path == "/issues"
        json(@store.all)
      else
        json({ error: "not found" }, status: 404)
      end
    end

    private

    def handle_events(env)
      event = parse(env["rack.input"]&.read.to_s)
      lock_for(event.fingerprint).synchronize do
        action, rec, ev = @store.ingest(event)
        action = deliver(action, rec, ev)
        json({
          action: action.to_s,
          count: rec["count"],
          fingerprint: rec["fingerprint"],
          first_seen: rec["first_seen"],
          last_seen: rec["last_seen"],
          issue: rec["issue_url"] || rec["outbox"],
          issue_error: rec["last_error"]
        })
      end
    rescue InvalidPayload => e
      json({ error: e.message }, status: 400)
    end

    def lock_for(fp)
      @locks_mutex.synchronize { @locks[fp] ||= Mutex.new }
    end

    # Delivery runs inline (a real deployment would queue it). Failure is
    # recorded on the record and retried on the event's next occurrence; the
    # response still reports 200 because the event is durably counted and the
    # sender (before_send returning nil) has handed off ownership.
    # Returns the action that was actually attempted.
    def deliver(action, rec, event)
      fp = rec["fingerprint"]
      case action
      when :opened
        open_issue(rec, event)
      when :commented
        if rec["issue_number"].nil? && !@github.dry_run?
          # The issue only ever existed in dry-run mode (state predates the
          # token); there is no GitHub issue to comment on, so open one.
          open_issue(rec, event)
        else
          begin
            @github.comment(number: rec["issue_number"], body: notice_text(rec))
            @store.record_delivered(fp)
            :commented
          rescue DeliveryError => e
            # The tracked issue number points at nothing on GitHub (the issue
            # was deleted, or the repo was re-created); open a fresh issue
            # instead of erroring on every recurrence forever.
            raise unless e.status == 404
            open_issue(rec, event)
          end
        end
      else # :suppressed
        action
      end
    rescue DeliveryError => e
      @store.record_delivery_error(fp, e.message)
      action
    end

    def open_issue(rec, event)
      r = @github.open_issue(title: event.title, body: Ticket.new(event, rec).body)
      @store.record_delivered(rec["fingerprint"], number: r["number"], url: r["url"], outbox: r["outbox"])
      :opened
    end

    def notice_text(rec)
      since = rec["count"] - (rec["last_notice_count"] || 0)
      "Recurrence notice.\n\n" \
        "- New occurrences since last notice: #{since}\n" \
        "- Total occurrences: #{rec['count']}\n" \
        "- First seen: #{rec['first_seen']}\n" \
        "- Latest seen: #{rec['last_seen']} (event `#{rec['last_event_id']}`)"
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
