# frozen_string_literal: true

require "digest/sha2"

module SentryTickets
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

    # Ordered as the SDK sends them: root cause first, raised exception last.
    def exceptions
      Array(hash_at("exception")["values"]).grep(Hash).map { |v| ExceptionValue.new(v) }
    end

    def raised = exceptions.last

    # Without an exception or a message there is nothing to group on, and
    # every such event would collide on the digest of the empty fingerprint.
    def reportable? = !raised.nil? || !message.to_s.strip.empty?

    # Sentry groups events by fingerprint. Events produced by the SDK almost
    # never carry one (it defaults to an empty array, meaning "derive it"), so
    # we derive one ourselves. Deliberately excludes tags: sentry-rack adds a
    # per-request request_id tag, which would shatter grouping into one issue
    # per request.
    def fingerprint
      explicit = @data["fingerprint"]
      return Digest::SHA256.hexdigest(explicit.join("|")) if explicit.is_a?(Array) && !explicit.empty?

      parts = []
      if raised
        parts << raised.type
        # The message keeps distinct failures distinct even when they share
        # type and raise site, e.g. `send(method_name)` missing different
        # methods on one line.
        parts << raised.first_line.chomp
        raised.frames.last(10).each do |f|
          parts << [f.module_name, f.function, f.filename, f.lineno].join(",")
        end
      end
      parts << message if message
      Digest::SHA256.hexdigest(parts.join("\u0000"))
    end

    def title
      text = raised ? raised.summary : (message || "<no message>").to_s.lines.first.to_s
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

      # The SDK's value field carries Exception#detailed_message: the message
      # on the first line, with anything else the exception adds beneath it.
      def first_line = @data["value"].to_s.lines.first.to_s

      # "Type: message", tolerating values that already carry the "Type: "
      # prefix (SDK detailed_message) or don't (hand-built events).
      def summary
        first = first_line
        return type if first.empty?

        first.start_with?("#{type}: ") ? first : "#{type}: #{first}"
      end

      # Ordered as the SDK sends them: oldest first, crash site last.
      def frames
        stacktrace = @data["stacktrace"]
        return [] unless stacktrace.is_a?(Hash)

        Array(stacktrace["frames"]).grep(Hash).map { |f| Frame.new(f) }
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

      # SDK payloads carry context as raw source lines (plain strings,
      # newline-terminated); hand-built events may use [lineno, text] pairs.
      def context(key)
        lines = @data[key]
        return [] unless lines.is_a?(Array)

        lines.map { |ln| (ln.is_a?(Array) ? ln[1] : ln).to_s.chomp }
      end
    end

    private

    def hash_at(key)
      value = @data[key]
      value.is_a?(Hash) ? value : {}
    end
  end
end
