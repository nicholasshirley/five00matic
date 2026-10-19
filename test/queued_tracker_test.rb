# frozen_string_literal: true

require_relative "database_helper"

class QueuedTrackerTest < Minitest::Test
  T0 = Time.utc(2026, 9, 19, 12)
  SIX_HOURS = 6 * 3600

  # Stands in for Five00Matic::GitHub, numbering the issues it opens from
  # 1. Every delivery fails while down is set, and opens take delay seconds.
  class CountingGitHub
    attr_reader :opens, :comments
    attr_accessor :down, :delay

    def initialize
      @opens = Queue.new
      @comments = []
    end

    def owns?(issue) = !issue.nil?

    def open_issue(title:, body:)
      sleep delay if delay
      raise Five00Matic::DeliveryError, "GitHub API 502: boom" if down

      number = (@opens << title).size
      { "number" => number, "url" => "http://gh/#{number}" }
    end

    def comment(issue, body:)
      raise Five00Matic::DeliveryError, "GitHub API 502: boom" if down

      @comments << issue["number"]
    end
  end

  def setup
    Five00Matic::GroupRecord.delete_all
    @github = CountingGitHub.new
    @queued = []
    tracker = Five00Matic::Tracker.new(store: Five00Matic::DatabaseStore.new, destination: @github,
                                       notice_interval: SIX_HOURS)
    @tracker = Five00Matic::QueuedTracker.new(tracker: tracker, enqueue: ->(*job) { @queued << job })
  end

  # Runs the deliveries queued so far, as their jobs would.
  def run_queued(now: T0)
    @queued.shift(@queued.size).map { |fingerprint, payload| @tracker.deliver(fingerprint, payload, now: now) }
  end

  def test_a_first_occurrence_is_recorded_and_its_issue_queued
    action, group = @tracker.track(Fixture.event, now: T0)
    assert_equal [:queued, 1], [action, group.count]
    assert_equal [[group.fingerprint, JSON.generate(Fixture.payload)]], @queued
    assert_equal 0, @github.opens.size, "nothing reaches GitHub from the hook's thread"
  end

  def test_the_queued_delivery_opens_the_issue_from_the_event
    @tracker.track(Fixture.event, now: T0)
    (action, group), = run_queued
    assert_equal :opened, action
    assert_equal "http://gh/1", group.issue_url
    assert_equal Fixture.event.title, @github.opens.pop
  end

  def test_a_recurrence_within_the_notice_interval_queues_nothing
    @tracker.track(Fixture.event, now: T0)
    run_queued
    action, group = @tracker.track(Fixture.event, now: T0 + 60)
    assert_equal [:suppressed, 2], [action, group.count]
    assert_empty @queued
  end

  def test_a_recurrence_after_the_notice_interval_queues_its_notice
    @tracker.track(Fixture.event, now: T0)
    run_queued
    @tracker.track(Fixture.event, now: T0 + SIX_HOURS)
    (action, group), = run_queued(now: T0 + SIX_HOURS)
    assert_equal :commented, action
    assert_equal [1], @github.comments
    assert_equal 2, group.last_notice_count
  end

  def test_deliveries_queued_by_a_burst_open_one_issue
    3.times { @tracker.track(Fixture.event, now: T0) }
    assert_equal 3, @queued.size, "every occurrence before the issue opens is owed it"
    assert_equal %i[opened suppressed suppressed], run_queued.map(&:first)
    assert_equal 1, @github.opens.size
  end

  def test_concurrent_deliveries_of_one_fingerprint_open_one_issue
    @github.delay = 0.2
    3.times { @tracker.track(Fixture.event, now: T0) }
    actions = @queued.map { |job| Thread.new { @tracker.deliver(*job, now: T0).first } }.map(&:value)
    assert_equal 1, @github.opens.size
    assert_equal 1, actions.count(:opened), "the others were turned away or found it open, got #{actions}"
  end

  def test_a_failed_delivery_is_kept_on_the_group
    @github.down = true
    @tracker.track(Fixture.event, now: T0)
    (action, group), = run_queued
    assert_equal :opened, action
    assert_match(/502/, group.last_error)
    assert_nil group.issue
  end
end
