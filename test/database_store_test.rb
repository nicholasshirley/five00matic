# frozen_string_literal: true

require_relative "database_helper"

class DatabaseStoreTest < Minitest::Test
  T0 = Time.utc(2026, 9, 19, 12)
  CLAIM = Five00Matic::DatabaseStore::CLAIM_SECONDS

  def setup
    Five00Matic::GroupRecord.delete_all
    @store = Five00Matic::DatabaseStore.new
    @fingerprint = Fixture.event.fingerprint
  end

  def test_record_starts_a_group_then_counts_it
    first = @store.record(Fixture.event, at: T0)
    assert_equal 1, first.count
    assert_equal T0.iso8601, first.first_seen
    assert_equal 2, @store.record(Fixture.event, at: T0 + 60).count
    assert_equal 1, Five00Matic::GroupRecord.count
  end

  def test_a_group_reads_back_as_it_was_written
    @store.record(Fixture.event, at: T0)
    issue = { "repo" => "you/app", "number" => 9, "url" => "https://github.com/you/app/issues/9" }
    written = @store.update(@fingerprint) { |group| group.delivered(issue, at: T0 + 60).failed("GitHub API 502: boom") }
    assert_equal written, @store.find(@fingerprint)
  end

  def test_find_answers_nil_for_a_fingerprint_never_recorded
    assert_nil @store.find(@fingerprint)
  end

  def test_records_from_concurrent_threads_are_all_counted
    10.times.map { Thread.new { 10.times { @store.record(Fixture.event, at: T0) } } }.each(&:join)
    assert_equal 100, @store.find(@fingerprint).count
  end

  def test_a_claim_runs_the_block_with_the_group
    @store.record(Fixture.event, at: T0)
    assert_equal 1, @store.claim(@fingerprint, now: T0) { |group| group.count }
  end

  def test_a_claim_turns_away_other_deliveries_until_released
    @store.record(Fixture.event, at: T0)
    @store.claim(@fingerprint, now: T0) do
      assert_nil @store.claim(@fingerprint, now: T0 + 60) { flunk "ran beside the claim's holder" }
    end
    assert_equal :next, @store.claim(@fingerprint, now: T0 + 60) { :next }
  end

  def test_a_claim_is_released_when_its_delivery_raises
    @store.record(Fixture.event, at: T0)
    assert_raises(RuntimeError) { @store.claim(@fingerprint, now: T0) { raise "boom" } }
    assert_equal :next, @store.claim(@fingerprint, now: T0) { :next }
  end

  def test_a_claim_lapses_for_a_holder_that_died
    @store.record(Fixture.event, at: T0)
    @store.claim(@fingerprint, now: T0) do
      assert_equal :taken, @store.claim(@fingerprint, now: T0 + CLAIM + 1) { :taken }
    end
  end

  def test_a_lapsed_holder_finishing_leaves_its_successors_claim_standing
    @store.record(Fixture.event, at: T0)
    holding = Queue.new
    finish = Queue.new
    lapsed = Thread.new do
      @store.claim(@fingerprint, now: T0) do
        holding << true
        finish.pop
      end
    end
    holding.pop

    @store.claim(@fingerprint, now: T0 + CLAIM + 1) do
      finish << true
      lapsed.join
      assert_nil @store.claim(@fingerprint, now: T0 + CLAIM + 2) { flunk "the successor's claim was released" }
    end
  end

  def test_concurrent_deliveries_of_one_fingerprint_run_one_at_a_time
    @store.record(Fixture.event, at: T0)
    ran = Queue.new
    5.times.map do
      Thread.new do
        @store.claim(@fingerprint) do
          ran << true
          sleep 0.2
        end
      end
    end.each(&:join)
    assert_equal 1, ran.size
  end
end
