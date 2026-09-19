#!/usr/bin/env ruby
# frozen_string_literal: true

# Standalone bootstrap with no gem dependencies beyond stdlib + rack:
#   ruby bin/serve.rb
# Honors TICKET_HOST (default 127.0.0.1) and TICKET_PORT (default 9292),
# plus all SentryTickets::Config env vars. For mounting into an existing
# Ruby app instead, use the App object directly via config.ru.
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "sentry_tickets"
require "socket"
require "stringio"

STATUS_TEXT = { 200 => "OK", 400 => "Bad Request", 404 => "Not Found", 500 => "Internal Server Error" }.freeze

def serve(client, app)
  request_line = client.gets
  return unless request_line

  method, raw_path = request_line.split
  path, query = raw_path.to_s.split("?", 2)

  headers = {}
  while (line = client.gets) && line != "\r\n" && !line.empty?
    k, v = line.split(": ", 2)
    headers[k.downcase] = v&.strip
  end

  body =
    if (len = headers["content-length"])
      client.read(len.to_i)
    else
      ""
    end

  env = {
    "REQUEST_METHOD" => method.to_s.upcase,
    "PATH_INFO" => path,
    "QUERY_STRING" => query.to_s,
    "CONTENT_LENGTH" => body.bytesize.to_s,
    "rack.input" => StringIO.new(body),
    "rack.url_scheme" => "http"
  }
  headers.each do |k, v|
    env["HTTP_#{k.upcase.tr("-", "_")}"] = v unless %w[host content-length].include?(k)
  end

  status, resp_headers, resp_body = app.call(env)
  out = resp_body.respond_to?(:each) ? resp_body.to_a.join : resp_body.to_s
  resp_body.close if resp_body.respond_to?(:close)

  client.write "HTTP/1.1 #{status} #{STATUS_TEXT[status] || "Status"}\r\n"
  client.write "Content-Type: #{resp_headers["Content-Type"]}\r\n"
  client.write "Content-Length: #{out.bytesize}\r\n"
  client.write "Connection: close\r\n\r\n"
  client.write out
rescue StandardError => e
  warn "[sentry-tickets] request error: #{e.class}: #{e.message}"
  begin
    client.write "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
  rescue StandardError
    nil
  end
end

config = SentryTickets::Config.new
app = SentryTickets::App.new(config)

# Bind first so the "listening" line never precedes a failed bind.
server = TCPServer.new(ENV.fetch("TICKET_HOST", "127.0.0.1"), ENV.fetch("TICKET_PORT", "9292").to_i)

$stderr.puts "[sentry-tickets] listening on http://#{ENV.fetch("TICKET_HOST", "127.0.0.1")}:#{ENV.fetch("TICKET_PORT", "9292")} " \
              "(dry_run=#{app.destination.dry_run?}, data=#{File.expand_path(config.data_dir)})"
trap("INT") { exit! }
trap("TERM") { exit! }

loop do
  client = server.accept
  Thread.new(client) do |c|
    serve(c, app)
  rescue StandardError => e
    warn "[sentry-tickets] connection error: #{e.class}: #{e.message}"
  ensure
    begin
      c.close
    rescue StandardError
      nil
    end
  end
end
