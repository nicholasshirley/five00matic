# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "fileutils"
require "digest/sha2"

module SentryTickets
  class DeliveryError < StandardError; end

  # Minimal GitHub REST client, stdlib only.
  #
  # Without a token or repo, delivery degrades to dry-run: issues and comments
  # are written to the outbox directory as markdown files, so the whole flow
  # (including formatting) is runnable without a real GitHub.
  class GitHubSync
    GITHUB_API_VERSION = "2022-11-28"
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30
    WRITE_TIMEOUT = 30

    def initialize(repo:, token: nil, labels: ["error-report"],
                   api_base: "https://api.github.com", outbox_dir: nil)
      @repo = repo
      @token = token
      @labels = labels
      @api_base = api_base
      @outbox_dir = outbox_dir
    end

    attr_reader :repo, :outbox_dir

    def dry_run?
      @token.nil? || @repo.nil?
    end

    # Returns { "number" => Integer|nil, "url" => String|nil, "outbox" => String|nil }
    def open_issue(title:, body:)
      if dry_run?
        { "outbox" => outbox_write("issue", title, body) }
      else
        r = request(:post, "/repos/#{@repo}/issues",
                    title: title, body: body, labels: @labels)
        raise DeliveryError, "GitHub response has no issue number" if r["number"].nil?

        { "number" => r["number"], "url" => r["html_url"] }
      end
    end

    # Returns { "number" => Integer }
    def comment(number:, body:)
      if dry_run?
        subject = number ? "notice for ##{number}" : "recurrence notice"
        outbox_write("comment", subject, body)
        { "number" => number }
      else
        request(:post, "/repos/#{@repo}/issues/#{number}/comments", body: body)
        { "number" => number }
      end
    end

    def self.slugify(text)
      text.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")[0, 60]
    end

    # Error text that can come back over the wire is binary-labeled by
    # Net::HTTP; anything persisted in state or echoed in a response must be
    # valid UTF-8 first.
    def self.scrub(string)
      string.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD")
    end

    private

    def request(method, path, payload = nil)
      uri = URI.parse("#{@api_base}#{path}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.write_timeout = WRITE_TIMEOUT if http.respond_to?(:write_timeout=)
      req = method == :post ? Net::HTTP::Post.new(uri.request_uri) : Net::HTTP::Get.new(uri.request_uri)
      req["Content-Type"] = "application/json"
      req["Accept"] = "application/vnd.github+json"
      req["Authorization"] = "Bearer #{@token}" if @token
      req["X-GitHub-Api-Version"] = GITHUB_API_VERSION
      req.body = JSON.generate(payload) if payload

      res = http.request(req)
      unless res.code.to_i.between?(200, 299)
        detail = self.class.scrub(res.body.to_s)[0, 300]
        raise DeliveryError, "GitHub API #{res.code}: #{detail}"
      end

      JSON.parse(res.body)
    rescue DeliveryError
      raise
    rescue StandardError => e
      # Parser and network failures can carry raw bytes (a middlebox's
      # garbage 200 body lands in the JSON::ParserError message); the
      # message is persisted in state, so it must always be valid UTF-8.
      raise DeliveryError, self.class.scrub("#{e.class}: #{e.message}")
    end

    def outbox_write(kind, title, text)
      FileUtils.mkdir_p(@outbox_dir)
      stamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
      # Distinct errors often slug to the same 60-character prefix (any
      # NoMethodError on nil does); disambiguate with a content digest so
      # same-second writes do not overwrite each other.
      digest = Digest::SHA256.hexdigest(text)[0, 8]
      file = File.join(@outbox_dir, "#{kind}-#{self.class.slugify(title)}.#{digest}.#{stamp}.md")
      File.write(file, "# #{title}\n\n#{text}\n")
      file
    end
  end
end
