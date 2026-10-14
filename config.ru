# For a real Rack host (Puma, Rails, any Rack 2/3 app):
#   rackup config.ru
# or mount Five00Matic::App into an existing app.
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))

require "five00matic"

map "/sentry" do
  run Five00Matic::App.new(Five00Matic::Config.new)
end
