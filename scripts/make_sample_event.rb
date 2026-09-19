# frozen_string_literal: true

# Generates a real error payload without sending anything anywhere, using the
# installed sentry-ruby SDK. Run under the same interpreter that runs your
# apps (here: the RVM ruby-3.2.0):
#
#   ~/.rvm/rubies/ruby-3.2.0/bin/ruby scripts/make_sample_event.rb
#
# Writes:
#   sample/event.json    raw event hash (what a before_send hook receives,
#                        via event.to_json_compatible)
#   sample/envelope.txt  the Sentry envelope that a DSN pointed at this
#                        receiver would POST (headers line + item lines)
require "sentry-ruby"

OUT_DIR = File.expand_path("../sample", __dir__)
Dir.mkdir(OUT_DIR) unless Dir.exist?(OUT_DIR)

Sentry.init do |config|
  config.dsn = "https://sample-key@localhost:9099/1"
  config.environment = "production"
  config.release = "sample-release-1"
  config.background_worker_threads = 0
end

scope = Sentry.get_current_scope
scope.set_user(id: "42")
scope.set_tags(source: "sample", integration: "ruby")
scope.set_extras(customer_id: "c-77", plan: "pro")
scope.set_transaction_name("/api/orders")

# Chained exception so the cause-chain rendering gets exercised.
raised =
  begin
    begin
      raise ArgumentError, "missing required parameter: user_id"
    rescue ArgumentError
      raise NoMethodError, "undefined method `name' for nil:NilClass"
    end
  rescue NoMethodError => e
    e
  end

event = Sentry.get_current_client.event_from_exception(raised)
scope.apply_to_event(event, {})

event_hash = event.to_json_compatible
File.write(File.join(OUT_DIR, "event.json"), JSON.pretty_generate(event_hash) + "\n")

transport = Sentry.get_current_client.transport
envelope = transport.envelope_from_event(event)
wire, = transport.serialize_envelope(envelope)
File.write(File.join(OUT_DIR, "envelope.txt"), wire + "\n")

puts "wrote sample/event.json (#{File.size(File.join(OUT_DIR, 'event.json'))} bytes)"
puts "wrote sample/envelope.txt (#{File.size(File.join(OUT_DIR, 'envelope.txt'))} bytes)"
puts
puts "exception.values ordering check (last entry must be NoMethodError, the raised exception):"
event_hash.dig("exception", "values").each do |v|
  puts "  #{v['type']}  stacktrace=#{!v['stacktrace'].nil?}"
end
puts
puts "top of main stacktrace (most recent frame last):"
frames = event_hash.dig("exception", "values").last.dig("stacktrace", "frames") || []
frames.last(3).each do |f|
  puts "  #{f['filename']}:#{f['lineno']} in #{f['function']} (in_app=#{f['in_app']})"
end
