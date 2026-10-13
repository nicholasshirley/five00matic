# frozen_string_literal: true

module Five00Matic
  # Renders the comment posted on a group's issue when the error recurs.
  class Notice
    def initialize(group)
      @group = group
    end

    def body
      <<~MARKDOWN.chomp
        Recurrence notice.

        - New occurrences since last notice: #{@group.unnotified_count}
        - Total occurrences: #{@group.count}
        - First seen: #{@group.first_seen}
        - Latest seen: #{@group.last_seen} (event `#{@group.last_event_id}`)
      MARKDOWN
    end
  end
end
