# frozen_string_literal: true

require_relative "test_helper"

# Stands in for Five00Matic::GitHub: every open files issue #42, and every
# comment lands. Subclasses break one part of that.
class FakeGitHub
  attr_reader :opens, :comments

  def initialize
    @opens = []
    @comments = []
  end

  def owns?(issue) = !issue.nil? && !issue["number"].nil?

  def open_issue(title:, body:)
    @opens << title
    { "number" => 42, "url" => "http://gh/42" }
  end

  def comment(issue, body:)
    @comments << issue["number"]
  end
end

class FailingGitHub < FakeGitHub
  def open_issue(title:, body:) = raise(Five00Matic::DeliveryError, "GitHub API 502: boom")
  def comment(issue, body:) = raise(Five00Matic::DeliveryError, "GitHub API 502: boom")
end

# Fails with raw binary bytes in the message, the way a wrapped
# JSON::ParserError on a middlebox's garbage response body would.
class BinaryErrorGitHub < FakeGitHub
  def open_issue(title:, body:) = raise(Five00Matic::DeliveryError, "boom: \xFF\xFE".b)
end

class SlowGitHub < FakeGitHub
  def open_issue(title:, body:)
    sleep 0.2 # widen the record-before-deliver race window
    super
  end
end

# An outbox whose opens take long enough for sibling processes to pile up
# inside them.
class SlowOutbox < Five00Matic::Outbox
  def open_issue(title:, body:)
    sleep 0.2
    super
  end
end

# Opens fine; every comment 502s.
class BadCommentGitHub < FakeGitHub
  def comment(issue, body:) = raise(Five00Matic::DeliveryError.new("GitHub API 502: boom", status: 502))
end

# Every comment finds its issue deleted. Opens are numbered 101, 102, ...
# and fail while fail_opens is set.
class GoneCommentGitHub < FakeGitHub
  attr_accessor :fail_opens

  def open_issue(title:, body:)
    raise Five00Matic::DeliveryError, "GitHub API 502: boom" if fail_opens

    @opens << title
    { "number" => 100 + @opens.size, "url" => "http://gh/#{100 + @opens.size}" }
  end

  def comment(issue, body:)
    @comments << issue["number"]
    raise Five00Matic::IssueGone, "GitHub API 404: Not Found"
  end
end

class TrackerTest < Minitest::Test
  T0 = Time.utc(2026, 9, 19, 12)
  SIX_HOURS = 6 * 3600

  def tracker(destination, store: Fixture.store, notice_interval: 0)
    Five00Matic::Tracker.new(store: store, destination: destination, notice_interval: notice_interval)
  end

  def test_first_occurrence_opens_an_issue
    github = FakeGitHub.new
    action, group = tracker(github).track(Fixture.event, now: T0)
    assert_equal :opened, action
    assert_equal 1, group.count
    assert_equal "http://gh/42", group.issue_url
    assert_equal 1, github.opens.size
  end

  def test_recurrence_within_the_notice_interval_is_suppressed
    github = FakeGitHub.new
    tracker = tracker(github, notice_interval: SIX_HOURS)
    tracker.track(Fixture.event, now: T0)
    action, group = tracker.track(Fixture.event, now: T0 + 3600)
    assert_equal :suppressed, action
    assert_equal 2, group.count
    assert_empty github.comments
  end

  def test_recurrence_after_the_notice_interval_comments
    github = FakeGitHub.new
    tracker = tracker(github, notice_interval: SIX_HOURS)
    tracker.track(Fixture.event, now: T0)
    action, = tracker.track(Fixture.event, now: T0 + SIX_HOURS + 1)
    assert_equal :commented, action
    assert_equal [42], github.comments
  end

  def test_suppressed_recurrences_do_not_move_the_notice_window
    tracker = tracker(FakeGitHub.new, notice_interval: SIX_HOURS)
    tracker.track(Fixture.event, now: T0)
    tracker.track(Fixture.event, now: T0 + 60)
    action, group = tracker.track(Fixture.event, now: T0 + SIX_HOURS)
    assert_equal :commented, action, "due against the T0 notice, not the suppressed occurrence"
    assert_equal 3, group.count
  end

  def test_failed_open_is_recorded_and_retried_on_the_next_occurrence
    tracker = tracker(FailingGitHub.new)
    action, group = tracker.track(Fixture.event)
    assert_equal :opened, action
    assert_match(/502/, group.last_error)

    action, group = tracker.track(Fixture.event)
    assert_equal :opened, action, "failed opens retry on the next occurrence"
    assert_equal 2, group.count
  end

  def test_comment_on_deleted_issue_opens_a_replacement
    github = GoneCommentGitHub.new
    tracker = tracker(github)
    tracker.track(Fixture.event)
    assert_equal 1, github.opens.size

    action, group = tracker.track(Fixture.event)
    assert_equal :opened, action, "a 404 on comment opens a replacement issue"
    assert_nil group.last_error
    assert_equal 2, github.opens.size
    assert_equal 101, github.comments.first, "the failed comment targeted the first issue"
    assert_equal 102, group.issue["number"], "the replacement issue number replaces the dead one"
  end

  def test_comment_failure_does_not_open_a_replacement
    tracker = tracker(BadCommentGitHub.new)
    tracker.track(Fixture.event)

    action, group = tracker.track(Fixture.event)
    assert_equal :commented, action
    assert_match(/502/, group.last_error)
    assert_equal 42, group.issue["number"], "a transient comment failure must keep the issue number"
  end

  def test_concurrent_first_occurrences_open_one_issue
    github = SlowGitHub.new
    store = Fixture.store
    tracker = tracker(github, store: store, notice_interval: 3600)

    5.times.map { Thread.new { tracker.track(Fixture.event) } }.each(&:join)

    assert_equal 5, store.groups.first.count
    assert_equal 1, github.opens.size, "concurrent first occurrences must open exactly one issue"
    assert_empty github.comments
  end

  def test_first_occurrences_in_separate_processes_open_one_issue
    dir = Fixture.store_dir
    outbox = File.join(dir, "outbox")
    pids = 3.times.map do
      fork do
        tracker(SlowOutbox.new(outbox), store: Fixture.store(dir)).track(Fixture.event)
        exit!(0)
      end
    end
    pids.each { |pid| assert_equal 0, Process.wait2(pid).last.exitstatus }

    files = Dir[File.join(outbox, "*.md")].map { |f| File.basename(f) }
    assert_equal 1, files.count { |f| f.start_with?("issue-") }, "one issue across processes, got #{files}"
    assert_equal 2, files.count { |f| f.start_with?("comment-") }, "the later occurrences become notices"
    assert_equal 3, Fixture.store(dir).groups.first.count
  end

  def test_dry_run_state_opens_issue_when_delivery_becomes_real
    # README workflow: run without a token first, then "set repo + token and
    # restart". An issue filed to the outbox is not one GitHub holds, so the
    # next occurrence opens a real one, notice window or not.
    dir = Fixture.store_dir
    dry = tracker(Five00Matic::Outbox.new(File.join(dir, "outbox")), store: Fixture.store(dir),
                                                                        notice_interval: SIX_HOURS)
    dry.track(Fixture.event, now: T0)

    github = FakeGitHub.new
    real = tracker(github, store: Fixture.store(dir), notice_interval: SIX_HOURS)
    action, group = real.track(Fixture.event, now: T0 + 60)
    assert_equal :opened, action
    assert_equal 1, github.opens.size
    assert_empty github.comments
    assert_equal "http://gh/42", group.issue_url

    action, = real.track(Fixture.event, now: T0 + 60 + SIX_HOURS)
    assert_equal :commented, action, "follow-up recurrences comment on the real issue"
    assert_equal [42], github.comments
  end

  def test_gone_issue_is_forgotten_even_when_its_replacement_fails_to_open
    github = GoneCommentGitHub.new
    tracker = tracker(github, notice_interval: SIX_HOURS)
    tracker.track(Fixture.event, now: T0)

    github.fail_opens = true
    action, group = tracker.track(Fixture.event, now: T0 + SIX_HOURS)
    assert_equal :opened, action
    assert_nil group.issue
    assert_match(/502/, group.last_error)

    github.fail_opens = false
    action, group = tracker.track(Fixture.event, now: T0 + SIX_HOURS + 60)
    assert_equal :opened, action
    assert_equal [101], github.comments, "the dead issue is not commented on again"
    assert_equal "http://gh/102", group.issue_url
  end

  def test_delivery_error_with_binary_message_does_not_wedge_state
    tracker = tracker(BinaryErrorGitHub.new)
    _, group = tracker.track(Fixture.event)
    assert_match(/boom/, group.last_error)

    action, = tracker.track(Fixture.event(id: "e2", type: "RuntimeError", message: "other"))
    assert_equal :opened, action
  end
end
