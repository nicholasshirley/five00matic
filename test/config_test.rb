# frozen_string_literal: true

require_relative "test_helper"
require "pathname"

class ConfigTest < Minitest::Test
  KEYS = %w[TICKET_REPO TICKET_TOKEN GITHUB_REPO GITHUB_TOKEN TICKET_APP_ID TICKET_APP_KEY TICKET_APP_KEY_FILE
            TICKET_LABELS TICKET_NOTICE_INTERVAL TICKET_DATA_DIR TICKET_API_BASE].freeze

  def setup
    @saved = KEYS.to_h { |k| [k, ENV[k]] }
    KEYS.each { |k| ENV.delete(k) }
  end

  def teardown
    @saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def pem = Fixture.private_key.to_pem

  def test_defaults
    c = Five00Matic::Config.new
    assert_nil c.repo
    assert_nil c.token
    assert_nil c.app_id
    assert_nil c.private_key
    assert_nil c.credentials
    assert_equal ["error-report"], c.labels
    assert_equal 21_600, c.notice_interval
    assert_equal "https://api.github.com", c.api_base
    assert_equal File.join(Dir.pwd, "data"), c.data_dir
  end

  def test_labels_are_split_stripped_and_filtered
    ENV["TICKET_LABELS"] = "error-report, p1 ,,need-triage"
    assert_equal ["error-report", "p1", "need-triage"], Five00Matic::Config.new.labels
  end

  def test_api_base_trailing_slash_is_removed
    ENV["TICKET_API_BASE"] = "https://ghe.example.com/api/v3/"
    assert_equal "https://ghe.example.com/api/v3", Five00Matic::Config.new.api_base
  end

  def test_data_dir_accepts_a_pathname
    assert_equal "/srv/app/storage/five00matic",
                 Five00Matic::Config.new(data_dir: Pathname.new("/srv/app/storage/five00matic")).data_dir
  end

  def test_github_env_fallbacks
    ENV["GITHUB_REPO"] = "fallback/repo"
    ENV["GITHUB_TOKEN"] = "gh-token"
    c = Five00Matic::Config.new
    assert_equal "fallback/repo", c.repo
    assert_equal "gh-token", c.token

    ENV["TICKET_REPO"] = "primary/repo"
    ENV["TICKET_TOKEN"] = "ticket-token"
    c = Five00Matic::Config.new
    assert_equal "primary/repo", c.repo, "TICKET_* wins over GITHUB_*"
    assert_equal "ticket-token", c.token
  end

  def test_blank_env_values_are_nil
    ENV["TICKET_REPO"] = "   "
    ENV["TICKET_TOKEN"] = ""
    ENV["TICKET_APP_ID"] = " "
    c = Five00Matic::Config.new
    assert_nil c.repo
    assert_nil c.token
    assert_nil c.app_id
  end

  def test_dry_run_without_repo_and_credentials
    assert Five00Matic::Config.new(repo: "you/repo", token: nil).dry_run?
    assert Five00Matic::Config.new(repo: nil, token: "t").dry_run?
    refute Five00Matic::Config.new(repo: "you/repo", token: "t").dry_run?
    assert Five00Matic::Config.new(repo: "you/repo", token: nil, app_id: "1", private_key: nil).dry_run?,
           "an app id without its key cannot authenticate"
    refute Five00Matic::Config.new(repo: "you/repo", token: nil, app_id: "1", private_key: pem).dry_run?
  end

  def test_credentials_are_the_token_or_else_the_app
    c = Five00Matic::Config.new(repo: "you/repo", token: "t", app_id: "1", private_key: pem)
    assert_equal Five00Matic::Token.new(token: "t"), c.credentials, "a token wins over the app"

    c = Five00Matic::Config.new(repo: "you/repo", token: nil, app_id: "1", private_key: pem)
    assert_kind_of Five00Matic::AppToken, c.credentials
    assert_same c.credentials, c.credentials, "one app identity, so its token cache is shared"
  end

  def test_app_key_from_env_text_or_file
    ENV["TICKET_APP_ID"] = "1"
    ENV["TICKET_APP_KEY_FILE"] = File.join(Fixture.store_dir, "app.pem").tap { |path| File.write(path, pem) }
    assert_equal pem, Five00Matic::Config.new.private_key

    ENV["TICKET_APP_KEY"] = "-----BEGIN inline-----"
    assert_equal "-----BEGIN inline-----", Five00Matic::Config.new.private_key, "the text wins over the file"
  end

  def test_notice_interval_from_env_is_an_integer
    ENV["TICKET_NOTICE_INTERVAL"] = "3600"
    assert_equal 3600, Five00Matic::Config.new.notice_interval
  end
end
