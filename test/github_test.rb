# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class GitHubTest < Minitest::Test
  def github(api_base)
    SentryTickets::GitHub.new(repo: "you/repo", token: "t", labels: ["error-report"], api_base: api_base)
  end

  # Serves one canned HTTP response, and yields the API base to point at it.
  def answering(status_line, body)
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      sock = server.accept
      sock.gets
      length = 0
      while (line = sock.gets) != "\r\n"
        name, value = line.split(":", 2)
        length = value.to_i if name.casecmp?("content-length")
      end
      # Read the whole request: closing with it unread resets the connection.
      sock.read(length)
      sock.write "HTTP/1.1 #{status_line}\r\nContent-Type: application/json\r\n" \
                 "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n"
      sock.write body
      sock.close
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    thread.join
    server.close
  end

  def test_owns_only_issues_github_numbered
    assert github("http://unused").owns?({ "number" => 7, "url" => "https://github.com/you/repo/issues/7" })
    refute github("http://unused").owns?({ "url" => "/data/outbox/issue-boom.md" }), "an outbox issue is not GitHub's"
    refute github("http://unused").owns?(nil)
  end

  def test_comment_on_a_missing_issue_raises_issue_gone
    answering("404 Not Found", '{"message":"Not Found"}') do |api_base|
      assert_raises(SentryTickets::IssueGone) { github(api_base).comment({ "number" => 7 }, body: "b") }
    end
  end

  def test_network_error_wraps_as_delivery_error
    error = assert_raises(SentryTickets::DeliveryError) do
      github("http://127.0.0.1:1").open_issue(title: "t", body: "b")
    end
    assert_match(/connection refused/i, error.message)
  end

  # A middlebox can answer GitHub's 2xx with a non-JSON, non-UTF-8 body; the
  # JSON::ParserError message then carries raw bytes, and would otherwise
  # land in state and break every future persist.
  def test_garbage_success_body_wraps_with_valid_utf8_message
    answering("200 OK", "\xFF\xFEbad!".b) do |api_base|
      error = assert_raises(SentryTickets::DeliveryError) do
        github(api_base).open_issue(title: "t", body: "b")
      end
      assert_match(/JSON::ParserError/, error.message)
      assert error.message.valid_encoding?, "wrapped error must be valid UTF-8, got #{error.message.inspect}"
    end
  end

  def test_delivery_error_messages_are_valid_utf8
    # Net::HTTP labels bodies binary; valid multibyte text must survive and
    # invalid bytes must not reach the JSON state file.
    assert_equal "GitHub API 422: café", SentryTickets::DeliveryError.new("GitHub API 422: café".b).message
    assert_equal "boom: \uFFFD\uFFFD", SentryTickets::DeliveryError.new("boom: \xFF\xFE".b).message
  end
end
