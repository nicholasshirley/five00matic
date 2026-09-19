# frozen_string_literal: true

require_relative "test_helper"

class StoreTest < Minitest::Test
  T0 = Time.utc(2026, 9, 19, 12, 0, 0)

  def test_fingerprint_is_stable
    assert_equal SentryTickets::Store.fingerprint(Fixture.event),
                 SentryTickets::Store.fingerprint(Fixture.event)
  end

  def test_fingerprint_changes_with_frame_lineno
    refute_equal SentryTickets::Store.fingerprint(Fixture.event),
                     SentryTickets::Store.fingerprint(Fixture.event(frame_lineno: 27))
  end

  def test_fingerprint_ignores_volatile_tags
    a = Fixture.event
    b = Fixture.event.tap { |e| e["tags"] = { "request_id" => "zzz-999" } }
    assert_equal a["exception"], b["exception"]
    assert_equal SentryTickets::Store.fingerprint(a), SentryTickets::Store.fingerprint(b),
                 "per-request tags must not split one error into many issues"
  end

  def test_explicit_fingerprint_is_used
    a = Fixture.event(fingerprint: ["my-fingerprint"])
    b = Fixture.event(fingerprint: ["my-fingerprint"], frame_lineno: 999)
    c = Fixture.event(fingerprint: ["other-fingerprint"])
    assert_equal SentryTickets::Store.fingerprint(a), SentryTickets::Store.fingerprint(b)
    refute_equal SentryTickets::Store.fingerprint(a), SentryTickets::Store.fingerprint(c)
  end

  def test_first_event_opens_and_counts
    store = Fixture.store
    action, rec, = store.ingest(Fixture.event, now: T0)
    assert_equal :opened, action
    assert_equal 1, rec["count"]
    assert_equal false, rec["issue_pending"]
    assert_equal T0.iso8601, rec["first_seen"]
  end

  def test_recurrence_before_notice_interval_is_suppressed
    store = Fixture.store
    store.ingest(Fixture.event, now: T0)
    store.record_delivered(SentryTickets::Store.fingerprint(Fixture.event), number: 7, url: "http://gh/7", at: T0)

    action, rec, = store.ingest(Fixture.event, now: T0 + 3600)
    assert_equal :suppressed, action
    assert_equal 2, rec["count"]
    assert_equal 7, rec["issue_number"]
  end

  def test_recurrence_after_notice_interval_comments
    store = Fixture.store
    store.ingest(Fixture.event, now: T0)
    store.record_delivered(SentryTickets::Store.fingerprint(Fixture.event), number: 7, at: T0)

    action, rec, = store.ingest(Fixture.event, now: T0 + 21_601)
    assert_equal :commented, action
    assert_equal 2, rec["count"]
  end

  def test_delivery_success_anchors_notice_window
    store = Fixture.store
    fp = SentryTickets::Store.fingerprint(Fixture.event)
    store.ingest(Fixture.event, now: T0)
    store.record_delivered(fp, number: 7, at: T0)

    # count moves without advancing the anchor while suppressed
    store.ingest(Fixture.event, now: T0 + 60)
    # still due against the T0 anchor, even though only ~2h of *events* elapsed
    # since the last suppressed count
    action, rec, = store.ingest(Fixture.event, now: T0 + 21_720)
    assert_equal :commented, action
    assert_equal 3, rec["count"]
  end

  def test_failed_open_retries_next_occurrence
    store = Fixture.store
    fp = SentryTickets::Store.fingerprint(Fixture.event)
    store.ingest(Fixture.event, now: T0)
    store.record_delivery_error(fp, "GitHub API 502: boom")

    action, = store.ingest(Fixture.event, now: T0 + 60)
    assert_equal :opened, action, "issue_pending stays false until delivery succeeds"
    assert_equal "GitHub API 502: boom", store.all.first["last_error"]
  end

  def test_persists_across_instances
    dir = Fixture.store_dir
    store = Fixture.store(dir)
    fp = SentryTickets::Store.fingerprint(Fixture.event)
    store.ingest(Fixture.event, now: T0)
    store.record_delivered(fp, number: 9, url: "http://gh/9")

    reloaded = Fixture.store(dir)
    assert_equal 1, reloaded.tracked
    assert_equal 9, reloaded.all.first["issue_number"]
  end

  def test_title_for_exception_event
    assert_equal "NoMethodError: undefined method `name' for nil:NilClass",
                 SentryTickets::Store.title_for(Fixture.event)
  end
end
