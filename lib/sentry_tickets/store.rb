# frozen_string_literal: true

require "json"
require "digest/sha2"
require "fileutils"
require "time"

module SentryTickets
  # Per-fingerprint state and throttle decisions.
  #
  # State lives in one JSON file written atomically, so counts and notice
  # times survive restarts. The store owns the queue: an event is ingested
  # exactly once, and delivery failures are retried on the next occurrence of
  # the same fingerprint (last_notice_at / issue_pending only advance on a
  # successful delivery).
  class Store
    ACTIONS = %i(opened commented suppressed).freeze

    def initialize(data_dir:, notice_interval: 6 * 3600)
      @path = File.join(data_dir, "state.json")
      @notice_interval = notice_interval
      @mutex = Mutex.new
      load!
    end

    # Returns [action, record, event].
    def ingest(event, project = "default", now: Time.now)
      fp = self.class.fingerprint(event)
      @mutex.synchronize do
        now = Time.utc(*now.to_a)
        rec = @state[fp] || new_record(fp, project, now).tap { |r| @state[fp] = r }
        action = rec["issue_pending"] ? (notice_due?(rec, now) ? :commented : :suppressed) : :opened
        rec["count"] += 1
        rec["last_seen"] = now.iso8601
        rec["last_event_id"] = event["event_id"]
        rec["title"] = self.class.title_for(event)
        # project comes from the DSN and is stable per app; the first event's
        # value is kept for the record's lifetime
        rec["release"] = event["release"] if event["release"]
        rec["environment"] = event["environment"] if event["environment"]
        persist!
        [action, rec, event]
      end
    end

    # Marks a delivery as successful. last_notice_at / last_notice_count anchor
    # the next throttle window and the "N new occurrences" count.
    def record_delivered(fp, number: nil, url: nil, outbox: nil, at: Time.now)
      at = Time.utc(*at.to_a)
      @mutex.synchronize do
        rec = @state[fp]
        return if rec.nil?
        rec["issue_number"] = number if number
        rec["issue_url"] = url if url
        rec["outbox"] = outbox if outbox
        rec["issue_pending"] = true
        rec["last_notice_at"] = at.iso8601
        rec["last_notice_count"] = rec["count"]
        rec["last_error"] = nil
        persist!
      end
    end

    def record_delivery_error(fp, message)
      @mutex.synchronize do
        rec = @state[fp]
        return if rec.nil?
        rec["last_error"] = message
        persist!
      end
    end

    def all
      @state.values.sort_by { |r| r["last_seen"] || "" }.reverse
    end

    def tracked
      @state.size
    end

    # Sentry groups events by fingerprint. Events produced by the SDK almost
    # never carry one (it defaults to an empty array, meaning "derive it"), so
    # we derive one ourselves. Deliberately excludes tags: sentry-rack adds a
    # per-request request_id tag, which would shatter grouping into one issue
    # per request.
    #
    # Shape produced by sentry-ruby 5.x:
    #   exception.values is ordered root cause first; the raised (main)
    #   exception is values.last. stacktrace.frames is ordered oldest frame
    #   first; the crash site is the last frame.
    def self.fingerprint(event)
      explicit = event["fingerprint"]
      return Digest::SHA256.hexdigest(explicit.join("|")) if explicit.is_a?(Array) && !explicit.empty?

      parts = []
      values = event.dig("exception", "values")
      if values.is_a?(Array) && !values.empty?
        v = values.last
        parts << v["type"].to_s
        frames = v.dig("stacktrace", "frames")
        if frames.is_a?(Array)
          frames.last(10).each do |f|
            parts << [f["module"], f["function"], f["filename"], f["lineno"]].join(",")
          end
        end
      end
      parts << event["message"] if event["message"]
      Digest::SHA256.hexdigest(parts.join("\u0000"))
    end

    # The SDK's value field carries Exception#detailed_message, i.e.
    # "Type: message\n\nbacktrace lines" - the first line already contains the
    # type. The raw payload at the bottom of the ticket keeps the rest.
    def self.title_for(event)
      values = event.dig("exception", "values")
      title =
        if values.is_a?(Array) && !values.empty?
          exception_line(values.last)
        else
          (event["message"] || "<no message>").lines.first.to_s
        end
      title = title.gsub(/[[:space:]]+/, " ").strip
      title.length > 100 ? "#{title[0..97]}..." : title
    end

    # "Type: message" for the exception, tolerating values that already carry
    # the "Type: " prefix (SDK detailed_message) or don't (hand-built events).
    def self.exception_line(v)
      type = v["type"].to_s
      first = v["value"].to_s.lines.first.to_s
      first.empty? ? type : (first.start_with?("#{type}: ") ? first : "#{type}: #{first}")
    end

    private

    def new_record(fp, project, now)
      {
        "fingerprint" => fp,
        "project" => project,
        "count" => 0,
        "title" => nil,
        "release" => nil,
        "environment" => nil,
        "first_seen" => now.iso8601,
        "last_seen" => now.iso8601,
        "last_event_id" => nil,
        "issue_number" => nil,
        "issue_url" => nil,
        "issue_pending" => false,
        "last_notice_at" => nil,
        "last_notice_count" => nil,
        "last_error" => nil
      }
    end

    def notice_due?(rec, now)
      last = rec["last_notice_at"] ? Time.parse(rec["last_notice_at"]) : nil
      last.nil? || now - last >= @notice_interval
    end

    def load!
      @state = File.exist?(@path) ? JSON.parse(File.read(@path)) : {}
    end

    # Caller holds @mutex.
    def persist!
      FileUtils.mkdir_p(File.dirname(@path))
      File.write("#{@path}.tmp", JSON.pretty_generate(@state))
      File.rename("#{@path}.tmp", @path)
    end
  end
end
