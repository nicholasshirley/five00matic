# frozen_string_literal: true

require_relative "test_helper"

class EventTest < Minitest::Test
  def event(data) = Five00Matic::Event.new(data)

  # The fixture event with the raised exception's frames passed through the
  # block for editing.
  def event_with_frames
    payload = Fixture.payload
    yield payload["exception"]["values"].last["stacktrace"]["frames"]
    event(payload)
  end

  def test_fingerprint_is_stable
    assert_equal Fixture.event.fingerprint, Fixture.event.fingerprint
  end

  def test_fingerprint_ignores_line_numbers
    assert_equal Fixture.event.fingerprint, Fixture.event(frame_lineno: 27).fingerprint,
                 "a deploy that shifts lines must not reopen every error in the file"
  end

  def test_fingerprint_ignores_the_message
    # Ruby 3.2's NoMethodError embeds the receiver's inspect, so every
    # occurrence of one bug carries a different address.
    a = Fixture.event(message: "undefined method `name' for #<User:0x0000000109a275d8 @id=60>")
    b = Fixture.event(message: "undefined method `name' for #<User:0x00000001033c1f20 @id=61>")
    assert_equal a.fingerprint, b.fingerprint
  end

  def test_fingerprint_changes_with_exception_type
    refute_equal Fixture.event.fingerprint, Fixture.event(type: "ArgumentError").fingerprint
  end

  def test_fingerprint_changes_with_the_app_call_path
    other = event_with_frames { |frames| frames.first["function"] = "show" }
    refute_equal Fixture.event.fingerprint, other.fingerprint
  end

  def test_fingerprint_ignores_library_frames_when_app_frames_exist
    other = event_with_frames do |frames|
      frames.unshift(Fixture.frame(88, function: "call", module_name: nil, filename: "rack/runtime.rb", in_app: false))
    end
    assert_equal Fixture.event.fingerprint, other.fingerprint, "a gem upgrade must not reopen the error"
  end

  def test_fingerprint_uses_every_frame_when_none_are_in_app
    library_only = lambda do |function|
      event_with_frames do |frames|
        frames.each { |f| f["in_app"] = false }
        frames.first["function"] = function
      end
    end
    refute_equal library_only.call("index").fingerprint, library_only.call("show").fingerprint
  end

  def test_fingerprint_falls_back_to_the_message_without_a_stack_trace
    timeout = ->(value) { event("exception" => { "values" => [{ "type" => "Timeout::Error", "value" => value }] }) }
    refute_equal timeout.call("execution expired").fingerprint, timeout.call("connection refused").fingerprint
  end

  def test_message_events_group_by_message
    assert_equal event("message" => "cache miss").fingerprint, event("message" => "cache miss").fingerprint
    refute_equal event("message" => "cache miss").fingerprint, event("message" => "cache hit").fingerprint
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

  def test_title_for_exception_event
    assert_equal "NoMethodError: undefined method `name' for nil:NilClass", Fixture.event.title
  end

  def test_title_for_exception_value_without_detailed_message
    # Rubies before 3.2 have no detailed_message; the SDK sends the bare message.
    assert_equal "NoMethodError: undefined method `name' for nil:NilClass",
                 Fixture.event(value: "undefined method `name' for nil:NilClass").title
  end

  def test_title_for_exception_raised_without_a_message
    assert_equal "StandardError", Fixture.event(type: "StandardError", message: "StandardError").title
  end

  def test_title_for_namespaced_exception
    assert_equal "Deep::Oops: x", Fixture.event(type: "Deep::Oops", message: "x").title
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
