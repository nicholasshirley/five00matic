# frozen_string_literal: true

module Five00Matic
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
        deliver(@store.record(event, at: now), event, now)
      end
    end

    private

    def lock_for(fingerprint)
      @locks_mutex.synchronize { @locks[fingerprint] ||= Mutex.new }
    end

    # Decided from the group alone, so a group whose last delivery failed, or
    # whose issue the destination does not hold (filed in dry-run, say), gets
    # its due on whichever occurrence comes next.
    def deliver(group, event, now)
      if !@destination.owns?(group.issue) then open_issue(group, event, now)
      elsif group.notice_due?(now, @notice_interval) then post_notice(group, event, now)
      else [:suppressed, group]
      end
    end

    def open_issue(group, event, now)
      issue = @destination.open_issue(title: event.title, body: Ticket.new(event, group).body)
      [:opened, update(group) { |g| g.delivered(issue, at: now) }]
    rescue DeliveryError => e
      [:opened, update(group) { |g| g.failed(e.message) }]
    end

    def post_notice(group, event, now)
      @destination.comment(group.issue, body: Notice.new(group).body)
      [:commented, update(group) { |g| g.delivered(g.issue, at: now) }]
    rescue IssueGone
      open_issue(update(group, &:without_issue), event, now)
    rescue DeliveryError => e
      [:commented, update(group) { |g| g.failed(e.message) }]
    end

    def update(group, &) = @store.update(group.fingerprint, &)
  end
end
