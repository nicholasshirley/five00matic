# frozen_string_literal: true

require_relative "test_helper"
require "socket"

class GitHubTest < Minitest::Test
  def github(api_base)
    SentryTickets::GitHub.new(repo: "you/repo", token: "t", labels: ["error-report"], api_base: api_base)
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

    error = assert_raises(SentryTickets::DeliveryError) do
      github("http://127.0.0.1:#{port}").open_issue(title: "t", body: "b")
    end
    assert error.message.valid_encoding?,
           "wrapped error must be valid UTF-8, got #{error.message.inspect}"
  ensure
    t.join
    server.close
  end

  def test_delivery_error_messages_are_valid_utf8
    # Net::HTTP labels bodies binary; valid multibyte text must survive and
    # invalid bytes must not reach the JSON state file.
    assert_equal "GitHub API 422: café", SentryTickets::DeliveryError.new("GitHub API 422: café".b).message
    assert_equal "boom: \uFFFD\uFFFD", SentryTickets::DeliveryError.new("boom: \xFF\xFE".b).message
  end
end
