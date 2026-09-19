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
    assert_includes body, ">       <%= @customer.name %>"
    assert_includes body, "      def load"
    assert_includes body, "          end"
  end

  def test_stacktrace_tolerates_non_array_frame_context
    event = Fixture.event
    frame = event.dig("exception", "values").last["stacktrace"]["frames"].last
    frame["pre_context"] = "garbage"
    frame["post_context"] = "garbage"
    body = SentryTickets::Ticket.new(event, @rec).body
    assert_includes body, "-- Order.load"
  end

  def test_breadcrumb_with_out_of_range_numeric_timestamp_renders_unknown
    # Time.at holds any Bignum, but not a non-finite Float; a foreign event
    # carrying one (or rendered from a hand-built hash) must not abort the
    # rest of the ticket.
    crumbs = [Fixture.breadcrumb("http", "GET /x", timestamp: nil),
              Fixture.breadcrumb("redis", "get k", timestamp: "not-a-ts-but-a-string")]
    body = SentryTickets::Ticket.new(Fixture.event(breadcrumbs: crumbs), @rec).body
    assert_includes body, "[INFO] ? http"
    assert_includes body, "not-a-ts-but-a-string redis"
  end

  def test_stacktrace_context_accepts_lineno_text_pairs
    event = Fixture.event
    frames = event.dig("exception", "values").last["stacktrace"]["frames"]
    frames.last["pre_context"] = [[25, "  def load"]]
    frames.last["context_line"] = "    boom"
    frames.last["post_context"] = [[27, "  end"]]
    body = SentryTickets::Ticket.new(event, @rec).body
    assert_includes body, "      def load"
    assert_includes body, ">       boom"
    assert_includes body, "      end"
  end

  def test_stacktrace_falls_back_to_abs_path
    event = Fixture.event
    frames = event.dig("exception", "values").last["stacktrace"]["frames"]
    frames.last.delete("filename")
    frames.last["abs_path"] = "/app/lib/orders.rb"
    body = SentryTickets::Ticket.new(event, @rec).body
    assert_includes body, "-- Order.load at /app/lib/orders.rb:26"
  end

  def test_request_section_renders_without_crashing
    event = Fixture.event.merge(
      "request" => {
        "method" => "POST",
        "url" => "https://app.example.com/orders",
        "query_string" => "page=2",
        "data" => { "customer_id" => 42 },
        "cookies" => "session=abc",
        "env" => { "REMOTE_ADDR" => "203.0.113.7" }
      }
    )
    store = Fixture.store
    _, rec, = store.ingest(event, now: Time.utc(2026, 9, 19, 12))
    body = SentryTickets::Ticket.new(event, rec).body
    assert_includes body, "## Request"
    assert_includes body, "**Method:** POST"
    assert_includes body, "**URL:** https://app.example.com/orders (query: page=2)"
    assert_includes body, "**User IP:** 203.0.113.7"
    assert_includes body, "**Cookies:** session=abc"
  end

  def test_breadcrumbs_rendered_with_last_ten_cap
    crumbs = 15.times.map { |i| Fixture.breadcrumb("http", "GET /api/orders?page=#{i}", timestamp: 1_758_268_800 + i) }
    event = Fixture.event(breadcrumbs: crumbs)
    body = SentryTickets::Ticket.new(event, @rec).body
    assert_includes body, "## Breadcrumbs (last 10)"
    assert_includes body, "[INFO] 2025-09-19 08:00:14 http — GET /api/orders?page=14"
    refute_includes body, "page=4\n", "only the last 10 crumbs are shown"
    assert_includes body, "page=5\n"
  end

  def test_breadcrumb_data_rendered_and_string_timestamps_pass_through
    crumbs = [Fixture.breadcrumb("redis", "hmset user:42", level: "warning",
                                 timestamp: "2026-09-19T12:00:00Z", data: { "key" => "user:42" })]
    event = Fixture.event(breadcrumbs: crumbs)
    body = SentryTickets::Ticket.new(event, @rec).body
    assert_includes body, "[WARNING] 2026-09-19T12:00:00Z redis — hmset user:42"
    assert_includes body, '`{"key":"user:42"}`'
  end

  def test_malformed_ancillary_sections_render_without_crashing
    garbage = Fixture.event.merge(
      "breadcrumbs" => { "values" => "garbage" },
      "contexts" => "garbage",
      "request" => { "url" => "https://x", "env" => "garbage" }
    )
    body = SentryTickets::Ticket.new(garbage, @rec).body
    assert_includes body, "## Summary"
    assert_includes body, "## Request"
    assert_includes body, "**URL:** https://x"
    refute_includes body, "## Breadcrumbs"
    refute_includes body, "## Contexts"

    crumbs_garbage = Fixture.event(breadcrumbs: [7, "oops"])
    body = SentryTickets::Ticket.new(crumbs_garbage, @rec).body
    refute_includes body, "## Breadcrumbs", "non-hash crumbs are dropped, not rendered"
  end

  def test_raw_payload_embedded
    body = @ticket.body
    assert_includes body, "<details>"
    assert_includes body, "\"event_id\": \"#{@event['event_id']}\""
    assert_includes body, "```json\n"
    assert_includes body, "\n```\n\n</details>"
  end

  def test_body_fits_github_issue_limit_when_payload_is_huge
    # GitHub rejects issue bodies over 65,536 characters; one fat event must
    # not make the ticket permanently undeliverable.
    event = Fixture.event.merge("extra" => { "blob" => "x" * 200_000 })
    body = SentryTickets::Ticket.new(event, @rec).body
    assert_operator body.length, :<=, SentryTickets::Ticket::MAX_BODY_CHARS
    assert_includes body, "## Summary"
    assert_includes body, "*(payload truncated to fit GitHub issue size limits)*"
    assert body.end_with?("</details>"), "details block must stay closed"
  end

  def test_body_clips_when_structured_sections_alone_overflow
    tags = 200.times.map { |i| ["tag_#{i}", "v" * 450] }.to_h
    event = Fixture.event.merge("tags" => tags)
    body = SentryTickets::Ticket.new(event, @rec).body
    assert_operator body.length, :<=, SentryTickets::Ticket::MAX_BODY_CHARS
    assert_includes body, "*(sections truncated to fit GitHub issue size limits)*"
  end
end
