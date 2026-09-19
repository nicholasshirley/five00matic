# frozen_string_literal: true

require "json"
require "stringio"
require "uri"
require "zlib"

module SentryTickets
  # The deliverable: POST /events accepts either a raw event hash (what a
  # before_send hook has) or a raw Sentry envelope (what a DSN pointed here
  # would POST), and answers with what happened to it.
  class App
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
      event, project = extract_event(env)
      return json({ error: "unrecognized payload (expected event JSON or Sentry envelope)" }, status: 400) if event.nil?

      lock_for(Store.fingerprint(event)).synchronize do
        action, rec, ev = @store.ingest(event, project)
        deliver(action, rec, ev)
        json({
          action: action.to_s,
          count: rec["count"],
          fingerprint: rec["fingerprint"],
          project: rec["project"],
          first_seen: rec["first_seen"],
          last_seen: rec["last_seen"],
          issue: rec["issue_url"] || rec["outbox"],
          issue_error: rec["last_error"]
        })
      end
    end

    def lock_for(fp)
      @locks_mutex.synchronize { @locks[fp] ||= Mutex.new }
    end

    # Delivery runs inline (a real deployment would queue it). Failure is
    # recorded on the record and retried on the event's next occurrence; the
    # response still reports 200 because the event is durably counted and the
    # sender (before_send returning nil) has handed off ownership.
    def deliver(action, rec, event)
      fp = rec["fingerprint"]
      case action
      when :opened
        r = @github.open_issue(title: Store.title_for(event), body: Ticket.new(event, rec).body)
        @store.record_delivered(fp, number: r["number"], url: r["url"], outbox: r["outbox"])
      when :commented
        @github.comment(number: rec["issue_number"], body: notice_text(rec))
        @store.record_delivered(fp)
      when :suppressed
      end
    rescue DeliveryError => e
      @store.record_delivery_error(fp, e.message)
    end

    def notice_text(rec)
      since = rec["count"] - (rec["last_notice_count"] || 0)
      "Recurrence notice.\n\n" \
        "- New occurrences since last notice: #{since}\n" \
        "- Total occurrences: #{rec['count']}\n" \
        "- First seen: #{rec['first_seen']}\n" \
        "- Latest seen: #{rec['last_seen']} (event `#{rec['last_event_id']}`)"
    end

    def extract_event(env)
      body = env["rack.input"]
      body = body.respond_to?(:read) ? body.read : body.to_s
      if body.start_with?("\x1F\x8B".b)
        begin
          body = Zlib.gunzip(body)
        rescue Zlib::Error
          return [nil, nil]
        end
      end
      return [nil, nil] if body.strip.empty?

      event, project = envelope_event(body)
      return [event, project] if event

      begin
        parsed = JSON.parse(body)
      rescue JSON::ParserError
        return [nil, nil]
      end
      return [nil, nil] unless parsed.is_a?(Hash)

      [scrub_encoding(parsed), env["HTTP_X_SENTRY_PROJECT"] || "default"]
    end

    # JSON.parse trusts the source encoding: a body that is not valid UTF-8
    # yields UTF-8-labeled strings with invalid bytes, which later crash
    # JSON.pretty_generate in the ticket renderer. Normalize every string so
    # one bad event cannot wedge the pipeline for its fingerprint.
    def scrub_encoding(obj)
      case obj
      when Hash then obj.transform_values { |v| scrub_encoding(v) }
      when Array then obj.map { |v| scrub_encoding(v) }
      when String
        obj.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
      else obj
      end
    end

    # Envelope wire format: headers JSON line, then (item headers JSON line,
    # item payload JSON line) pairs. Only the first "event"/"error" item
    # counts; sessions, client reports, transactions and profiles are skipped.
    def envelope_event(body)
      lines = body.split("\n")
      header = JSON.parse(lines[0])
      return [nil, nil] unless header.is_a?(Hash) && header["event_id"] && (header["dsn"] || header["sent_at"])

      project =
        if header["dsn"].is_a?(String)
          begin
            URI.parse(header["dsn"]).path.split("/").last
          rescue URI::Error
            nil
          end
        end
      i = 1
      while i + 1 < lines.length
        item_header = JSON.parse(lines[i])
        if item_header.is_a?(Hash) && %w(event error).include?(item_header["type"])
          payload = JSON.parse(lines[i + 1])
          return [scrub_encoding(payload), project || "default"] if payload.is_a?(Hash)
        end
        i += 2
      end
      [nil, nil]
    rescue JSON::ParserError
      [nil, nil]
    end

    def json(payload, status: 200)
      body = JSON.generate(payload)
      [status, { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s }, [body]]
    end
  end
end
