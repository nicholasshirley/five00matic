# frozen_string_literal: true

module Five00Matic
  # Runtime configuration from the environment.
  #
  # TICKET_REPO           owner/repo that receives issues   (GITHUB_REPO works too)
  # TICKET_TOKEN          personal access token            (GITHUB_TOKEN works too)
  # TICKET_APP_ID         GitHub App id: with its private key, tickets are
  #                       posted as the app; TICKET_TOKEN wins when both are set
  # TICKET_APP_KEY        the app's private key as PEM text, or
  # TICKET_APP_KEY_FILE   a path to it
  # TICKET_LABELS         comma-separated, default "error-report"
  # TICKET_NOTICE_INTERVAL seconds between recurrence notices, default 21600 (6h)
  # TICKET_DATA_DIR       state + outbox directory, default ./data
  # TICKET_API_BASE       default https://api.github.com (GHES: https://ghe.example.com/api/v3)
  class Config
    attr_reader :repo, :token, :app_id, :private_key, :labels, :notice_interval, :data_dir, :api_base

    def initialize(
      repo: self.class.blank_to_nil(ENV["TICKET_REPO"] || ENV["GITHUB_REPO"]),
      token: self.class.blank_to_nil(ENV["TICKET_TOKEN"] || ENV["GITHUB_TOKEN"]),
      app_id: self.class.blank_to_nil(ENV["TICKET_APP_ID"]),
      private_key: self.class.blank_to_nil(ENV["TICKET_APP_KEY"]) || self.class.read_key(ENV["TICKET_APP_KEY_FILE"]),
      labels: ENV.fetch("TICKET_LABELS", "error-report"),
      notice_interval: ENV.fetch("TICKET_NOTICE_INTERVAL", 6 * 3600),
      data_dir: ENV.fetch("TICKET_DATA_DIR", File.join(Dir.pwd, "data")),
      api_base: ENV.fetch("TICKET_API_BASE", "https://api.github.com")
    )
      @repo = repo
      @token = token
      @app_id = app_id
      @private_key = private_key
      @labels = labels.split(",").map(&:strip).reject(&:empty?).freeze
      @notice_interval = Integer(notice_interval)
      @data_dir = data_dir.to_s
      @api_base = api_base.chomp("/")
    end

    # Without a repo and a way to authenticate, tickets go to the outbox
    # directory.
    def dry_run? = repo.nil? || credentials.nil?

    # What the GitHub client authenticates with: the token as given, or an
    # app that mints its own. Nil without either.
    def credentials
      @credentials ||=
        if token then Token.new(token: token)
        elsif app_id && private_key then AppToken.new(app_id: app_id, private_key: private_key, api_base: api_base)
        end
    end

    def self.blank_to_nil(value)
      value.nil? || value.strip.empty? ? nil : value
    end

    def self.read_key(path)
      File.read(path) unless blank_to_nil(path).nil?
    end
  end
end
