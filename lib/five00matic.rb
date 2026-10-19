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
require_relative "five00matic/database_store"
require_relative "five00matic/ticket"
require_relative "five00matic/notice"
require_relative "five00matic/delivery_error"
require_relative "five00matic/github"
require_relative "five00matic/outbox"
require_relative "five00matic/tracker"
require_relative "five00matic/scrubber"
require_relative "five00matic/hook"
require_relative "five00matic/app"
require_relative "five00matic/engine" if defined?(Rails::Engine)

# Receives Sentry-shaped error events from the sentry-ruby SDK (via a
# before_send hook) and turns each unique error into a GitHub issue, with
# throttled recurrence notices.
module Five00Matic
  # Loaded on first use, so requiring the gem loads no Rails framework.
  autoload :GroupRecord, File.join(__dir__, "five00matic", "group_record")

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

  # The before_send callable for Sentry.init, from the keywords Config
  # accepts (repo:, app_id:, private_key:, data_dir:, ...) plus the hook's
  # own: filter: (the app's parameter filter), mode: and logger:.
  def self.before_send(filter: nil, mode: :shadow, logger: nil, **config)
    Hook.new(tracker: tracker(Config.new(**config)), scrubber: Scrubber.new(filter), mode: mode, logger: logger)
  end
end
