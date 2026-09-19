# frozen_string_literal: true

require "json"
require "digest/sha2"
require "time"

require_relative "sentry_tickets/config"
require_relative "sentry_tickets/store"
require_relative "sentry_tickets/ticket"
require_relative "sentry_tickets/github_sync"
require_relative "sentry_tickets/app"

# Receives Sentry-shaped error events from the sentry-ruby SDK (via a
# before_send hook) and turns each unique error into a GitHub issue, with
# throttled recurrence notices.
module SentryTickets
  VERSION = "0.1.0"
end
