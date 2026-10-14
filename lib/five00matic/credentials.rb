# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

module Five00Matic
  # A personal access token, used as given.
  Token = Data.define(:token)

  # A GitHub App's identity: signs a JWT with the app's private key,
  # exchanges it for an installation access token, and hands that token out
  # until shortly before it expires. The app is expected to be installed on
  # one account, the one owning the repos it files into; that installation
  # is looked up on first use, and again after a mint fails, since an app
  # installed afresh has a new id. Failures become DeliveryError, so the
  # ticket that needed the token is retried on the error's next occurrence.
  class AppToken
    # GitHub accepts a JWT expiring up to ten minutes out; this leaves room
    # for a clock a little ahead of GitHub's.
    JWT_LIFETIME = 540
    # A new token is minted when fewer than this many seconds remain.
    RENEW_MARGIN = 300
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30

    def initialize(app_id:, private_key:, api_base:)
      @app_id = app_id.to_s
      @key = OpenSSL::PKey::RSA.new(private_key)
      @api_base = api_base
      @mutex = Mutex.new
      @token = nil
      @expires_at = Time.at(0)
      @installation_id = nil
    end

    def token(now: Time.now)
      @mutex.synchronize do
        mint(now) if @expires_at - now < RENEW_MARGIN
        @token
      rescue DeliveryError
        @installation_id = nil
        raise
      end
    end

    private

    def mint(now)
      jwt = jwt(now)
      @installation_id ||= installation_id(jwt)
      granted = request(Net::HTTP::Post, "/app/installations/#{@installation_id}/access_tokens", jwt)
      raise DeliveryError, "GitHub App token response is not an object" unless granted.is_a?(Hash)

      @token = granted.fetch("token")
      @expires_at = Time.iso8601(granted.fetch("expires_at"))
    rescue KeyError, ArgumentError, TypeError => e
      raise DeliveryError, "GitHub App token response: #{e.class}: #{e.message}"
    end

    def installation_id(jwt)
      installations = request(Net::HTTP::Get, "/app/installations", jwt)
      installations = [] unless installations.is_a?(Array)
      unless installations.size == 1
        raise DeliveryError, "GitHub App #{@app_id} has #{installations.size} installations, expected one"
      end

      id = installations.first["id"] if installations.first.is_a?(Hash)
      raise DeliveryError, "GitHub App installation has no id" if id.nil?

      id
    end

    # RS256, as GitHub requires; issued a minute in the past for clock skew.
    def jwt(now)
      header = base64url(JSON.generate(alg: "RS256", typ: "JWT"))
      claims = base64url(JSON.generate(iat: now.to_i - 60, exp: now.to_i + JWT_LIFETIME, iss: @app_id))
      signature = base64url(@key.sign(OpenSSL::Digest.new("SHA256"), "#{header}.#{claims}"))
      "#{header}.#{claims}.#{signature}"
    end

    def base64url(bytes) = [bytes].pack("m0").tr("+/", "-_").delete("=")

    # Refused connections, timeouts and error statuses alike become a
    # DeliveryError.
    def request(method, path, jwt)
      uri = URI("#{@api_base}#{path}")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                     open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        http.request(method.new(uri.request_uri, headers(jwt)))
      end
      unless response.is_a?(Net::HTTPSuccess)
        raise DeliveryError.new("GitHub App auth #{response.code}: #{response.body.to_s[0, 300]}",
                                status: response.code.to_i)
      end

      JSON.parse(response.body)
    rescue DeliveryError
      raise
    rescue StandardError => e
      raise DeliveryError, "GitHub App auth: #{e.class}: #{e.message}"
    end

    def headers(jwt)
      {
        "Accept" => "application/vnd.github+json",
        "Authorization" => "Bearer #{jwt}",
        "X-GitHub-Api-Version" => GitHub::API_VERSION
      }
    end
  end
end
