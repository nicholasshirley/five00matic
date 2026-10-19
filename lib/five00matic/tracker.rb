# frozen_string_literal: true

module Five00Matic
  # Records each error occurrence and gives the destination whatever it is
  # now owed: the issue on a fingerprint's first sighting, a throttled
  # recurrence notice after that. A failed delivery is kept on the group and
  # retried on the fingerprint's next occurrence.
  class Tracker
    # The Rack app answers /health and /issues from these.
    attr_reader :store, :destination

    def initialize(store:, destination:, notice_interval:)
      @store = store
      @destination = destination
      @notice_interval = notice_interval
    end

    # Returns [action, group]: the delivery attempted (:opened, :commented or
    # :suppressed) and the group as it is afterwards. Record and deliver run
    # under the fingerprint's lock, held across every process sharing the
    # store: without it, two concurrent first occurrences of one error would
    # both open an issue.
    def track(event, now: Time.now)
      @store.synchronize(event.fingerprint) do
        deliver(@store.record(event, at: now), event, now: now)
      end
    end

    # Whether the destination is owed anything for the group now: its
    # issue, or a recurrence notice.
    def owed?(group, now: Time.now) = !@destination.owns?(group.issue) || notice_owed?(group, now)

    # Gives the destination what the group is owed now, rendered from the
    # event, and returns [action, group] as track does. The caller holds
    # the fingerprint's lock. Decided from the group alone, so a group whose
    # last delivery failed, or whose issue the destination does not hold
    # (filed in dry-run, say), gets its due on whichever delivery comes next.
    def deliver(group, event, now: Time.now)
      if !@destination.owns?(group.issue) then open_issue(group, event, now)
      elsif notice_owed?(group, now) then post_notice(group, event, now)
      else [:suppressed, group]
      end
    end

    private

    # A delivery queued before the last one landed can find nothing left to report.
    def notice_owed?(group, now) = group.unnotified_count.positive? && group.notice_due?(now, @notice_interval)

    def open_issue(group, event, now)
      issue = @destination.open_issue(title: event.title, body: Ticket.new(event, group).body)
      [:opened, update(group) { |g| g.delivered(issue, at: now, reported: group.count) }]
    rescue DeliveryError => e
      [:opened, update(group) { |g| g.failed(e.message) }]
    end

    def post_notice(group, event, now)
      @destination.comment(group.issue, body: Notice.new(group).body)
      [:commented, update(group) { |g| g.delivered(g.issue, at: now, reported: group.count) }]
    rescue IssueGone
      open_issue(update(group, &:without_issue), event, now)
    rescue DeliveryError => e
      [:commented, update(group) { |g| g.failed(e.message) }]
    end

    def update(group, &) = @store.update(group.fingerprint, &)
  end
end
