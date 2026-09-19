# For a real Rack host (Puma, Rails, any Rack 2/3 app):
#   rackup config.ru
# or mount SentryTickets::App into an existing app.
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "sentry_tickets"

map "/sentry" do
  SentryTickets::App.new(SentryTickets::Config.new)
end
