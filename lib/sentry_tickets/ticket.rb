# frozen_string_literal: true

require "json"

module SentryTickets
  # Renders an Event into a GitHub issue body.
  class Ticket
    MAX_FRAMES = 20
    MAX_BREADCRUMBS = 10
    # GitHub rejects issue bodies over 65,536 characters; stay under it so a
    # single fat event cannot permanently fail delivery.
    MAX_BODY_CHARS = 60_000

    def initialize(event, record)
      @event = event
      @record = record
    end

    def body
      core = sections.compact.join("\n\n")
      # A monstrous tags/extra section can overflow on its own; clip it so the
      # raw payload always keeps a slice of the budget.
      core = clip_core(core, MAX_BODY_CHARS - 2_000)
      "#{core}\n\n#{raw_payload_section(MAX_BODY_CHARS - core.length - 2)}"
    end

    private

    def sections
      [
        summary_section,
        request_section,
        exception_section,
        stacktrace_section,
        kv_section("User", @event.user),
        kv_section("Tags", @event.tags),
        kv_section("Extra", @event.extra),
        breadcrumb_section,
        contexts_section
      ]
    end

    def summary_section
      lines = ["## Summary", ""]
      lines << "- **Environment:** #{@event.environment}" if @event.environment
      lines << "- **Release:** #{@event.release}" if @event.release
      lines << "- **Server:** #{@event.server_name}" if @event.server_name
      lines << "- **First seen:** #{@record['first_seen']}"
      lines << "- **Last seen:** #{@record['last_seen']}"
      lines << "- **Occurrences:** #{@record['count']}"
      lines << "- **Fingerprint:** `#{@record['fingerprint'].to_s[0, 16]}`"
      lines << "- **Latest event:** `#{@record['last_event_id']}`" if @record["last_event_id"]
      lines.join("\n")
    end

    def request_section
      req = @event.request
      return if req.empty?

      lines = ["## Request", ""]
      lines << "- **Method:** #{req['method']}" if req["method"]
      if req["url"]
        query = req["query_string"] ? " (query: #{req['query_string']})" : ""
        lines << "- **URL:** #{req['url']}#{query}"
      end
      status = @event.contexts["http"].is_a?(Hash) && @event.contexts["http"]["status_code"]
      lines << "- **Status:** #{status}" if status
      lines << "- **Body:** #{format_value(req['data'])}" if req["data"]
      lines << "- **Cookies:** #{format_value(req['cookies'])}" if req["cookies"]
      remote_addr = req["env"].is_a?(Hash) ? req["env"]["REMOTE_ADDR"] : nil
      lines << "- **User IP:** #{remote_addr}" if remote_addr
      lines.join("\n")
    end

    def exception_section
      exceptions = @event.exceptions
      return if exceptions.empty?

      lines = ["## Exception", ""]
      # The raised exception first, with its cause chain beneath it. No code
      # span: exception values contain literal backticks.
      exceptions.reverse.each_with_index do |exception, i|
        lines << (i.zero? ? exception.summary : "**Caused by:** #{exception.summary}")
        lines << "" if i < exceptions.length - 1
      end
      lines.join("\n")
    end

    # App frames when the SDK marked any, crash site first.
    def stacktrace
      frames = @event.raised&.frames || []
      app_frames = frames.select(&:in_app?)
      (app_frames.empty? ? frames : app_frames).reverse.first(MAX_FRAMES)
    end

    def stacktrace_section
      frames = stacktrace
      return if frames.empty?

      out = ["## Stack trace", "```"]
      frames.each_with_index do |frame, i|
        out << "-- #{frame.label || 'frame'} at #{frame.location}"
        frame.pre_context.each { |line| out << "    #{line}" }
        out << ">   #{frame.context_line}" if frame.context_line
        frame.post_context.each { |line| out << "    #{line}" }
        out << "" if i < frames.length - 1
      end
      out << "```"
      out.join("\n")
    end

    def kv_section(header, data)
      return if data.empty?

      lines = ["## #{header}", ""]
      data.each { |k, v| lines << "- **#{k}:** #{format_value(v)}" }
      lines.join("\n")
    end

    def breadcrumb_section
      crumbs = @event.breadcrumbs
      return if crumbs.empty?

      lines = ["## Breadcrumbs (last #{[MAX_BREADCRUMBS, crumbs.length].min})", ""]
      crumbs.last(MAX_BREADCRUMBS).each do |c|
        data = c["data"] ? " `#{JSON.generate(c['data'])}`" : ""
        lines << "- [#{c['level'].to_s.upcase}] #{format_ts(c['timestamp'])} #{c['category']} — #{c['message']}#{data}"
      end
      lines.join("\n")
    end

    def contexts_section
      return if @event.contexts.empty?

      "## Contexts\n\n```\n#{JSON.pretty_generate(@event.contexts)}\n```"
    end

    # The raw payload is the least important section, so it is the one that
    # shrinks: pretty JSON first, compact JSON second, then clipped. The
    # details block and its fence always close, so the markdown stays valid.
    def raw_payload_section(budget)
      header = "<details>\n<summary>Full event payload</summary>\n\n```json\n"
      footer = "\n```\n\n</details>"
      note = "\n*(payload truncated to fit GitHub issue size limits)*"

      json = JSON.pretty_generate(@event.to_h)
      return "#{header}#{json}#{footer}" if header.length + json.length + footer.length <= budget

      json = JSON.generate(@event.to_h)
      room = budget - header.length - footer.length - note.length
      return "#{header}#{json}#{footer}" if room.positive? && header.length + json.length + footer.length <= budget

      if room.positive?
        "#{header}#{json[0, room]}#{note}#{footer}"
      else
        "*(full event payload omitted: ticket exceeded GitHub issue size limits)*"
      end
    end

    # Last resort for events whose structured sections alone overflow: cut at a
    # line boundary and close any code fence left open.
    def clip_core(text, limit)
      return text if text.length <= limit

      cut = text[0, limit]
      cut = cut[0, cut.rindex("\n")] if cut.rindex("\n")
      fences = cut.lines.count { |l| l.start_with?("```") }
      if fences.odd?
        width = cut.lines.reverse.find { |l| l.start_with?("```") }[/\A`+/].length
        cut << "\n#{'`' * width}"
      end
      "#{cut}\n\n*(sections truncated to fit GitHub issue size limits)*"
    end

    def format_value(v)
      s = v.is_a?(String) ? v : JSON.generate(v)
      s.length > 500 ? "#{s[0, 500]}..." : s
    end

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
