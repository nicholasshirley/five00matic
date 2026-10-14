# frozen_string_literal: true

require_relative "test_helper"

class GroupTest < Minitest::Test
  T0 = Time.utc(2026, 9, 19, 12)

  def seen_once(at: T0) = SentryTickets::Group.start("fp", at: at).record(Fixture.event, at: at)

  def test_record_counts_and_remembers_the_latest_event
    group = seen_once.record(Fixture.event(id: "e2"), at: T0 + 60)
    assert_equal 2, group.count
    assert_equal T0.iso8601, group.first_seen
    assert_equal (T0 + 60).iso8601, group.last_seen
    assert_equal "e2", group.last_event_id
    assert_equal "NoMethodError: undefined method `name' for nil:NilClass", group.title
  end

  def test_times_are_kept_as_the_same_utc_instant
    group = seen_once(at: Time.new(2026, 9, 19, 5, 0, 0, "-07:00"))
    assert_equal "2026-09-19T12:00:00Z", group.first_seen,
                 "wall-clock components must not be reinterpreted as UTC"
    assert_equal "2026-09-19T12:00:00Z", group.last_seen
  end

  def test_notice_is_due_once_the_interval_has_passed_since_the_last_one
    group = seen_once.delivered({ "number" => 7 }, at: Time.new(2026, 9, 19, 5, 0, 0, "-07:00"))
    refute group.notice_due?(T0 + 3599, 3600)
    assert group.notice_due?(T0 + 3600, 3600), "the anchor compares by instant, whatever its zone"
  end

  def test_delivery_anchors_the_unnotified_count
    group = seen_once.delivered({ "number" => 7 }, at: T0)
    group = group.record(Fixture.event, at: T0 + 1).record(Fixture.event, at: T0 + 2)
    assert_equal 2, group.unnotified_count
  end

  def test_delivery_clears_the_last_error
    group = seen_once.failed("GitHub API 502: boom")
    assert_equal "GitHub API 502: boom", group.last_error
    assert_nil group.delivered({ "number" => 7 }, at: T0).last_error
  end
end
