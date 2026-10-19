# frozen_string_literal: true

require "time"

module Five00Matic
  # Everything remembered about one fingerprint: how often and when it was
  # seen, the issue it was filed as, and when that issue was last notified.
  # Immutable; each change returns the group as it is afterwards. Times are
  # UTC ISO 8601 strings, as persisted.
  Group = Data.define(
    :fingerprint, :title, :release, :environment,
    :count, :first_seen, :last_seen, :last_event_id,
    # What the destination returned on opening it, e.g. GitHub's
    # { "repo" => "you/app", "number" => 7, "url" => "https://github.com/..." }.
    :issue,
    # The window for the next recurrence notice starts at last_notice_at;
    # last_notice_count is the count that notice reported.
    :last_notice_at, :last_notice_count,
    :last_error
  ) do
    def initialize(fingerprint:, first_seen:, title: nil, release: nil, environment: nil, count: 0,
                   last_seen: nil, last_event_id: nil, issue: nil, last_notice_at: nil,
                   last_notice_count: 0, last_error: nil)
      super
    end

    def self.start(fingerprint, at:) = new(fingerprint: fingerprint, first_seen: at.getutc.iso8601)

    def record(event, at:)
      with(count: count + 1, last_seen: at.getutc.iso8601, last_event_id: event.id, title: event.title,
           release: event.release || release, environment: event.environment || environment)
    end

    # reported is the count the ticket or notice gave, which occurrences
    # recorded while it was in flight have since passed.
    def delivered(issue, at:, reported: count)
      with(issue: issue, last_notice_at: at.getutc.iso8601, last_notice_count: reported, last_error: nil)
    end

    def failed(message) = with(last_error: message)

    def without_issue = with(issue: nil)

    def notice_due?(now, interval)
      last_notice_at.nil? || now - Time.iso8601(last_notice_at) >= interval
    end

    def unnotified_count = count - last_notice_count

    def issue_url = issue && issue["url"]
  end
end
