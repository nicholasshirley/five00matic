# frozen_string_literal: true

require_relative "database_helper"
require "active_job"
require "logger"

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(nil)

class DeliveryJobTest < Minitest::Test
  # Opens fail while down is set.
  class FlakyGitHub
    attr_reader :opens
    attr_accessor :down

    def initialize
      @opens = []
    end

    def owns?(issue) = !issue.nil?

    def open_issue(title:, body:)
      raise Five00Matic::DeliveryError, "GitHub API 502: boom" if down

      @opens << title
      { "number" => @opens.size, "url" => "http://gh/#{@opens.size}" }
    end
  end

  def setup
    Five00Matic::GroupRecord.delete_all
    @dir = Fixture.store_dir
    adapter.enqueued_jobs.clear
  end

  def teardown
    Five00Matic.queued_tracker = nil
  end

  def adapter = ActiveJob::Base.queue_adapter

  def issue_files = Dir[File.join(@dir, "outbox", "issue-*.md")]

  def queue_through(destination)
    tracker = Five00Matic::Tracker.new(store: Five00Matic::DatabaseStore.new, destination: destination,
                                       notice_interval: 0)
    Five00Matic.queued_tracker = Five00Matic::QueuedTracker.new(
      tracker: tracker, enqueue: ->(*job) { Five00Matic::DeliveryJob.perform_later(*job) }
    )
  end

  def last_error = Five00Matic.queued_tracker.tracker.store.find(Fixture.event.fingerprint).last_error

  # Runs the jobs queued so far, as a worker picking them up would.
  def work_off
    jobs = adapter.enqueued_jobs.dup
    adapter.enqueued_jobs.clear
    jobs.each { |job| ActiveJob::Base.execute(job) }
  end

  def test_before_send_queues_from_the_hook_and_the_job_delivers
    hook = Five00Matic.before_send(repo: nil, token: nil, data_dir: @dir, notice_interval: 0, mode: :replace,
                                   delivery: :active_job)
    assert_nil hook.call(FakeErrorEvent.new(Fixture.payload))
    assert_empty issue_files, "the hook's thread files nothing"
    assert_equal [Five00Matic::DeliveryJob], adapter.enqueued_jobs.map { |job| job[:job] }

    work_off
    assert_equal 1, issue_files.size
  end

  def test_a_failed_delivery_is_retried_until_it_lands
    github = FlakyGitHub.new
    github.down = true
    queue_through(github).track(Fixture.event)
    work_off
    assert adapter.enqueued_jobs.first[:at], "the retry waits"
    assert_match(/502/, last_error)

    github.down = false
    work_off
    assert_equal 1, github.opens.size
    assert_empty adapter.enqueued_jobs
    assert_nil last_error
  end

  def test_retries_stop_after_ten_attempts_and_leave_the_failure_on_the_group
    github = FlakyGitHub.new
    github.down = true
    queue_through(github).track(Fixture.event)
    attempts = 0
    until adapter.enqueued_jobs.empty? || attempts > 20
      attempts += 1
      work_off # raises if the last attempt did
    end
    assert_equal 10, attempts
    assert_match(/502/, last_error)
  end

  def test_a_delivery_that_finds_the_claim_held_leaves_it_to_the_holder
    github = FlakyGitHub.new
    tracker = queue_through(github)
    tracker.track(Fixture.event)
    tracker.tracker.store.claim(Fixture.event.fingerprint) { work_off }
    assert_empty github.opens
    assert_empty adapter.enqueued_jobs, "not retried"
  end

  def test_a_job_with_no_tracker_to_deliver_with_fails
    Five00Matic::DeliveryJob.perform_later("fingerprint", "{}")
    error = assert_raises(RuntimeError) { work_off }
    assert_match(/delivery: :active_job/, error.message)
  end
end
