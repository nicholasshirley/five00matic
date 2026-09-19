# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "sentry_tickets"
require "minitest/autorun"
require "tmpdir"
require "stringio"

module Fixture
  # Sentry-ruby 5.x payload shape after an event.to_json_compatible round
  # trip: string keys, frames ordered oldest first, exception.values ordered
  # root cause first with the raised exception last.
  def self.frame(lineno, function: "load", module_name: "Order",
                 filename: "/app/lib/orders.rb", in_app: true, context: nil)
    f = { "lineno" => lineno, "function" => function, "module" => module_name,
          "filename" => filename, "in_app" => in_app }
    if context
      f["pre_context"] = context
      f["context_line"] = "<%= @customer.name %>"
      f["post_context"] = context.map { |ln| [ln[0] + 1, "  end"] }
    end
    f
  end

  def self.event(
    id: "e0f1a2b3-c4d5-4e6f-a7b8-9c0d1e2f3a4b",
    type: "NoMethodError",
    value: "undefined method `name' for nil:NilClass",
    frame_lineno: 26,
    fingerprint: []
  )
    {
      "event_id" => id,
      "timestamp" => "2026-09-19T04:35:00.000000Z",
      "platform" => "ruby",
      "type" => "event",
      "environment" => "production",
      "release" => "1.2.3",
      "server_name" => "web1.example.com",
      "level" => "error",
      "user" => { "id" => "42" },
      "tags" => { "request_id" => "abc-123" },
      "extra" => { "customer_id" => "c-77", "plan" => "pro" },
      "contexts" => {
        "runtime" => { "name" => "rb", "version" => "3.2.0" },
        "os" => { "name" => "darwin", "version" => "25.0.0" }
      },
      "fingerprint" => fingerprint,
      "exception" => {
        "values" => [
          { "type" => "ArgumentError", "value" => "missing required parameter: user_id",
            "stacktrace" => { "frames" => [frame(5, function: "validate!")] } },
          { "type" => type, "value" => value,
            "stacktrace" => { "frames" => [frame(12, function: "index"),
                                           frame(frame_lineno, context: [[25, "  def load"], [26, "    @customer"]])] } }
        ]
      }
    }
  end

  def self.store_dir
    Dir.mktmpdir("sentry-tickets-test")
  end

  def self.store(dir = store_dir, interval = 21_600)
    SentryTickets::Store.new(data_dir: dir, notice_interval: interval)
  end
end
