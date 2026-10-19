# frozen_string_literal: true

require_relative "lib/five00matic/version"

Gem::Specification.new do |spec|
  spec.name = "five00matic"
  spec.version = Five00Matic::VERSION
  spec.authors = ["Nicholas Shirley"]
  spec.summary = "Turns sentry-ruby error events into GitHub issues with throttled recurrence notices"
  spec.homepage = "https://github.com/nicholasshirley/five00matic"

  spec.required_ruby_version = ">= 3.2" # Group is a Data class
  spec.files = Dir["lib/**/*.rb"] + Dir["db/**/*.rb"] + ["README.md"]
  spec.require_paths = ["lib"]
end
