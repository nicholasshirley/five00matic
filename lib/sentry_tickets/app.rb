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
    BAD_PAYLOAD_ERROR = "unrecognized payload (expected event JSON or Sentry envelope)"
    NO_SIGNAL_ERROR = "event has no exception or message"

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
      event, project, error = extract_event(env)
      return json({ error: error }, status: 400) if event.nil?

      lock_for(Store.fingerprint(event)).synchronize do
        action, rec, ev = @store.ingest(event, project)
        action = deliver(action, rec, ev)
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
      r = @github.open_issue(title: Store.title_for(event), body: Ticket.new(event, rec).body)
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

    # Returns [event, project, error]. A nil event carries the reason in
    # error.
    def extract_event(env)
      raw = env["rack.input"]
      raw = raw.respond_to?(:read) ? raw.read : raw
      # Rack servers hand over binary bodies, but embedded callers may not;
      # normalize so encoding-sensitive calls (strip, gzip sniff, JSON.parse)
      # behave like the deployed path whatever the input's label.
      body = raw.to_s.b
      # gzip magic bytes, by value: a String#start_with? sniff raises
      # Encoding::CompatibilityError when the body is UTF-8-labeled and
      # carries non-ASCII bytes.
      if body.getbyte(0) == 0x1F && body.getbyte(1) == 0x8B
        begin
          body = Zlib.gunzip(body)
        rescue Zlib::Error
          return [nil, nil, BAD_PAYLOAD_ERROR]
        end
      end
      return [nil, nil, BAD_PAYLOAD_ERROR] if body.strip.empty?

      event, project = envelope_event(body)
      if event.nil?
        begin
          parsed = JSON.parse(body)
        rescue JSON::ParserError
          return [nil, nil, BAD_PAYLOAD_ERROR]
        end
        return [nil, nil, BAD_PAYLOAD_ERROR] unless parsed.is_a?(Hash)

        event, project = parsed, (env["HTTP_X_SENTRY_PROJECT"] || "default")
      end

      # Project is persisted and echoed back, but never passed through
      # normalize: X-Sentry-Project is a raw header, and an invalid-encoding
      # byte sequence would raise JSON::GeneratorError on the next persist
      # and wedge the store.
      project = scrub_encoding(project)
      event = normalize(event)
      return [nil, nil, NO_SIGNAL_ERROR] unless error_event?(event)

      [event, project]
    end

    # JSON.parse trusts the source encoding: a body that is not valid UTF-8
    # yields strings with invalid bytes, which later crash JSON generation in
    # the ticket renderer — or ride along raw when the source was
    # binary-labeled, making GitHub reject the delivery with 400. Normalize
    # every string, keys included, so one bad event cannot wedge the pipeline
    # for its fingerprint.
    def scrub_encoding(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), h| h[scrub_encoding(k)] = scrub_encoding(v) }
      when Array
        obj.map { |v| scrub_encoding(v) }
      when String
        obj.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
      when Float
        # 1e999/-1e999 in the payload parse as infinities (and a NaN literal
        # with a permissive parser), which JSON.generate then refuses; the
        # ticket's raw-payload section would fail on every delivery attempt.
        obj.finite? ? obj : nil
      else obj
      end
    end

    # Fingerprinting and rendering assume the SDK's shapes and crash on
    # garbage (Hash#dig into a String, Integer#[]). Strip structurally
    # invalid pieces instead of 500ing; whatever survives is real signal.
    def normalize(event)
      scrub_encoding(event).tap { |ev| normalize_exception(ev) }
    end

    def normalize_exception(event)
      ex = event["exception"]
      return event.delete("exception") unless ex.is_a?(Hash)

      values = ex["values"].is_a?(Array) ? ex["values"].grep(Hash) : nil
      return event.delete("exception") if values.nil? || values.empty?

      values.each { |v| normalize_exception_value(v) }
      ex["values"] = values
    end

    def normalize_exception_value(v)
      st = v["stacktrace"]
      return v.delete("stacktrace") unless st.is_a?(Hash)

      return unless st["frames"].is_a?(Array)
      st["frames"] = st["frames"].grep(Hash)
      st["frames"].each do |f|
        %w[pre_context post_context].each { |k| f.delete(k) unless f[k].is_a?(Array) }
      end
    end

    # After normalize, a present "exception" is usable. Anything else needs a
    # non-blank message: without one there is nothing to group on, and every
    # such event would collide on the digest of the empty fingerprint.
    def error_event?(event)
      return true if event["exception"].is_a?(Hash)
      !event["message"].to_s.strip.empty?
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
          return [payload, project || "default"] if payload.is_a?(Hash)
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
