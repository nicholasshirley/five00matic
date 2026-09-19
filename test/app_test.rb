# frozen_string_literal: true

require_relative "test_helper"

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

  def test_event_hash_opens_issue_in_outbox
    status, headers, body = post(Fixture.payload.to_json)
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

  def test_recurrence_comments_when_notice_is_due
    post(Fixture.payload.to_json)
    status, _, body = post(Fixture.payload.to_json) # notice_interval=0, but...
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
    post(Fixture.payload.to_json)
    other = Fixture.payload(id: "deadbeef-0000-4000-8000-000000000000", type: "RuntimeError", message: "kaput")
    _, _, body = post(other.to_json)
    resp = JSON.parse(body.join)
    assert_equal "opened", resp["action"]
    assert_equal 2, outbox_files.size
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

  def test_malformed_shapes_are_tolerated_not_500
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
    assert_equal payloads.size, outbox_files.size, "each event opens its own ticket"
  end

  def test_utf8_labeled_body_with_non_ascii_content_is_accepted
    event = Fixture.payload
    event["extra"] = { "note" => "café über ✓" }
    status, _, resp_body = post(event.to_json) # UTF-8-labeled, raw non-ASCII bytes
    assert_equal 200, status
    assert_equal "opened", JSON.parse(resp_body.join)["action"]
    assert_includes File.read(outbox_files.first), "café über ✓"
  end

  def test_payloads_the_sdk_could_not_have_built_are_rejected
    # JSON.parse lets these through but JSON.generate refuses them, and the
    # ticket and state file are both written with JSON.generate.
    invalid_utf8_key = (+"{\"caf\xE9\":1,\"message\":\"ok\"}").force_encoding(Encoding::UTF_8)
    binary_value = "{\"message\":\"caf\xE9\"}".b
    infinite = Fixture.payload(breadcrumbs: [Fixture.breadcrumb("http", "GET /x")]).to_json.sub("1758268800.123", "1e999")
    [invalid_utf8_key, binary_value, infinite].each do |body|
      status, _, resp_body = post(body)
      assert_equal 400, status, body
      assert_equal "payload holds invalid UTF-8 or a non-finite number", JSON.parse(resp_body.join)["error"]
    end
    assert_empty outbox_files
  end

  def test_unknown_route_is_404
    status, _, body = get("/nope")
    assert_equal 404, status
    assert_equal "not found", JSON.parse(body.join)["error"]
  end

  def test_escaped_unicode_in_json_payload_is_accepted
    raw = Fixture.payload.to_json.sub('"pro"', '"proé"') # valid escape, still exercises render
    status, _, body = post(raw)
    assert_equal 200, status
    assert_equal "opened", JSON.parse(body.join)["action"]
  end

  def test_dry_run_outbox_failure_is_recorded_not_500
    dir = Fixture.store_dir
    File.write(File.join(dir, "outbox"), "x") # outbox path taken by a file
    app = SentryTickets::App.new(
      SentryTickets::Config.new(repo: nil, token: nil, data_dir: dir, notice_interval: 0)
    )
    status, _, body = post(Fixture.payload.to_json, {}, app: app)
    resp = JSON.parse(body.join)
    assert_equal 200, status
    assert_equal "opened", resp["action"]
    assert_match(/EEXIST|not a directory/i, resp["issue_error"])
    assert_equal 1, resp["count"], "the event is durably counted even when the outbox is not"
  end

  def test_health_with_no_events
    status, _, body = get("/health")
    assert_equal 200, status
    health = JSON.parse(body.join)
    assert_equal 0, health["tracked"]
    assert_equal SentryTickets::VERSION, health["version"]
  end

  def test_health_and_issues
    post(Fixture.payload.to_json)
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
end
