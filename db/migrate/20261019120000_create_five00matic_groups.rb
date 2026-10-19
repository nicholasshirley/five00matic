# frozen_string_literal: true

# Rails names the class after the file: "five00matic" camelizes as Five00matic.
class CreateFive00maticGroups < ActiveRecord::Migration[7.1]
  def change
    create_table :five00matic_groups do |t|
      t.string :fingerprint, null: false, index: { unique: true }
      t.string :title
      t.string :release
      t.string :environment
      t.integer :count, null: false, default: 0
      t.datetime :first_seen, null: false
      t.datetime :last_seen
      t.string :last_event_id
      t.json :issue
      t.datetime :last_notice_at
      t.integer :last_notice_count, null: false, default: 0
      t.text :last_error
      t.datetime :claimed_until
    end
  end
end
