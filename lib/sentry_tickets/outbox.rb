# frozen_string_literal: true

require "digest/sha2"
require "fileutils"

module SentryTickets
  # Stands in for GitHub when no repo or token is configured: issues and
  # notices are written to a directory as markdown files, so the whole flow,
  # formatting included, runs without a real GitHub.
  class Outbox
    def initialize(dir)
      @dir = dir
    end

    def dry_run? = true

    # Returns { "outbox" => String }, the file's path.
    def open_issue(title:, body:)
      { "outbox" => write("issue", title, body) }
    end

    def comment(number:, body:)
      write("comment", number ? "notice for ##{number}" : "recurrence notice", body)
    end

    def self.slugify(text)
      text.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")[0, 60]
    end

    private

    def write(kind, title, text)
      FileUtils.mkdir_p(@dir)
      stamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
      # Distinct errors often slug to the same 60-character prefix (any
      # NoMethodError on nil does); disambiguate with a content digest so
      # same-second writes do not overwrite each other.
      digest = Digest::SHA256.hexdigest(text)[0, 8]
      file = File.join(@dir, "#{kind}-#{self.class.slugify(title)}.#{digest}.#{stamp}.md")
      # Outbox files carry full event payloads (user ids, request bodies);
      # keep them readable by the owner only.
      File.write(file, "# #{title}\n\n#{text}\n", perm: 0o600)
      file
    rescue SystemCallError, IOError => e
      # Match GitHub: a failed delivery is recorded and retried on the next
      # occurrence, it does not 500 the ingest.
      raise DeliveryError, "#{e.class}: #{e.message}"
    end
  end
end
