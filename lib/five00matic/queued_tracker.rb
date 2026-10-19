# frozen_string_literal: true

require "json"

module Five00Matic
  # Records each occurrence where it happens and leaves the delivery to a
  # job, so the thread that captured the error never waits on GitHub. The
  # tracker's store must hold claims (DatabaseStore): a claim keeps two
  # deliveries of one fingerprint from both opening its issue.
  class QueuedTracker
    attr_reader :tracker

    # enqueue is called with a fingerprint and the event as JSON, and has a
    # job call deliver with them.
    def initialize(tracker:, enqueue:)
      @tracker = tracker
      @enqueue = enqueue
    end

    # Returns [action, group]: :queued when the destination is owed
    # something and its delivery was enqueued, :suppressed otherwise.
    def track(event, now: Time.now)
      group = @tracker.store.record(event, at: now)
      return [:suppressed, group] unless @tracker.owed?(group, now: now)

      @enqueue.call(group.fingerprint, JSON.generate(event.to_h))
      [:queued, group]
    end

    # The job's half: gives the destination what the group is owed as it
    # stands now, rendered from the event that queued the delivery. Returns
    # [action, group] as Tracker#deliver does, or [:busy, nil] when another
    # delivery holds the fingerprint's claim.
    def deliver(fingerprint, payload, now: Time.now)
      @tracker.store.claim(fingerprint, now: now) do |group|
        @tracker.deliver(group, Event.new(JSON.parse(payload)), now: now)
      end || [:busy, nil]
    end
  end
end
