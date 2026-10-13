# frozen_string_literal: true

require_relative "test_helper"

class ScrubberTest < Minitest::Test
  def request_payload
    Fixture.payload.merge(
      "request" => {
        "url" => "https://shop.example/login",
        "method" => "POST",
        "query_string" => "email=a%40b.example&page=2&tag=x&tag=y",
        "cookies" => { "_session" => "s3cret" },
        "headers" => { "Accept" => "*/*", "Authorization" => "Bearer t0ken", "Cookie" => "_session=s3cret" },
        "data" => { "user" => { "email" => "a@b.example", "password" => "hunter2", "name" => "Ann" } }
      },
      "breadcrumbs" => { "values" => [Fixture.breadcrumb("sql", "SELECT", data: { "db.query.parameter.email" => "a@b",
                                                                                   "sql" => "SELECT 1" })] }
    )
  end

  def test_cookies_and_authorization_go_even_without_a_filter
    scrubbed = Five00Matic::Scrubber.new.scrub(request_payload)
    request = scrubbed["request"]
    refute request.key?("cookies")
    assert_equal({ "Accept" => "*/*" }, request["headers"])
    assert_equal "hunter2", request.dig("data", "user", "password"), "nothing else changes without a filter"
    assert_equal "email=a%40b.example&page=2&tag=x&tag=y", request["query_string"]
  end

  # An app that empties rack_env_whitelist gets the whole Rack env sent:
  # the cookie and credential headers and the raw body among it.
  def test_rack_env_is_cut_to_the_sdk_defaults_even_without_a_filter
    payload = request_payload
    payload["request"]["env"] = {
      "REMOTE_ADDR" => "203.0.113.7", "SERVER_NAME" => "shop.example", "SERVER_PORT" => "443",
      "HTTP_COOKIE" => "_session=s3cret", "HTTP_AUTHORIZATION" => "Bearer t0ken",
      "rack.request.form_vars" => "user%5Bpassword%5D=hunter2"
    }
    assert_equal({ "REMOTE_ADDR" => "203.0.113.7", "SERVER_NAME" => "shop.example", "SERVER_PORT" => "443" },
                 Five00Matic::Scrubber.new.scrub(payload).dig("request", "env"))
  end

  def test_the_payload_given_is_left_as_it_was
    payload = request_payload
    Five00Matic::Scrubber.new(FakeFilter.new).scrub(payload)
    assert_equal({ "_session" => "s3cret" }, payload["request"]["cookies"])
    assert_equal "hunter2", payload.dig("request", "data", "user", "password")
  end

  def test_filter_reaches_body_query_breadcrumbs_and_the_scope_sections
    payload = request_payload.merge(
      "user" => { "id" => "42", "email" => "a@b.example" },
      "tags" => { "token" => "t", "request_id" => "r1" },
      "extra" => { "password_hint" => "x", "plan" => "pro" },
      "contexts" => { "rails.error" => { "email" => "a@b.example" }, "os" => { "name" => "darwin" } }
    )
    scrubbed = Five00Matic::Scrubber.new(FakeFilter.new).scrub(payload)
    request = scrubbed["request"]
    assert_equal({ "user" => { "email" => "[FILTERED]", "password" => "[FILTERED]", "name" => "Ann" } }, request["data"])
    assert_equal "email=%5BFILTERED%5D&page=2&tag=x&tag=y", request["query_string"], "repeated keys and order survive"
    assert_equal({ "db.query.parameter.email" => "[FILTERED]", "sql" => "SELECT 1" },
                 scrubbed["breadcrumbs"]["values"].first["data"])
    assert_equal({ "id" => "42", "email" => "[FILTERED]" }, scrubbed["user"])
    assert_equal({ "token" => "[FILTERED]", "request_id" => "r1" }, scrubbed["tags"])
    assert_equal({ "password_hint" => "[FILTERED]", "plan" => "pro" }, scrubbed["extra"])
    assert_equal({ "rails.error" => { "email" => "[FILTERED]" }, "os" => { "name" => "darwin" } }, scrubbed["contexts"])
  end

  def test_query_sent_without_percent_encoding_is_filtered_too
    payload = request_payload
    payload["request"]["query_string"] = "password=s3cret&u=José"
    assert_equal "password=%5BFILTERED%5D&u=Jos%C3%A9",
                 Five00Matic::Scrubber.new(FakeFilter.new).scrub(payload).dig("request", "query_string")
  end

  # sentry-ruby 7 sends the query parsed, its own masking applied to
  # top-level keys only.
  def test_query_sent_as_a_hash_is_filtered
    payload = request_payload
    payload["request"]["query_string"] = { "user" => { "password" => "s3cret" }, "page" => "2" }
    assert_equal({ "user" => { "password" => "[FILTERED]" }, "page" => "2" },
                 Five00Matic::Scrubber.new(FakeFilter.new).scrub(payload).dig("request", "query_string"))
  end

  def test_json_body_text_is_parsed_for_the_filter_and_other_text_is_kept
    payload = request_payload
    payload["request"]["data"] = '{"password":"p","q":1}'
    assert_equal({ "password" => "[FILTERED]", "q" => 1 },
                 Five00Matic::Scrubber.new(FakeFilter.new).scrub(payload).dig("request", "data"))

    payload["request"]["data"] = "<xml>raw</xml>"
    assert_equal "<xml>raw</xml>", Five00Matic::Scrubber.new(FakeFilter.new).scrub(payload).dig("request", "data")

    payload["request"]["data"] = "[1, 2]"
    assert_equal "[1, 2]", Five00Matic::Scrubber.new(FakeFilter.new).scrub(payload).dig("request", "data")
  end

  def test_shapes_the_sdk_does_not_send_pass_through
    payload = Fixture.payload.merge("request" => "garbage", "breadcrumbs" => "garbage", "user" => nil, "tags" => [1])
    scrubbed = Five00Matic::Scrubber.new(FakeFilter.new).scrub(payload)
    assert_equal "garbage", scrubbed["request"]
    assert_equal "garbage", scrubbed["breadcrumbs"]
    assert_nil scrubbed["user"]
    assert_equal [1], scrubbed["tags"]

    body = Five00Matic::Scrubber.new(FakeFilter.new).scrub(Fixture.payload.merge("request" => { "data" => 5 }))
    assert_equal 5, body.dig("request", "data")
  end

  def test_event_without_scope_sections_gains_none
    assert_equal({ "event_id" => "x", "message" => "boom" },
                 Five00Matic::Scrubber.new(FakeFilter.new).scrub({ "event_id" => "x", "message" => "boom" }))
  end

  def test_request_without_body_or_query_gains_neither
    payload = Fixture.payload.merge("request" => { "url" => "https://shop.example/", "headers" => {} })
    request = Five00Matic::Scrubber.new(FakeFilter.new).scrub(payload)["request"]
    refute request.key?("data")
    refute request.key?("query_string")
  end
end
