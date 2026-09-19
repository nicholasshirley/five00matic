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
      # Real SDK shape: raw source lines as strings, newline-terminated.
      f["pre_context"] = context.map { |ln| "#{ln}\n" }
      f["context_line"] = "    <%= @customer.name %>\n"
      f["post_context"] = ["      end\n", "    end\n"]
    end
    f
  end

  # value is what the SDK sends: Exception#detailed_message, which puts
  # " (Type)" after the message and error_highlight lines beneath it.
  def self.payload(
    id: "e0f1a2b3-c4d5-4e6f-a7b8-9c0d1e2f3a4b",
    type: "NoMethodError",
    message: "undefined method `name' for nil:NilClass",
    value: "#{message} (#{type})\n\n    <%= @customer.name %>\n                 ^^^^^",
    frame_lineno: 26,
    fingerprint: [],
    breadcrumbs: nil
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
          { "type" => "ArgumentError", "value" => "missing required parameter: user_id (ArgumentError)",
            "stacktrace" => { "frames" => [frame(5, function: "validate!")] } },
          { "type" => type, "value" => value,
            "stacktrace" => { "frames" => [frame(12, function: "index"),
                                           frame(frame_lineno, context: ["  def load", "    @customer"])] } }
        ]
      }
    }.tap do |event|
      # SDK shape: breadcrumbs.values with epoch-float timestamps.
      event["breadcrumbs"] = { "values" => breadcrumbs } if breadcrumbs
    end
  end

  def self.event(**payload_options)
    SentryTickets::Event.new(payload(**payload_options))
  end

  def self.breadcrumb(category, message, timestamp: 1_758_268_800.123, level: "info", data: nil)
    c = { "timestamp" => timestamp, "category" => category, "message" => message, "level" => level }
    c["data"] = data if data
    c
  end

  def self.store_dir
    Dir.mktmpdir("sentry-tickets-test")
  end

  def self.store(dir = store_dir, interval = 21_600)
    SentryTickets::Store.new(data_dir: dir, notice_interval: interval)
  end
end
