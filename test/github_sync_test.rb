# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class GitHubSyncTest < Minitest::Test
  def setup
    @outbox = Fixture.store_dir
  end

  def sync(repo: "you/repo", token: "t")
    SentryTickets::GitHubSync.new(repo: repo, token: token, outbox_dir: @outbox)
  end

  def test_dry_run_without_token_or_repo
    assert SentryTickets::GitHubSync.new(repo: "you/repo", token: nil, outbox_dir: @outbox).dry_run?
    assert SentryTickets::GitHubSync.new(repo: nil, token: "t", outbox_dir: @outbox).dry_run?
    refute sync.dry_run?
  end

  def test_open_issue_dry_run_writes_outbox
    r = SentryTickets::GitHubSync.new(repo: nil, token: nil, outbox_dir: @outbox)
             .open_issue(title: "boom", body: "the body")
    assert_match %r{\Aissue-boom\.[0-9a-f]{8}\.\d{8}-\d{6}\.md\z}, File.basename(r["outbox"])
    assert_equal "# boom\n\nthe body\n", File.read(r["outbox"])
    assert_nil r["number"]
  end

  def test_comment_dry_run_subject_reflects_issue_number
    out = SentryTickets::GitHubSync.new(repo: nil, token: nil, outbox_dir: @outbox)
    out.comment(number: 7, body: "text")
    assert_includes File.read(Dir[File.join(@outbox, "comment-*.md")].first), "notice for #7"

    out.comment(number: nil, body: "text")
    files = Dir[File.join(@outbox, "comment-*.md")]
    assert_equal 2, files.size
    assert_includes File.read(files.last), "recurrence notice"
  end

  def test_same_slug_distinct_bodies_do_not_overwrite
    client = SentryTickets::GitHubSync.new(repo: nil, token: nil, outbox_dir: @outbox)
    long = "NoMethodError: undefined method `#{'x' * 40}' for nil:NilClass"
    client.open_issue(title: long, body: "first")
    client.open_issue(title: long.sub("x", "y"), body: "second")

    files = Dir[File.join(@outbox, "issue-*.md")]
    assert_equal 2, files.size, "distinct issues must not share an outbox file"
    refute_equal files[0], files[1]
  end

  def test_outbox_files_are_owner_readable_only
    r = SentryTickets::GitHubSync.new(repo: nil, token: nil, outbox_dir: @outbox)
              .open_issue(title: "boom", body: "the body")
    assert_equal 0o600, File.stat(r["outbox"]).mode & 0o777
  end

  def test_unwritable_outbox_wraps_as_delivery_error
    file = File.join(Dir.mktmpdir, "a-file")
    File.write(file, "x")
    client = SentryTickets::GitHubSync.new(repo: nil, token: nil, outbox_dir: File.join(file, "nope"))
    error = assert_raises(SentryTickets::DeliveryError) do
      client.open_issue(title: "t", body: "b")
    end
    assert error.message.valid_encoding?
  end

  def test_delivery_error_messages_are_valid_utf8
    # Net::HTTP labels bodies binary; valid multibyte text must survive and
    # invalid bytes must not reach the JSON state file.
    assert_equal "GitHub API 422: café", SentryTickets::DeliveryError.new("GitHub API 422: café".b).message
    assert_equal "boom: ��", SentryTickets::DeliveryError.new("boom: \xFF\xFE".b).message
  end

  def test_slugify
    assert_equal "nomethoderror-undefined-method-name-for-nil-nilclass-nometho",
                 SentryTickets::GitHubSync.slugify("NoMethodError: undefined method `name' for nil:NilClass (NoMethodError)")
    assert_equal "a-b", SentryTickets::GitHubSync.slugify("  A_B  ")
  end

  def test_network_error_wraps_as_delivery_error
    client = SentryTickets::GitHubSync.new(
      repo: "you/repo", token: "t", api_base: "http://127.0.0.1:1", outbox_dir: @outbox
    )
    error = assert_raises(SentryTickets::DeliveryError) do
      client.open_issue(title: "t", body: "b")
    end
    assert_match(/connection refused/i, error.message)
  end

  # A middlebox can answer GitHub's 2xx with a non-JSON, non-UTF-8 body; the
  # JSON::ParserError message then carries raw bytes, and would otherwise
  # land in state and break every future persist.
  def test_garbage_success_body_wraps_with_valid_utf8_message
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    t = Thread.new do
      sock = server.accept
      sock.gets
      headers = {}
      headers[$1.downcase] = $2.strip while (line = sock.gets) != "\r\n" && line =~ /\A([^:]+): (.*)\z/
      sock.read(headers["content-length"].to_i) if headers["content-length"]
      sock.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 6\r\n" \
                 "Connection: close\r\n\r\n"
      sock.write "\xFF\xFEbad!".b
      sock.close
    end

    client = SentryTickets::GitHubSync.new(
      repo: "you/repo", token: "t", api_base: "http://127.0.0.1:#{port}", outbox_dir: @outbox
    )
    error = assert_raises(SentryTickets::DeliveryError) do
      client.open_issue(title: "t", body: "b")
    end
    assert error.message.valid_encoding?,
           "wrapped error must be valid UTF-8, got #{error.message.inspect}"
  ensure
    t.join
    server.close
  end
end
