# frozen_string_literal: true

module Five00Matic
  # Runtime configuration from the environment.
  #
  # TICKET_REPO           owner/repo that receives issues   (GITHUB_REPO works too)
  # TICKET_TOKEN          personal access token            (GITHUB_TOKEN works too)
  # TICKET_LABELS         comma-separated, default "error-report"
  # TICKET_NOTICE_INTERVAL seconds between recurrence notices, default 21600 (6h)
  # TICKET_DATA_DIR       state + outbox directory, default ./data
  # TICKET_API_BASE       default https://api.github.com (GHES: https://ghe.example.com/api/v3)
  class Config
    attr_reader :repo, :token, :labels, :notice_interval, :data_dir, :api_base

    def initialize(
      repo: self.class.blank_to_nil(ENV["TICKET_REPO"] || ENV["GITHUB_REPO"]),
      token: self.class.blank_to_nil(ENV["TICKET_TOKEN"] || ENV["GITHUB_TOKEN"]),
      labels: ENV.fetch("TICKET_LABELS", "error-report"),
      notice_interval: ENV.fetch("TICKET_NOTICE_INTERVAL", 6 * 3600),
      data_dir: ENV.fetch("TICKET_DATA_DIR", File.join(Dir.pwd, "data")),
      api_base: ENV.fetch("TICKET_API_BASE", "https://api.github.com")
    )
      @repo = repo
      @token = token
      @labels = labels.split(",").map(&:strip).reject(&:empty?).freeze
      @notice_interval = Integer(notice_interval)
      @data_dir = data_dir
      @api_base = api_base.chomp("/")
    end

    # Without both a repo and a token, tickets go to the outbox directory.
    def dry_run? = repo.nil? || token.nil?

    def self.blank_to_nil(value)
      value.nil? || value.strip.empty? ? nil : value
    end
  end
end
