# frozen_string_literal: true

require "json"
require "digest/sha2"
require "time"

require_relative "five00matic/version"
require_relative "five00matic/credentials"
require_relative "five00matic/config"
require_relative "five00matic/event"
require_relative "five00matic/group"
require_relative "five00matic/store"
require_relative "five00matic/ticket"
require_relative "five00matic/notice"
require_relative "five00matic/delivery_error"
require_relative "five00matic/github"
require_relative "five00matic/outbox"
require_relative "five00matic/tracker"
require_relative "five00matic/app"

# Receives Sentry-shaped error events from the sentry-ruby SDK (via a
# before_send hook) and turns each unique error into a GitHub issue, with
# throttled recurrence notices.
module Five00Matic
  # The pipeline a config describes: a store in its data directory feeding
  # the destination its credentials select, the outbox without any.
  def self.tracker(config)
    destination =
      if config.dry_run?
        Outbox.new(File.join(config.data_dir, "outbox"))
      else
        GitHub.new(repo: config.repo, credentials: config.credentials, labels: config.labels, api_base: config.api_base)
      end
    Tracker.new(store: Store.new(config.data_dir), destination: destination, notice_interval: config.notice_interval)
  end
end
