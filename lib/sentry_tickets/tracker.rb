# frozen_string_literal: true

module SentryTickets
  # Records each error occurrence and gives the destination whatever it is
  # now owed: the issue on a fingerprint's first sighting, a throttled
  # recurrence notice after that. A failed delivery is kept on the group and
  # retried on the fingerprint's next occurrence.
  class Tracker
    def initialize(store:, destination:, notice_interval:)
      @store = store
      @destination = destination
      @notice_interval = notice_interval
      # Serializes record -> deliver per fingerprint: without it, two
      # concurrent first occurrences of one error would both open an issue.
      @locks = {}
      @locks_mutex = Mutex.new
    end

    # Returns [action, group]: the delivery attempted (:opened, :commented or
    # :suppressed) and the group as it is afterwards.
    def track(event, now: Time.now)
      lock_for(event.fingerprint).synchronize do
        group = @store.record(event, at: now)
        deliver(action_for(group, now), group, event, now)
      end
    end

    private

    def lock_for(fingerprint)
      @locks_mutex.synchronize { @locks[fingerprint] ||= Mutex.new }
    end

    def action_for(group, now)
      return :opened unless group.issue

      group.notice_due?(now, @notice_interval) ? :commented : :suppressed
    end

    def deliver(action, group, event, now)
      case action
      when :opened
        open_issue(group, event, now)
      when :commented
        if group.issue["number"].nil? && !@destination.dry_run?
          # The issue only ever existed in dry-run mode (state predates the
          # token); there is no GitHub issue to comment on, so open one.
          open_issue(group, event, now)
        else
          begin
            @destination.comment(number: group.issue["number"], body: notice_text(group))
            [:commented, @store.update(group.fingerprint) { |g| g.delivered(g.issue, at: now) }]
          rescue DeliveryError => e
            # The tracked issue number points at nothing on GitHub (the issue
            # was deleted, or the repo was re-created); open a fresh issue
            # instead of erroring on every recurrence forever.
            raise unless e.status == 404
            open_issue(group, event, now)
          end
        end
      else
        [:suppressed, group]
      end
    rescue DeliveryError => e
      [action, @store.update(group.fingerprint) { |g| g.failed(e.message) }]
    end

    def open_issue(group, event, now)
      issue = @destination.open_issue(title: event.title, body: Ticket.new(event, group).body)
      [:opened, @store.update(group.fingerprint) { |g| g.delivered(issue, at: now) }]
    end

    def notice_text(group)
      "Recurrence notice.\n\n" \
        "- New occurrences since last notice: #{group.unnotified_count}\n" \
        "- Total occurrences: #{group.count}\n" \
        "- First seen: #{group.first_seen}\n" \
        "- Latest seen: #{group.last_seen} (event `#{group.last_event_id}`)"
    end
  end
end
