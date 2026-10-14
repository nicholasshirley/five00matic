# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Five00Matic
  # Files issues and recurrence notices through GitHub's REST API, stdlib
  # only.
  class GitHub
    API_VERSION = "2022-11-28"
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30
    WRITE_TIMEOUT = 30

    def initialize(repo:, credentials:, labels:, api_base:)
      @repo = repo
      @credentials = credentials
      @labels = labels
      @api_base = api_base
    end

    def dry_run? = false

    # Only issues opened in this repo: an outbox file has no repo, and after
    # TICKET_REPO changes, issue #7 of the old repo is not #7 of the new one.
    # GitHub matches repo names case-insensitively.
    def owns?(issue) = !issue.nil? && @repo.casecmp?(issue["repo"].to_s)

    # Returns { "repo" => String, "number" => Integer, "url" => String }
    def open_issue(title:, body:)
      issue = post("/repos/#{@repo}/issues", { title: title, body: body, labels: @labels }, @credentials.token)
      raise DeliveryError, "GitHub response has no issue number" if issue["number"].nil?

      { "repo" => @repo, "number" => issue["number"], "url" => issue["html_url"] }
    end

    # A 404 for the comment means its issue is gone. The token is fetched
    # outside that rescue: an app whose installation was removed fails to
    # mint with a 404 too, and that says nothing about the issue.
    def comment(issue, body:)
      token = @credentials.token
      begin
        post("/repos/#{@repo}/issues/#{issue['number']}/comments", { body: body }, token)
      rescue DeliveryError => e
        raise e.status == 404 ? IssueGone.new(e.message, status: 404) : e
      end
    end

    private

    def post(path, payload, token)
      response = send_request(path, JSON.generate(payload), token)
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
    def send_request(path, body, token)
      uri = URI("#{@api_base}#{path}")
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT,
                                          read_timeout: READ_TIMEOUT, write_timeout: WRITE_TIMEOUT) do |http|
        http.post(uri.request_uri, body, headers(token))
      end
    rescue StandardError => e
      raise DeliveryError, "#{e.class}: #{e.message}"
    end

    def headers(token)
      {
        "Content-Type" => "application/json",
        "Accept" => "application/vnd.github+json",
        "Authorization" => "Bearer #{token}",
        "X-GitHub-Api-Version" => API_VERSION
      }
    end
  end
end
