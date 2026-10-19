# frozen_string_literal: true

require "digest/sha2"

module Five00Matic
  # A sentry-ruby error event: the string-keyed hash event.to_json_compatible
  # produces. Everything this app knows about the payload's layout lives here
  # and in the two value classes below; a section of an unexpected type reads
  # as empty rather than crashing whoever asked.
  class Event
    TITLE_LIMIT = 100

    def initialize(data)
      @data = data
    end

    def to_h = @data

    def id = @data["event_id"]
    def message = @data["message"]
    def environment = @data["environment"]
    def release = @data["release"]
    def server_name = @data["server_name"]

    def request = hash_at("request")
    def user = hash_at("user")
    def tags = hash_at("tags")
    def extra = hash_at("extra")
    def contexts = hash_at("contexts")

    def breadcrumbs = Array(hash_at("breadcrumbs")["values"]).grep(Hash)

    # The client's address, which the SDK leaves in the request's Rack env
    # only when send_default_pii is on.
    def remote_addr
      env = request["env"]
      env["REMOTE_ADDR"] if env.is_a?(Hash)
    end

    # The class of the job that raised, which sentry-rails sends in the
    # active_job context.
    def job_class
      job = contexts["active_job"]
      job["job_class"] if job.is_a?(Hash)
    end

    # Ordered as the SDK sends them: root cause first, raised exception last.
    def exceptions
      Array(hash_at("exception")["values"]).grep(Hash).map { |v| ExceptionValue.new(v) }
    end

    def raised = exceptions.last

    # Without an exception or a message there is nothing to group on, and
    # every such event would collide on the digest of the empty fingerprint.
    def reportable? = !raised.nil? || !message.to_s.strip.empty?

    # One bug, one ticket. An explicit fingerprint set in the app wins;
    # otherwise the raised exception's type plus where it happened in app
    # code. Line numbers shift with unrelated edits and messages carry ids and
    # object addresses (Ruby 3.2's NoMethodError embeds "#<User:0x... @id=5>"),
    # so neither is part of the key: the message stands in only when there is
    # no stack trace. Tags stay out too, since sentry-rack's per-request
    # request_id would give every request its own ticket.
    def fingerprint
      Digest::SHA256.hexdigest(grouping_key.join("\u0000"))
    end

    def title
      text = raised ? raised.summary : message.to_s.lines.first.to_s
      text = text.gsub(/[[:space:]]+/, " ").strip
      text = "<no message>" if text.empty?
      text.length > TITLE_LIMIT ? "#{text[0, TITLE_LIMIT - 3]}..." : text
    end

    # One entry of exception.values.
    class ExceptionValue
      def initialize(data)
        @data = data
      end

      def type = @data["type"].to_s

      # The SDK fills value with Exception#detailed_message, which (Ruby 3.2+)
      # appends " (Type)" to the message's first line and may add
      # error_highlight or did_you_mean lines beneath it.
      def message = @data["value"].to_s.lines.first.to_s.chomp.delete_suffix(" (#{type})")

      # "Type: message", or just the type when there is no message of its own
      # (an exception raised without one reports its class name).
      def summary = message.empty? || message == type ? type : "#{type}: #{message}"

      # Ordered as the SDK sends them: oldest first, crash site last.
      def frames
        stacktrace = @data["stacktrace"]
        return [] unless stacktrace.is_a?(Hash)

        Array(stacktrace["frames"]).grep(Hash).map { |f| Frame.new(f) }
      end

      # The frames that say where the app went wrong: the ones the SDK marked
      # in-app, or all of them when it marked none.
      def app_frames
        in_app = frames.select(&:in_app?)
        in_app.empty? ? frames : in_app
      end
    end

    # One entry of a stacktrace's frames.
    class Frame
      def initialize(data)
        @data = data
      end

      def module_name = @data["module"]
      def function = @data["function"]
      def filename = @data["filename"]
      def lineno = @data["lineno"]
      def in_app? = !!@data["in_app"]

      def location = [filename || @data["abs_path"], lineno].compact.join(":")
      def label = module_name && function ? "#{module_name}.#{function}" : function

      def context_line
        line = @data["context_line"]
        line.to_s.chomp if line
      end

      def pre_context = context("pre_context")
      def post_context = context("post_context")

      private

      # Raw source lines, newline-terminated; the SDK pads with nil where the
      # context runs past the start or end of the file.
      def context(key)
        lines = @data[key]
        lines.is_a?(Array) ? lines.grep(String).map(&:chomp) : []
      end
    end

    private

    def grouping_key
      explicit = @data["fingerprint"]
      return explicit.map(&:to_s) if explicit.is_a?(Array) && !explicit.empty?
      return [message.to_s] unless raised

      frames = raised.app_frames
      return [raised.type, raised.message] if frames.empty?

      # filename only, without location's abs_path fallback: the SDK sends
      # filename with the project root or load path stripped, while abs_path
      # carries the deploy directory, which can change with every release.
      [raised.type, *frames.map { |f| "#{f.filename}:#{f.label}" }]
    end

    def hash_at(key)
      value = @data[key]
      value.is_a?(Hash) ? value : {}
    end
  end
end
