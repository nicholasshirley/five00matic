# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  KEYS = %w[TICKET_REPO TICKET_TOKEN GITHUB_REPO GITHUB_TOKEN TICKET_LABELS
            TICKET_NOTICE_INTERVAL TICKET_DATA_DIR TICKET_API_BASE].freeze

  def setup
    @saved = KEYS.to_h { |k| [k, ENV[k]] }
    KEYS.each { |k| ENV.delete(k) }
  end

  def teardown
    @saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def test_defaults
    c = SentryTickets::Config.new
    assert_nil c.repo
    assert_nil c.token
    assert_equal ["error-report"], c.labels
    assert_equal 21_600, c.notice_interval
    assert_equal "https://api.github.com", c.api_base
    assert_equal File.join(Dir.pwd, "data"), c.data_dir
  end

  def test_labels_are_split_stripped_and_filtered
    ENV["TICKET_LABELS"] = "error-report, p1 ,,need-triage"
    assert_equal ["error-report", "p1", "need-triage"], SentryTickets::Config.new.labels
  end

  def test_api_base_trailing_slash_is_removed
    ENV["TICKET_API_BASE"] = "https://ghe.example.com/api/v3/"
    assert_equal "https://ghe.example.com/api/v3", SentryTickets::Config.new.api_base
  end

  def test_github_env_fallbacks
    ENV["GITHUB_REPO"] = "fallback/repo"
    ENV["GITHUB_TOKEN"] = "gh-token"
    c = SentryTickets::Config.new
    assert_equal "fallback/repo", c.repo
    assert_equal "gh-token", c.token

    ENV["TICKET_REPO"] = "primary/repo"
    ENV["TICKET_TOKEN"] = "ticket-token"
    c = SentryTickets::Config.new
    assert_equal "primary/repo", c.repo, "TICKET_* wins over GITHUB_*"
    assert_equal "ticket-token", c.token
  end

  def test_blank_env_values_are_nil
    ENV["TICKET_REPO"] = "   "
    ENV["TICKET_TOKEN"] = ""
    c = SentryTickets::Config.new
    assert_nil c.repo
    assert_nil c.token
  end

  def test_dry_run_without_both_repo_and_token
    assert SentryTickets::Config.new(repo: "you/repo", token: nil).dry_run?
    assert SentryTickets::Config.new(repo: nil, token: "t").dry_run?
    refute SentryTickets::Config.new(repo: "you/repo", token: "t").dry_run?
  end

  def test_notice_interval_from_env_is_an_integer
    ENV["TICKET_NOTICE_INTERVAL"] = "3600"
    assert_equal 3600, SentryTickets::Config.new.notice_interval
  end
end
