# frozen_string_literal: true

require_relative "test_helper"

class EventTest < Minitest::Test
  def event(data) = SentryTickets::Event.new(data)

  def test_fingerprint_is_stable
    assert_equal Fixture.event.fingerprint, Fixture.event.fingerprint
  end

  def test_fingerprint_changes_with_frame_lineno
    refute_equal Fixture.event.fingerprint, Fixture.event(frame_lineno: 27).fingerprint
  end

  def test_fingerprint_ignores_volatile_tags
    other = event(Fixture.payload.merge("tags" => { "request_id" => "zzz-999" }))
    assert_equal Fixture.event.fingerprint, other.fingerprint,
                 "per-request tags must not split one error into many issues"
  end

  def test_explicit_fingerprint_is_used
    a = Fixture.event(fingerprint: ["my-fingerprint"])
    b = Fixture.event(fingerprint: ["my-fingerprint"], frame_lineno: 999)
    c = Fixture.event(fingerprint: ["other-fingerprint"])
    assert_equal a.fingerprint, b.fingerprint
    refute_equal a.fingerprint, c.fingerprint
  end

  def test_fingerprint_distinguishes_values_at_same_raise_site
    refute_equal Fixture.event.fingerprint,
                 Fixture.event(value: "undefined method `age' for nil:NilClass").fingerprint,
                 "different exception messages on the same frames are different errors"
  end

  def test_fingerprint_ignores_backtrace_lines_in_value
    # The SDK value field carries detailed_message: message first, then
    # embedded backtrace lines. Only the message may split the fingerprint.
    with_trace = Fixture.event(value: "undefined method `name' for nil:NilClass\n\n  from /app/lib/orders.rb:26")
    assert_equal Fixture.event.fingerprint, with_trace.fingerprint
  end

  def test_title_for_exception_event
    assert_equal "NoMethodError: undefined method `name' for nil:NilClass", Fixture.event.title
  end

  def test_title_for_exception_value_with_type_prefix
    assert_equal "NoMethodError: already prefixed", Fixture.event(value: "NoMethodError: already prefixed").title
  end

  def test_title_for_message_event
    assert_equal "hello there", event("message" => "hello there\nmore").title
  end

  def test_title_falls_back_when_message_empty_or_missing
    assert_equal "<no message>", event("message" => "").title
    assert_equal "<no message>", event("event_id" => "x").title
    assert_equal "<no message>", event("message" => nil).title
  end

  def test_title_truncates_long_messages
    title = event("message" => "x" * 200).title
    assert_equal 100, title.length
    assert title.end_with?("...")
  end
end
