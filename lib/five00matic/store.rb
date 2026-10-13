# frozen_string_literal: true

require "json"
require "fileutils"

module Five00Matic
  # The groups, persisted in one JSON file that is rewritten atomically on
  # every change, so counts and notice anchors survive restarts.
  class Store
    def initialize(data_dir)
      @path = File.join(data_dir, "groups.json")
      @mutex = Mutex.new
      @groups = load
    end

    # Counts one occurrence of the event's fingerprint, starting a group for
    # a fingerprint not seen before. Returns the group as it is afterwards.
    def record(event, at:)
      update(event.fingerprint) { |group| (group || Group.start(event.fingerprint, at: at)).record(event, at: at) }
    end

    # Replaces a fingerprint's group with the block's result and persists it.
    def update(fingerprint)
      @mutex.synchronize do
        @groups[fingerprint] = yield @groups[fingerprint]
        persist
        @groups[fingerprint]
      end
    end

    # Most recently seen first.
    def groups
      @mutex.synchronize { @groups.values.sort_by(&:last_seen).reverse }
    end

    def size
      @mutex.synchronize { @groups.size }
    end

    private

    def load
      return {} unless File.exist?(@path)

      JSON.parse(File.read(@path)).transform_values { |attrs| Group.new(**attrs.transform_keys(&:to_sym)) }
    end

    # Caller holds @mutex.
    def persist
      FileUtils.mkdir_p(File.dirname(@path))
      # Titles and errors come from event content; keep the file readable by
      # the owner only (tmp-then-rename sets the mode on every write).
      File.write("#{@path}.tmp", JSON.pretty_generate(@groups.transform_values(&:to_h)), perm: 0o600)
      File.rename("#{@path}.tmp", @path)
    end
  end
end
