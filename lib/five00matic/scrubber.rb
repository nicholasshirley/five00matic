# frozen_string_literal: true

require "json"
require "uri"

module Five00Matic
  # Removes what a ticket must never carry from an event hash before it is
  # grouped, stored and rendered. Cookies, the Authorization header and the
  # Rack env beyond the SDK's default keys go unconditionally. A parameter
  # filter, when given (Rails' ActiveSupport::ParameterFilter built from the
  # app's filter_parameters, or anything that answers filter(hash) with a
  # hash), is applied to the request body and query string, breadcrumb data,
  # user, tags, extra and contexts. The SDK never runs the app's filter over
  # the request body: through sentry-ruby 6 the body goes out as submitted,
  # and 7 masks only top-level keys from its own fixed list, so without this
  # a failed login would file the password.
  class Scrubber
    # sentry-ruby's default rack_env_whitelist. An app that empties it sends
    # the whole Rack env, cookie and credential headers and the raw body
    # included, under names no list of secrets keeps up with.
    RACK_ENV_KEYS = %w[REMOTE_ADDR SERVER_NAME SERVER_PORT].freeze

    def initialize(filter = nil)
      @filter = filter
    end

    # Returns a scrubbed copy; the hash given is left as it was, so Sentry
    # still receives it whole.
    def scrub(payload)
      event = JSON.parse(JSON.generate(payload))
      scrub_request(event["request"]) if event["request"].is_a?(Hash)
      %w[user tags extra contexts].each { |key| event[key] = filtered(event[key]) if event.key?(key) }
      scrub_breadcrumbs(event["breadcrumbs"]) if event["breadcrumbs"].is_a?(Hash)
      event
    end

    private

    def scrub_request(request)
      request.delete("cookies")
      headers = request["headers"]
      headers.delete_if { |name, _| %w[authorization cookie].include?(name.to_s.downcase) } if headers.is_a?(Hash)
      request["env"] = request["env"].slice(*RACK_ENV_KEYS) if request["env"].is_a?(Hash)
      return if @filter.nil?

      request["data"] = filtered_body(request["data"]) if request.key?("data")
      request["query_string"] = filtered_query(request["query_string"]) if request.key?("query_string")
    end

    def scrub_breadcrumbs(breadcrumbs)
      Array(breadcrumbs["values"]).grep(Hash).each { |crumb| crumb["data"] = filtered(crumb["data"]) }
    end

    def filtered(value)
      @filter && value.is_a?(Hash) ? @filter.filter(value) : value
    end

    # A form body arrives as a hash, a JSON body as its text, which is parsed
    # so the filter can see its keys. Other text stays as it is.
    def filtered_body(data)
      case data
      when Hash then filtered(data)
      when String
        parsed = JSON.parse(data)
        parsed.is_a?(Hash) ? filtered(parsed) : data
      else data
      end
    rescue JSON::ParserError
      data
    end

    # sentry-ruby 7 sends the query parsed into a hash. Earlier versions send
    # its text, filtered pair by pair so repeated keys and their order
    # survive. decode_www_form refuses text holding any non-ASCII byte, which
    # a client that does not percent-encode sends and Puma passes on as it
    # came, so those bytes are encoded first.
    def filtered_query(query)
      return filtered(query) if query.is_a?(Hash)
      return query unless query.is_a?(String) && !query.empty?

      ascii = query.b.gsub(/[\x80-\xFF]/n) { |byte| format("%%%02X", byte.ord) }
      URI.encode_www_form(URI.decode_www_form(ascii).map { |key, value| [key, filtered({ key => value })[key]] })
    end
  end
end
