# frozen_string_literal: true

require_relative "test_helper"

class TicketTest < Minitest::Test
  def setup
    store = Fixture.store
    @_, @rec, @event = store.ingest(Fixture.event, now: Time.utc(2026, 9, 19, 12))
    @ticket = SentryTickets::Ticket.new(@event, @rec)
  end

  def test_title
    assert_equal "NoMethodError: undefined method `name' for nil:NilClass", @ticket.title
  end

  def test_body_has_core_sections
    body = @ticket.body
    assert_includes body, "## Summary"
    assert_includes body, "## Exception"
    assert_includes body, "## Stack trace"
    assert_includes body, "## Tags"
    assert_includes body, "## Extra"
    assert_includes body, "## Contexts"
    assert_includes body, "Full event payload"
  end

  def test_summary_fields
    body = @ticket.body
    assert_includes body, "**Project:** default"
    assert_includes body, "**Environment:** production"
    assert_includes body, "**Release:** 1.2.3"
    assert_includes body, "**Server:** web1.example.com"
    assert_includes body, "**Occurrences:** 1"
    assert_includes body, "**Fingerprint:**"
  end

  def test_exception_chain_shows_raised_first_with_cause
    body = @ticket.body
    nme = body.index("NoMethodError: undefined method")
    arg = body.index("**Caused by:** ArgumentError: missing required parameter")
    assert nme, "raised exception missing"
    assert arg, "cause chain missing"
    assert nme < arg, "raised exception must precede its cause"
  end

  def test_stacktrace_crash_frame_first_with_context_highlight
    body = @ticket.body
    crash = body.index("-- Order.load")
    older = body.index("-- Order.index")
    assert crash, "main frame missing"
    assert older, "older frame missing"
    assert crash < older, "crash site must render before older frames"
    assert_includes body, ">   <%= @customer.name %>"
    assert_includes body, "      def load"
  end

  def test_raw_payload_embedded
    body = @ticket.body
    assert_includes body, "<details>"
    assert_includes body, "\"event_id\": \"#{@event['event_id']}\""
    assert_includes body, "```json\n"
    assert_includes body, "\n```\n\n</details>"
  end
end
