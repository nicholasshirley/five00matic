# frozen_string_literal: true

require "json"
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
    def initialize(data_dir:, notice_interval: 6 * 3600)
      @path = File.join(data_dir, "state.json")
      @notice_interval = notice_interval
      @mutex = Mutex.new
      load!
    end

    # Returns [action, record, event].
    def ingest(event, now: Time.now)
      fp = event.fingerprint
      @mutex.synchronize do
        now = now.getutc
        rec = @state[fp] || new_record(fp, now).tap { |r| @state[fp] = r }
        action = rec["issue_pending"] ? (notice_due?(rec, now) ? :commented : :suppressed) : :opened
        rec["count"] += 1
        rec["last_seen"] = now.iso8601
        rec["last_event_id"] = event.id
        rec["title"] = event.title
        rec["release"] = event.release if event.release
        rec["environment"] = event.environment if event.environment
        persist!
        [action, rec, event]
      end
    end

    # Marks a delivery as successful. last_notice_at / last_notice_count anchor
    # the next throttle window and the "N new occurrences" count.
    def record_delivered(fp, number: nil, url: nil, outbox: nil, at: Time.now)
      at = at.getutc
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
        # An invalid-encoding message would raise JSON::GeneratorError on the
        # next persist! and every one after; keep state serializable.
        rec["last_error"] =
          message.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
        persist!
      end
    end

    def all
      @mutex.synchronize do
        @state.values.sort_by { |r| self.class.sort_time(r["last_seen"]) }.reverse
      end
    end

    # iso8601 strings only sort lexicographically within one precision:
    # "...00.5Z" sorts before "...00Z" though it is the later instant.
    def self.sort_time(value)
      Time.iso8601(value)
    rescue ArgumentError, TypeError
      Time.at(0)
    end

    def tracked
      @mutex.synchronize { @state.size }
    end

    private

    def new_record(fp, now)
      {
        "fingerprint" => fp,
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
      # Titles and last_errors are built from event content; keep the state
      # file readable by the owner only (the tmp-then-rename dance means the
      # permission is set on every write).
      File.write("#{@path}.tmp", JSON.pretty_generate(@state), perm: 0o600)
      File.rename("#{@path}.tmp", @path)
    end
  end
end
