# frozen_string_literal: true

require "json"
require "fileutils"

module Five00Matic
  # The groups, persisted in one JSON file. Nothing is cached: every
  # operation locks the file and reads it afresh, so the processes sharing a
  # data directory (a web server and the job workers it forked, each with
  # its own SDK hook) count against one set of groups. Writes go through a
  # temporary file and a rename, so no reader sees a partial file.
  class Store
    def initialize(data_dir)
      @data_dir = data_dir
      @path = File.join(data_dir, "groups.json")
    end

    # Counts one occurrence of the event's fingerprint, starting a group for
    # a fingerprint not seen before. Returns the group as it is afterwards.
    def record(event, at:)
      update(event.fingerprint) { |group| (group || Group.start(event.fingerprint, at: at)).record(event, at: at) }
    end

    # Replaces a fingerprint's group with the block's result and persists it.
    def update(fingerprint)
      locked(File::LOCK_EX) do |groups|
        groups[fingerprint] = yield groups[fingerprint]
        persist(groups)
        groups[fingerprint]
      end
    end

    # Most recently seen first.
    def groups = locked(File::LOCK_SH) { |groups| groups.values.sort_by(&:last_seen).reverse }

    def size = locked(File::LOCK_SH) { |groups| groups.size }

    # Runs the block holding the fingerprint's lock against every other
    # holder in any process sharing the data directory; Tracker keeps record
    # then deliver atomic with it. Fingerprints sharing a first byte share a
    # lock file, so the lock directory holds at most 256 files; unrelated
    # errors sharing one just wait for each other.
    def synchronize(fingerprint, &)
      lock(File.join(@data_dir, "locks", fingerprint[0, 2]), File::LOCK_EX, &)
    end

    private

    def locked(mode)
      lock("#{@path}.lock", mode) { yield load }
    end

    # Each File.open is its own lock holder, so threads of one process
    # serialize here as well as processes do.
    def lock(path, mode)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        file.flock(mode)
        yield
      end
    end

    def load
      return {} unless File.exist?(@path)

      JSON.parse(File.read(@path)).transform_values { |attrs| Group.new(**attrs.transform_keys(&:to_sym)) }
    end

    # Caller holds the exclusive lock.
    def persist(groups)
      # Titles and errors come from event content; keep the file readable by
      # the owner only (tmp-then-rename sets the mode on every write).
      File.write("#{@path}.tmp", JSON.pretty_generate(groups.transform_values(&:to_h)), perm: 0o600)
      File.rename("#{@path}.tmp", @path)
    end
  end
end
