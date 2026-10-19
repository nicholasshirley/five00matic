# frozen_string_literal: true

require "active_record"

module Five00Matic
  # A group's row, as DatabaseStore keeps it.
  class GroupRecord < ActiveRecord::Base
    self.table_name = "five00matic_groups"
  end
end
