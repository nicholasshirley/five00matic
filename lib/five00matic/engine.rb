# frozen_string_literal: true

module Five00Matic
  # Gives the app bin/rails five00matic:install:migrations, which copies
  # the database store's migrations that the app does not have yet.
  class Engine < ::Rails::Engine
    engine_name "five00matic"
  end
end
