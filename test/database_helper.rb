# frozen_string_literal: true

require_relative "test_helper"
require "active_record"

# A file rather than :memory:, which gives each connection a database of its
# own: threads in a test must share one. Built by the migrations an app
# copies, so they are what gets tested.
ActiveRecord::Base.establish_connection(adapter: "sqlite3", pool: 10, timeout: 5000,
                                        database: File.join(Dir.mktmpdir("five00matic-db"), "test.sqlite3"))
ActiveRecord::Migration.verbose = false
ActiveRecord::MigrationContext.new(File.expand_path("../db/migrate", __dir__)).migrate
