# frozen_string_literal: true

require_relative "test_helper"

# What the SDK hands a before_send hook, as far as the hook cares.
FakeErrorEvent = Struct.new(:payload) do
  def to_json_compatible = payload
end

# Collects what a hook logs.
FakeLogger = Struct.new(:lines) do
  def error(text) = lines << text
end

# A GitHub whose every open fails.
class DownGitHub
  def dry_run? = false
  def owns?(_issue) = false
  def open_issue(title:, body:) = raise(Five00Matic::DeliveryError, "GitHub API 502: boom")
end

class HookTest < Minitest::Test
  def setup
    @dir = Fixture.store_dir
    @outbox = File.join(@dir, "outbox")
    @tracker = Five00Matic.tracker(Five00Matic::Config.new(repo: nil, token: nil, data_dir: @dir, notice_interval: 0))
  end

  def issue_files = Dir[File.join(@outbox, "issue-*.md")]

  def test_shadow_returns_the_event_and_files_a_ticket
    event = FakeErrorEvent.new(Fixture.payload)
    assert_same event, Five00Matic::Hook.new(tracker: @tracker).call(event, {})
    assert_equal 1, issue_files.size
  end

  def test_replace_returns_nil_once_tracked
    hook = Five00Matic::Hook.new(tracker: @tracker, mode: :replace)
    assert_nil hook.call(FakeErrorEvent.new(Fixture.payload), {})
    assert_equal 1, issue_files.size
  end

  def test_replace_drops_the_event_even_when_delivery_failed
    # The occurrence is counted and the failure recorded for retry, so the
    # event is owned, the same contract as the HTTP receiver's 200.
    tracker = Five00Matic::Tracker.new(store: Fixture.store(@dir), destination: DownGitHub.new, notice_interval: 0)
    hook = Five00Matic::Hook.new(tracker: tracker, mode: :replace)
    assert_nil hook.call(FakeErrorEvent.new(Fixture.payload))
    assert_match(/502/, Fixture.store(@dir).groups.first.last_error)
  end

  def test_scrubbed_payload_is_what_gets_rendered
    payload = Fixture.payload
    payload["request"] = { "url" => "https://shop.example/login", "cookies" => { "_session" => "s3cret" },
                           "data" => { "password" => "hunter2" } }
    hook = Five00Matic::Hook.new(tracker: @tracker, scrubber: Five00Matic::Scrubber.new(FakeFilter.new))
    hook.call(FakeErrorEvent.new(payload))

    ticket = File.read(issue_files.first)
    refute_includes ticket, "s3cret"
    refute_includes ticket, "hunter2"
    assert_includes ticket, "[FILTERED]"
    assert_equal({ "_session" => "s3cret" }, payload["request"]["cookies"], "the SDK's own event is untouched")
  end

  def test_unreportable_event_goes_to_sentry_untracked
    event = FakeErrorEvent.new({ "event_id" => "x" })
    assert_same event, Five00Matic::Hook.new(tracker: @tracker, mode: :replace).call(event)
    assert_empty issue_files
  end

  def test_tracker_failure_is_logged_and_the_event_still_goes_to_sentry
    blocked = File.join(@dir, "blocked")
    File.write(blocked, "") # the data directory is a file: the store cannot even lock
    tracker = Five00Matic.tracker(Five00Matic::Config.new(repo: nil, token: nil, data_dir: blocked, notice_interval: 0))
    logger = FakeLogger.new([])
    event = FakeErrorEvent.new(Fixture.payload)
    assert_same event, Five00Matic::Hook.new(tracker: tracker, mode: :replace, logger: logger).call(event)
    assert_equal 1, logger.lines.size
    assert_match(/\A\[five00matic\] Errno::E/, logger.lines.first)
  end

  def test_unknown_mode_is_refused
    assert_raises(ArgumentError) { Five00Matic::Hook.new(tracker: @tracker, mode: :both) }
  end

  def test_before_send_builds_the_hook_from_config
    hook = Five00Matic.before_send(repo: nil, token: nil, data_dir: @dir, notice_interval: 0, mode: :replace,
                                   filter: FakeFilter.new)
    assert_nil hook.call(FakeErrorEvent.new(Fixture.payload))
    assert_equal 1, issue_files.size
  end
end
