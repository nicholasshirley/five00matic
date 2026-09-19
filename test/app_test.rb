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

  def post(body, headers = {})
    env = {
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/events",
      "QUERY_STRING" => "",
      "CONTENT_LENGTH" => body.bytesize.to_s,
      "rack.input" => StringIO.new(body)
    }.merge(headers)
    @app.call(env)
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
    _, _, body = post(Fixture.event.to_json, "HTTP_X_SENTRY_PROJECT" => "42")
    resp = JSON.parse(body.join)
    assert_equal "42", resp["project"]
  end
end
