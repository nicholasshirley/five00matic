# frozen_string_literal: true

require "json"

module SentryTickets
  # Renders a Sentry-shaped event hash (string keys, as produced by
  # event.to_json_compatible or an envelope) into a GitHub issue body.
  class Ticket
    MAX_FRAMES = 20
    MAX_BREADCRUMBS = 10

    def initialize(event, record)
      @event = event
      @record = record
    end

    def title
      @record["title"] || Store.title_for(@event)
    end

    def body
      sections = [summary_section]
      sections << request_section if non_empty_hash(@event["request"])
      sections << exception_section
      sections << stacktrace_section if stacktrace
      sections << user_section if non_empty_hash(@event["user"])
      sections << kv_section("Tags", @event["tags"]) if non_empty_hash(@event["tags"])
      sections << kv_section("Extra", @event["extra"]) if non_empty_hash(@event["extra"])
      sections << breadcrumb_section
      sections << contexts_section if non_empty_hash(@event["contexts"])
      sections << raw_payload_section
      sections.compact.join("\n\n")
    end

    private

    def summary_section
      lines = ["## Summary", ""]
      lines << "- **Project:** #{val(@record['project'])}" if @record["project"]
      lines << "- **Environment:** #{val(@event['environment'])}" if @event["environment"]
      lines << "- **Release:** #{val(@event['release'])}" if @event["release"]
      lines << "- **Server:** #{val(@event['server_name'])}" if @event["server_name"]
      lines << "- **First seen:** #{@record['first_seen']}"
      lines << "- **Last seen:** #{@record['last_seen']}"
      lines << "- **Occurrences:** #{@record['count']}"
      lines << "- **Fingerprint:** `#{@record['fingerprint'].to_s[0, 16]}`"
      lines << "- **Latest event:** `#{@record['last_event_id']}`" if @record["last_event_id"]
      lines.join("\n")
    end

    def request_section
      req = @event["request"]
      lines = ["## Request", ""]
      lines << "- **Method:** #{val(req['method'])}" if req["method"]
      url = req["url"]
      if url
        q = req["query_string"] ? " (query: #{val(req['query_string'])})" : ""
        lines << "- **URL:** #{val(url)}#{q}"
      end
      lines << "- **Status:** #{val(@event.dig('contexts', 'http', 'status_code'))}" if @event.dig("contexts", "http")
      lines << "- **Body:** #{format_value(req['data'])}" if req["data"]
      lines << "- **Cookies:** #{format_value(req['cookies'])}" if req["cookies"]
      lines << "- **User IP:** #{val(req.dig('env', 'REMOTE_ADDR'))}" if req.dig("env", "REMOTE_ADDR")
      lines.join("\n")
    end

    def exception_section
      values = @event.dig("exception", "values")
      return nil unless values.is_a?(Array) && !values.empty?

      lines = ["## Exception", ""]
      # values is ordered root cause first; the raised exception is last, so
      # show the raised one first with its cause chain beneath it
      values.reverse.each_with_index do |v, i|
        prefix = i.zero? ? "" : "**Caused by:** "
        # no code span: exception values contain literal backticks
        line = "#{prefix}#{Store.exception_line(v)}"
        lines << line
        lines << "" if i < values.length - 1
      end
      lines.join("\n")
    end

    def stacktrace
      values = @event.dig("exception", "values")
      return nil unless values.is_a?(Array) && !values.empty?

      st = values.last["stacktrace"]
      return nil unless st.is_a?(Hash)

      frames = st["frames"]
      return nil unless frames.is_a?(Array) && !frames.empty?

      app_frames = frames.select { |f| f["in_app"] }
      shown = (app_frames.empty? ? frames : app_frames).reverse # crash site first
      shown.first(MAX_FRAMES)
    end

    def stacktrace_section
      frames = stacktrace
      return nil unless frames

      out = ["## Stack trace", "```"]
      frames.each_with_index do |f, i|
        loc = [f["filename"] || f["abs_path"], f["lineno"]].compact.join(":")
        func = f["function"] ? (f["module"] ? "#{f['module']}.#{f['function']}" : f["function"]) : nil
        out << "-- #{func || 'frame'} at #{loc}"
        pre = f["pre_context"] || []
        post = f["post_context"] || []
        if pre.any? || f["context_line"] || post.any?
          pre.each { |ln| out << "    #{context_text(ln)}" }
          out << ">   #{f['context_line'].to_s.chomp}" if f["context_line"]
          post.each { |ln| out << "    #{context_text(ln)}" }
        end
        out << "" if i < frames.length - 1
      end
      out << "```"
      out.join("\n")
    end

    # SDK payloads carry pre_context/post_context as raw source lines (plain
    # strings, newline-terminated); hand-built events may use [lineno, text]
    # pairs. Accept both and strip the trailing newline.
    def context_text(ln)
      (ln.is_a?(Array) ? ln[1] : ln).to_s.chomp
    end

    def user_section
      kv_section("User", @event["user"])
    end

    def kv_section(header, data)
      lines = ["## #{header}", ""]
      data.each do |k, v|
        lines << "- **#{k}:** #{format_value(v)}"
      end
      lines.join("\n")
    end

    def breadcrumb_section
      crumbs = @event.dig("breadcrumbs", "values") || []
      return nil if crumbs.empty?

      lines = ["## Breadcrumbs (last #{[MAX_BREADCRUMBS, crumbs.length].min})", ""]
      crumbs.last(MAX_BREADCRUMBS).each do |c|
        ts = format_ts(c["timestamp"])
        extra = c["data"] ? " `#{JSON.generate(c['data'])}`" : ""
        lines << "- [#{c['level'].to_s.upcase}] #{ts} #{c['category'].to_s} — #{c['message'].to_s}#{extra}"
      end
      lines.join("\n")
    end

    def contexts_section
      "## Contexts\n\n```\n#{JSON.pretty_generate(@event['contexts'])}\n```"
    end

    def raw_payload_section
      %(<details>
<summary>Full event payload</summary>

```json
#{JSON.pretty_generate(@event)}
```

</details>)
    end

    def non_empty_hash(v)
      v.is_a?(Hash) && !v.empty?
    end

    def format_value(v)
      s = v.is_a?(String) ? v : JSON.generate(v)
      s.length > 500 ? "#{s[0, 500]}..." : s
    end

    def val(v) = v.nil? ? "?" : v.to_s

    # SDKs emit epoch floats, but hand-built or foreign events may carry
    # pre-formatted strings.
    def format_ts(t)
      case t
      when Numeric then Time.at(t).utc.strftime("%Y-%m-%d %H:%M:%S")
      when String then t
      else "?"
      end
    end
  end
end
