# frozen_string_literal: true

require_relative "test_helper"

class StoreTest < Minitest::Test
  T0 = Time.utc(2026, 9, 19, 12)

  def test_record_starts_a_group_then_counts_it
    store = Fixture.store
    first = store.record(Fixture.event, at: T0)
    assert_equal 1, first.count
    assert_equal T0.iso8601, first.first_seen
    assert_equal 2, store.record(Fixture.event, at: T0 + 60).count
    assert_equal 1, store.size
  end

  def test_update_replaces_the_group
    store = Fixture.store
    fingerprint = store.record(Fixture.event, at: T0).fingerprint
    assert_equal "boom", store.update(fingerprint) { |group| group.failed("boom") }.last_error
    assert_equal "boom", store.groups.first.last_error
  end

  def test_groups_are_ordered_most_recently_seen_first
    store = Fixture.store
    store.record(Fixture.event(id: "a"), at: T0)
    store.record(Fixture.event(id: "b", type: "RuntimeError"), at: T0 + 1)
    store.record(Fixture.event(id: "c", type: "ArgumentError"), at: T0 + 2)
    assert_equal %w[c b a], store.groups.map(&:last_event_id)
  end

  def test_persists_across_instances
    dir = Fixture.store_dir
    store = Fixture.store(dir)
    fingerprint = store.record(Fixture.event, at: T0).fingerprint
    store.update(fingerprint) { |group| group.delivered({ "number" => 9, "url" => "http://gh/9" }, at: T0) }

    reloaded = Fixture.store(dir)
    assert_equal 1, reloaded.size
    assert_equal store.groups.first, reloaded.groups.first
  end

  def test_file_is_owner_readable_only
    dir = Fixture.store_dir
    Fixture.store(dir).record(Fixture.event, at: T0)
    assert_equal 0o600, File.stat(File.join(dir, "groups.json")).mode & 0o777
  end
end
