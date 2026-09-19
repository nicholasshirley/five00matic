# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module SentryTickets
  # Files issues and recurrence notices through GitHub's REST API, stdlib
  # only.
  class GitHub
    API_VERSION = "2022-11-28"
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30
    WRITE_TIMEOUT = 30

    def initialize(repo:, token:, labels:, api_base:)
      @repo = repo
      @token = token
      @labels = labels
      @api_base = api_base
    end

    def dry_run? = false

    # Returns { "number" => Integer, "url" => String }
    def open_issue(title:, body:)
      issue = post("/repos/#{@repo}/issues", title: title, body: body, labels: @labels)
      raise DeliveryError, "GitHub response has no issue number" if issue["number"].nil?

      { "number" => issue["number"], "url" => issue["html_url"] }
    end

    def comment(number:, body:)
      post("/repos/#{@repo}/issues/#{number}/comments", body: body)
    end

    private

    def post(path, payload)
      response = send_request(path, JSON.generate(payload))
      unless response.is_a?(Net::HTTPSuccess)
        raise DeliveryError.new("GitHub API #{response.code}: #{response.body.to_s[0, 300]}",
                                status: response.code.to_i)
      end

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise DeliveryError, "#{e.class}: #{e.message}"
    end

    # Refused connections, timeouts, DNS and TLS failures alike become a
    # DeliveryError, to be retried on the next occurrence.
    def send_request(path, body)
      uri = URI("#{@api_base}#{path}")
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT,
                                          read_timeout: READ_TIMEOUT, write_timeout: WRITE_TIMEOUT) do |http|
        http.post(uri.request_uri, body, headers)
      end
    rescue StandardError => e
      raise DeliveryError, "#{e.class}: #{e.message}"
    end

    def headers
      {
        "Content-Type" => "application/json",
        "Accept" => "application/vnd.github+json",
        "Authorization" => "Bearer #{@token}",
        "X-GitHub-Api-Version" => API_VERSION
      }
    end
  end
end
