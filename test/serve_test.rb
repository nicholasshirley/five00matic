# frozen_string_literal: true

require_relative "test_helper"
require "net/http"
require "rbconfig"
require "socket"

# End-to-end coverage for the documented zero-dependency entrypoint: env ->
# Config -> App over a real socket, including the hand-rolled HTTP parsing
# in bin/serve.rb.
class ServeTest < Minitest::Test
  SCRIPT = File.expand_path("../bin/serve.rb", __dir__)

  def setup
    @dir = Fixture.store_dir
    @port = free_port
    @log = File.join(@dir, "serve.log")
    @pid = Process.spawn(
      { "TICKET_HOST" => "127.0.0.1", "TICKET_PORT" => @port.to_s, "TICKET_DATA_DIR" => @dir },
      RbConfig.ruby, SCRIPT, out: @log, err: @log
    )
    wait_ready
  end

  def teardown
    return unless @pid

    begin
      Process.kill("TERM", @pid)
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.wait(@pid)
    rescue Errno::ECHILD
      nil
    end
  end

  def test_event_hash_opens_issue_in_outbox
    res = http_post(Fixture.event.to_json)
    assert_equal 200, res.code.to_i
    assert_equal "opened", JSON.parse(res.body)["action"]
    assert_equal 1, Dir[File.join(@dir, "outbox", "issue-*.md")].size

    health = JSON.parse(http_get("/health").body)
    assert_equal "ok", health["status"]
    assert_equal 1, health["tracked"]
    assert health["dry_run"]
    assert_equal SentryTickets::VERSION, health["version"]
  end

  def test_envelope_delivered_with_dsn_project
    event = Fixture.event
    wire = [
      JSON.generate("event_id" => event["event_id"], "dsn" => "https://k@my-host.local/7",
                    "sent_at" => "2026-09-19T12:00:00Z"),
      JSON.generate("type" => "event"),
      event.to_json
    ].join("\n")
    res = http_post(wire)
    assert_equal 200, res.code.to_i
    assert_equal "7", JSON.parse(res.body)["project"]
  end

  def test_garbage_is_400
    res = http_post("not json at all")
    assert_equal 400, res.code.to_i
    assert_includes JSON.parse(res.body)["error"], "unrecognized"
  end

  private

  def free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def wait_ready
    200.times do
      return http_get("/health")
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      alive = (Process.kill(0, @pid) && true) rescue false
      flunk "server exited during startup; log: #{File.read(@log)}" unless alive
      sleep 0.05
    end
    flunk "server never became ready; log: #{File.read(@log)}"
  end

  def http_get(path)
    Net::HTTP.start("127.0.0.1", @port) { |http| http.get(path) }
  end

  def http_post(body)
    Net::HTTP.start("127.0.0.1", @port) do |http|
      req = Net::HTTP::Post.new("/events")
      req["Content-Type"] = "application/json"
      req.body = body
      http.request(req)
    end
  end
end
