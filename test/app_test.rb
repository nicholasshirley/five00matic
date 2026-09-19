# frozen_string_literal: true

require_relative "test_helper"

class FailingGitHub
  def open_issue(title:, body:)
    raise SentryTickets::DeliveryError, "GitHub API 502: boom"
  end

  def comment(number:, body:)
    raise SentryTickets::DeliveryError, "GitHub API 502: boom"
  end
end

class SlowGitHub
  attr_reader :opens, :comments

  def initialize
    @mutex = Mutex.new
    @opens = 0
    @comments = 0
  end

  def open_issue(title:, body:)
    sleep 0.2 # widen the ingest-before-deliver race window
    @mutex.synchronize { @opens += 1 }
    { "number" => @opens, "url" => "http://gh/#{@opens}" }
  end

  def comment(number:, body:)
    @mutex.synchronize { @comments += 1 }
    { "number" => number }
  end
end

class AppTest < Minitest::Test
  def setup
    dir = Fixture.store_dir
    @config = SentryTickets::Config.new(
      repo: nil, token: nil, data_dir: dir, notice_interval: 0 # 0: always due, no GitHub
    )
    @app = SentryTickets::App.new(@config)
    @outbox = File.join(dir, "outbox")
  end

  def post(body, headers = {}, app: @app)
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/events",
      "QUERY_STRING" => "",
      "CONTENT_LENGTH" => body.bytesize.to_s,
      "rack.input" => StringIO.new(body)
    }.merge(headers)
    app.call(env)
  end

  def get(path)
    @app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => path, "rack.input" => StringIO.new(""))
  end

  def outbox_files
    Dir[File.join(@outbox, "**", "*.md")].sort
  end

  def test_dry_run_without_token
    assert @app.github.dry_run?
  end

  def test_event_hash_opens_issue_in_outbox
    status, headers, body = post(Fixture.event.to_json)
    resp = JSON.parse(body.join)
    assert_equal 200, status
    assert_equal "opened", resp["action"]
    assert_equal 1, resp["count"]
    files = outbox_files
    assert_equal 1, files.size
    assert_match %r{^issue-}, File.basename(files.first)
    content = File.read(files.first)
    assert_includes content, "# NoMethodError: undefined method `name' for nil"
    assert_includes content, "## Summary"
    assert_includes content, "<details>"
  end

  def test_recurrence_suppressed_then_commented
    post(Fixture.event.to_json)
    status, _, body = post(Fixture.event.to_json) # notice_interval=0, but...
    # ...second hit sees issue_pending and last_notice_at just set -> still
    # due (0 interval) -> commented
    resp = JSON.parse(body.join)
    assert_equal 200, status
    assert_equal "commented", resp["action"]
    assert_equal 2, resp["count"]
    files = outbox_files
    assert_equal 2, files.size
    comment_file = files.find { |f| File.basename(f).start_with?("comment-") }
    refute_nil comment_file
    assert_includes File.read(comment_file), "New occurrences since last notice: 1"
  end

  def test_distinct_error_opens_second_issue
    post(Fixture.event.to_json)
    other = Fixture.event(id: "deadbeef-0000-4000-8000-000000000000", type: "RuntimeError", value: "kaput")
    _, _, body = post(other.to_json)
    resp = JSON.parse(body.join)
    assert_equal "opened", resp["action"]
    assert_equal 2, outbox_files.size
    assert @app.store.tracked == 2
  end

  def test_envelope_payload
    event = Fixture.event
    project_id = "7"
    header = { "event_id" => event["event_id"], "dsn" => "https://k@my-host.local/#{project_id}",
               "sent_at" => "2026-09-19T12:00:00Z", "sdk" => "sentry.ruby" }
    item_header = { "type" => "event", "content_type" => "application/json" }
    # plus a session item that must be ignored
    wire = [JSON.generate(header), JSON.generate(item_header), event.to_json,
            JSON.generate("type" => "session"), JSON.generate("seq" => 1)].join("\n")

    status, _, body = post(wire)
    resp = JSON.parse(body.join)
    assert_equal 200, status
    assert_equal "opened", resp["action"]
    assert_equal project_id, resp["project"], "project comes from the DSN in the envelope header"
    assert_equal 1, outbox_files.size
  end

  def test_envelope_only_with_sessions_is_rejected
    header = { "event_id" => "x", "sent_at" => "2026-09-19T12:00:00Z" }
    wire = [JSON.generate(header), JSON.generate("type" => "session"), JSON.generate("seq" => 1)].join("\n")
    status, = post(wire)
    assert_equal 400, status
  end

  def test_garbage_rejected
    status, _, body = post("not json at all")
    assert_equal 400, status
    assert_includes JSON.parse(body.join)["error"], "unrecognized"
  end

  def test_event_without_exception_or_message_is_rejected
    # every such event would otherwise collide on the digest of the empty
    # fingerprint, merging unrelated payloads into one ticket
    status, _, body = post({ "event_id" => "x" }.to_json)
    assert_equal 400, status
    assert_equal "event has no exception or message", JSON.parse(body.join)["error"]

    status, = post({ "message" => "   " }.to_json)
    assert_equal 400, status
  end

  def test_malformed_exception_shapes_are_sanitized_not_500
    payloads = [
      '{"message":"m1","exception":"garbage"}',
      '{"message":"m2","exception":{"values":[{"type":"E","stacktrace":"garbage"}]}}',
      '{"message":"m3","exception":{"values":[7]}}',
      '{"message":"m4","exception":{"values":[]}}',
      '{"exception":{"values":[{"type":"E1","value":"v","stacktrace":{"frames":[1]}}]}}',
      '{"exception":{"values":[{"type":"E2","value":"v","stacktrace":{"frames":[{"pre_context":"garbage","context_line":"  boom","post_context":"garbage"}]}}]}}',
      '{"message":"m5","breadcrumbs":{"values":"garbage"}}',
      '{"message":"m6","request":{"env":"garbage"},"contexts":"garbage"}'
    ]
    payloads.each do |raw|
      status, _, body = post(raw)
      assert_equal 200, status, raw
      assert_equal "opened", JSON.parse(body.join)["action"], raw
    end
    assert_equal payloads.size, outbox_files.size, "each sanitized event opens its own ticket"
  end

  def test_utf8_labeled_body_with_non_ascii_content_is_accepted
    event = Fixture.event
    event["extra"] = { "note" => "café über ✓" }
    status, _, resp_body = post(event.to_json) # UTF-8-labeled, raw non-ASCII bytes
    assert_equal 200, status
    assert_equal "opened", JSON.parse(resp_body.join)["action"]
    assert_includes File.read(outbox_files.first), "café über ✓"
  end

  def test_invalid_utf8_in_json_keys_is_scrubbed
    body = (+"{\"caf\xE9\":1,\"message\":\"ok\"}").force_encoding(Encoding::UTF_8)
    status, _, resp_body = post(body)
    assert_equal 200, status
    outbox = File.read(outbox_files.first)
    assert_includes outbox, "caf\uFFFD", "invalid key bytes must be replaced, not crash or leak raw"
  end

  def test_envelope_event_without_signal_is_rejected
    header = { "event_id" => "x", "sent_at" => "2026-09-19T12:00:00Z" }
    wire = [JSON.generate(header), JSON.generate("type" => "event"), { "event_id" => "x" }.to_json].join("\n")
    status, _, body = post(wire)
    assert_equal 400, status
    assert_equal "event has no exception or message", JSON.parse(body.join)["error"]
  end

  def test_unknown_route_is_404
    status, _, body = get("/nope")
    assert_equal 404, status
    assert_equal "not found", JSON.parse(body.join)["error"]
  end

  def test_gzip_event_hash_is_accepted
    gz = Zlib.gzip(Fixture.event.to_json)
    status, _, body = post(gz)
    assert_equal 200, status
    assert_equal "opened", JSON.parse(body.join)["action"]
  end

  def test_gzip_envelope_is_accepted
    event = Fixture.event
    header = { "event_id" => event["event_id"], "dsn" => "https://k@my-host.local/7",
               "sent_at" => "2026-09-19T12:00:00Z" }
    item_header = { "type" => "event", "content_type" => "application/json" }
    wire = [JSON.generate(header), JSON.generate(item_header), event.to_json].join("\n")

    status, _, body = post(Zlib.gzip(wire))
    resp = JSON.parse(body.join)
    assert_equal 200, status
    assert_equal "opened", resp["action"]
    assert_equal "7", resp["project"]
  end

  def test_invalid_gzip_is_rejected_not_500
    status, _, body = post("\x1F\x8B".b + "not really gzip")
    assert_equal 400, status
    assert_includes JSON.parse(body.join)["error"], "unrecognized"
  end

  def test_non_utf8_bytes_do_not_break_the_pipeline
    raw = Fixture.event.to_json.sub('"pro"', '"pro\u00e9"') # valid escape, still exercises render
    status, _, body = post(raw)
    assert_equal 200, status
    assert_equal "opened", JSON.parse(body.join)["action"]
  end

  def test_binary_payload_bytes_are_scrubbed
    # A body with raw high bytes in a string parses (JSON.parse labels it
    # UTF-8 without validating) and used to crash JSON.pretty_generate.
    body = "{\"event_id\":\"e1\",\"message\":\"caf\xE9\",\"extra\":{\"blob\":\"\xFE\"}}".b
    status, _, resp_body = post(body)
    assert_equal 200, status
    resp = JSON.parse(resp_body.join)
    assert_equal "opened", resp["action"]
    outbox = File.read(outbox_files.first)
    assert_includes outbox, "caf\uFFFD" # replacement char, not a crash
  end

  def test_delivery_failure_is_recorded_and_retried
    app = SentryTickets::App.new(@config, github: FailingGitHub.new)
    status, _, body = post(Fixture.event.to_json, {}, app: app)
    resp = JSON.parse(body.join)
    assert_equal 200, status, "sender has handed off ownership; failure is recorded, not propagated"
    assert_equal "opened", resp["action"]
    assert_match(/502/, resp["issue_error"])

    status, _, body = post(Fixture.event.to_json, {}, app: app)
    resp = JSON.parse(body.join)
    assert_equal 200, status
    assert_equal "opened", resp["action"], "failed opens retry on the next occurrence"
    assert_equal 2, resp["count"]
  end

  def test_concurrent_same_fingerprint_opens_one_issue
    dir = Fixture.store_dir
    config = SentryTickets::Config.new(repo: "x/y", token: "t", data_dir: dir, notice_interval: 3600)
    github = SlowGitHub.new
    app = SentryTickets::App.new(config, github: github)

    threads = 5.times.map do
      Thread.new { post(Fixture.event.to_json, {}, app: app) }
    end
    threads.each(&:join)

    assert_equal 5, app.store.all.first["count"]
    assert_equal 1, github.opens, "concurrent first occurrences must open exactly one issue"
    assert_equal 0, github.comments
  end

  def test_health_with_no_events
    status, _, body = get("/health")
    assert_equal 200, status
    health = JSON.parse(body.join)
    assert_equal 0, health["tracked"]
    assert_equal SentryTickets::VERSION, health["version"]
  end

  def test_health_and_issues
    post(Fixture.event.to_json)
    status, _, body = get("/health")
    assert_equal 200, status
    health = JSON.parse(body.join)
    assert_equal "ok", health["status"]
    assert health["dry_run"]
    assert_equal 1, health["tracked"]

    status, _, body = get("/issues")
    assert_equal 200, status
    issues = JSON.parse(body.join)
    assert_equal 1, issues.size
    assert_equal "NoMethodError: undefined method `name' for nil:NilClass", issues.first["title"]
  end

  def test_project_header_on_raw_hash
    _, _, body = post(Fixture.event.to_json, { "HTTP_X_SENTRY_PROJECT" => "42" })
    resp = JSON.parse(body.join)
    assert_equal "42", resp["project"]
  end
end
