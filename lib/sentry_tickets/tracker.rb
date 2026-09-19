# frozen_string_literal: true

module SentryTickets
  # Records each error occurrence and gives the destination whatever it is
  # now owed: the issue on a fingerprint's first sighting, a throttled
  # recurrence notice after that. A failed delivery is kept on the record and
  # retried on the fingerprint's next occurrence.
  class Tracker
    def initialize(store:, destination:)
      @store = store
      @destination = destination
      # Serializes record -> deliver per fingerprint: without it, two
      # concurrent first occurrences of one error would both open an issue.
      @locks = {}
      @locks_mutex = Mutex.new
    end

    # Returns [action, record], the action being the delivery attempted:
    # :opened, :commented or :suppressed.
    def track(event)
      lock_for(event.fingerprint).synchronize do
        action, rec, = @store.ingest(event)
        [deliver(action, rec, event), rec]
      end
    end

    private

    def lock_for(fp)
      @locks_mutex.synchronize { @locks[fp] ||= Mutex.new }
    end

    def deliver(action, rec, event)
      fp = rec["fingerprint"]
      case action
      when :opened
        open_issue(rec, event)
      when :commented
        if rec["issue_number"].nil? && !@destination.dry_run?
          # The issue only ever existed in dry-run mode (state predates the
          # token); there is no GitHub issue to comment on, so open one.
          open_issue(rec, event)
        else
          begin
            @destination.comment(number: rec["issue_number"], body: notice_text(rec))
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
      r = @destination.open_issue(title: event.title, body: Ticket.new(event, rec).body)
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
  end
end
