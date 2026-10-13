# frozen_string_literal: true

require_relative "test_helper"

class NoticeTest < Minitest::Test
  T0 = Time.utc(2026, 9, 19, 12)

  def test_body_reports_occurrences_since_the_last_notice
    group = Five00Matic::Group.start("fp", at: T0).record(Fixture.event, at: T0)
    group = group.delivered({ "number" => 7 }, at: T0)
    group = group.record(Fixture.event, at: T0 + 60).record(Fixture.event(id: "e3"), at: T0 + 120)

    assert_equal <<~MARKDOWN.chomp, Five00Matic::Notice.new(group).body
      Recurrence notice.

      - New occurrences since last notice: 2
      - Total occurrences: 3
      - First seen: 2026-09-19T12:00:00Z
      - Latest seen: 2026-09-19T12:02:00Z (event `e3`)
    MARKDOWN
  end
end
