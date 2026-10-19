# frozen_string_literal: true

require "time"

module Five00Matic
  # The groups as rows of the app's five00matic_groups table, shared by
  # every process and host on its database. Each operation is a statement
  # or a short transaction of its own. A delivery is serialized per
  # fingerprint by a claim on its row rather than by a lock held across the
  # GitHub call, so recording an occurrence never waits on GitHub.
  class DatabaseStore
    # Long past the GitHub client's timeouts, so a claim lapses only when
    # its holder died mid-delivery.
    CLAIM_SECONDS = 10 * 60
    # ISO 8601 strings in a Group, timestamps in its row.
    TIMES = %i[first_seen last_seen last_notice_at].freeze

    # Counts one occurrence of the event's fingerprint, starting a group for
    # a fingerprint not seen before. Returns the group as it is afterwards.
    # The insert does nothing for a row that exists, so two processes
    # starting one group at once both count on the same row.
    def record(event, at:)
      GroupRecord.insert(columns(Group.start(event.fingerprint, at: at)), unique_by: :fingerprint)
      update(event.fingerprint) { |group| group.record(event, at: at) }
    end

    # Replaces a fingerprint's group with the block's result, its row
    # locked from read to write.
    def update(fingerprint)
      GroupRecord.transaction do
        row = GroupRecord.lock.find_by!(fingerprint: fingerprint)
        group = yield group_of(row)
        row.update!(columns(group))
        group
      end
    end

    def find(fingerprint)
      row = GroupRecord.find_by(fingerprint: fingerprint)
      row && group_of(row)
    end

    # Runs the block with the fingerprint's group while holding its
    # delivery claim, and returns the block's result. Returns nil without
    # running it while another delivery's claim stands: that delivery, or
    # its retry, gives the destination what it is owed.
    def claim(fingerprint, now: Time.now)
      expires = Time.at(now.to_i + CLAIM_SECONDS)
      claimed = GroupRecord.where(fingerprint: fingerprint)
                           .where("claimed_until IS NULL OR claimed_until < ?", now)
                           .update_all(claimed_until: expires)
      return if claimed.zero?

      begin
        yield find(fingerprint)
      ensure
        # Only this claim: one that lapsed may have been taken since.
        GroupRecord.where(fingerprint: fingerprint, claimed_until: expires).update_all(claimed_until: nil)
      end
    end

    private

    def group_of(row)
      attributes = row.attributes.transform_keys(&:to_sym).slice(*Group.members)
      Group.new(**attributes.merge(TIMES.to_h { |name| [name, row[name]&.getutc&.iso8601] }))
    end

    def columns(group)
      attributes = group.to_h
      attributes.merge(TIMES.to_h { |name| [name, attributes[name] && Time.iso8601(attributes[name])] })
    end
  end
end
