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

# Delivers errors with raw binary bytes in the message, the way a wrapped
# JSON::ParserError on a middlebox's garbage response body would.
class BinaryErrorGitHub
  def open_issue(title:, body:)
    raise SentryTickets::DeliveryError, "boom: \xFF\xFE".b
  end

  def comment(number:, body:)
    raise SentryTickets::DeliveryError, "boom: \xFF\xFE".b
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
    sleep 0.2 # widen the record-before-deliver race window
    @mutex.synchronize { @opens += 1 }
    { "number" => @opens, "url" => "http://gh/#{@opens}" }
  end

  def comment(number:, body:)
    @mutex.synchronize { @comments += 1 }
  end
end

# open_issue succeeds; comment always 502s.
class BadCommentGitHub
  def dry_run? = false

  def open_issue(title:, body:) = { "number" => 7, "url" => "http://gh/7" }

  def comment(number:, body:)
    raise SentryTickets::DeliveryError.new("GitHub API 502: boom", status: 502)
  end
end

# Succeeds at open_issue but the comment endpoint 404s, as it does when the
# tracked issue was deleted on GitHub.
class GoneCommentGitHub
  attr_reader :opens, :comments

  def initialize
    @opens = []
    @comments = []
  end

  def dry_run? = false

  def open_issue(title:, body:)
    @opens << title
    { "number" => 100 + @opens.size, "url" => "http://gh/#{100 + @opens.size}" }
  end

  def comment(number:, body:)
    @comments << number
    raise SentryTickets::DeliveryError.new("GitHub API 404: Not Found", status: 404)
  end
end

class RecordingGitHub
  attr_reader :opens, :comments

  def initialize
    @opens = []
    @comments = []
  end

  def dry_run? = false

  def open_issue(title:, body:)
    @opens << title
    { "number" => 42, "url" => "http://gh/42" }
  end

  def comment(number:, body:)
    @comments << number
  end
end

class TrackerTest < Minitest::Test
  def tracker(destination, store: Fixture.store(Fixture.store_dir, 0))
    SentryTickets::Tracker.new(store: store, destination: destination)
  end

  def test_failed_open_is_recorded_and_retried_on_the_next_occurrence
    tracker = tracker(FailingGitHub.new)
    action, rec = tracker.track(Fixture.event)
    assert_equal :opened, action
    assert_match(/502/, rec["last_error"])

    action, rec = tracker.track(Fixture.event)
    assert_equal :opened, action, "failed opens retry on the next occurrence"
    assert_equal 2, rec["count"]
  end

  def test_comment_on_deleted_issue_opens_a_replacement
    github = GoneCommentGitHub.new
    tracker = tracker(github)
    tracker.track(Fixture.event)
    assert_equal 1, github.opens.size

    action, rec = tracker.track(Fixture.event)
    assert_equal :opened, action, "a 404 on comment opens a replacement issue"
    assert_nil rec["last_error"]
    assert_equal 2, github.opens.size
    assert_equal 101, github.comments.first, "the failed comment targeted the first issue"
    assert_equal 102, rec["issue_number"], "the replacement issue number replaces the dead one"
  end

  def test_comment_failure_does_not_open_a_replacement
    tracker = tracker(BadCommentGitHub.new)
    tracker.track(Fixture.event)

    action, rec = tracker.track(Fixture.event)
    assert_equal :commented, action
    assert_match(/502/, rec["last_error"])
    assert_equal 7, rec["issue_number"], "a transient comment failure must keep the issue number"
  end

  def test_concurrent_first_occurrences_open_one_issue
    github = SlowGitHub.new
    store = Fixture.store(Fixture.store_dir, 3600)
    tracker = tracker(github, store: store)

    5.times.map { Thread.new { tracker.track(Fixture.event) } }.each(&:join)

    assert_equal 5, store.all.first["count"]
    assert_equal 1, github.opens, "concurrent first occurrences must open exactly one issue"
    assert_equal 0, github.comments
  end

  def test_dry_run_state_opens_issue_when_delivery_becomes_real
    # README workflow: run without a token first, then "set repo + token and
    # restart". A fingerprint only ever opened in dry-run mode has no issue
    # number, so its first due recurrence must open, not comment on
    # /issues//comments.
    dir = Fixture.store_dir
    dry = tracker(SentryTickets::Outbox.new(File.join(dir, "outbox")), store: Fixture.store(dir, 3600))
    dry.track(Fixture.event)

    github = RecordingGitHub.new
    real = tracker(github, store: Fixture.store(dir, 0))
    action, rec = real.track(Fixture.event)
    assert_equal :opened, action
    assert_equal 1, github.opens.size
    assert_empty github.comments
    assert_equal "http://gh/42", rec["issue_url"]

    action, = real.track(Fixture.event)
    assert_equal :commented, action, "follow-up recurrences comment on the real issue"
    assert_equal [42], github.comments
  end

  def test_delivery_error_with_binary_message_does_not_wedge_state
    tracker = tracker(BinaryErrorGitHub.new)
    _, rec = tracker.track(Fixture.event)
    assert_match(/boom/, rec["last_error"])

    action, = tracker.track(Fixture.event(id: "e2", type: "RuntimeError", message: "other"))
    assert_equal :opened, action
  end
end
