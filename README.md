# sentry_experiment

A prototype error-ticket receiver: it accepts the error event that
sentry-ruby has fully assembled (via a `before_send` hook, or a raw Sentry
envelope POST) and turns each unique error into a well-formatted GitHub
issue ticket, with throttled recurrence notices. No dependency on Sentry's
servers and no dependency on any gem beyond the Ruby stdlib (+ rack
compatibility for mounting).

Built against the payload shape of sentry-ruby 5.10 / sentry-rails 5.10 as
installed under RVM Ruby 3.2.0, but the code runs on plain modern Ruby
(verified on 3.2 and 3.4) with zero installed gems.

## Layout

```
lib/sentry_tickets.rb          entry point
lib/sentry_tickets/config.rb   env-driven configuration
lib/sentry_tickets/store.rb    fingerprint, counts, throttle anchors (JSON file)
lib/sentry_tickets/ticket.rb   GitHub-issue markdown rendering
lib/sentry_tickets/github_sync.rb  thin REST client + dry-run outbox
lib/sentry_tickets/app.rb      the RACK app (POST /events, GET /health, /issues)
bin/serve.rb                   zero-dependency standalone server (stdlib TCPServer)
config.ru                      RACK entry (puma/rackup) for a real deployment
scripts/make_sample_event.rb   generates a real event using the installed SDK
test/                          minitest suite
sample/                        generated sample payloads (gitignored)
data/                          state.json + outbox/ (gitignored)
```

## Running

No gems to install. Any modern Ruby works (3.2/3.4 verified):

```sh
# tests
ruby -Ilib -Itest -e 'Dir["test/*_test.rb"].each { |f| require File.expand_path(f) }'

# dry-run server (no GitHub token): tickets land in data/outbox/ as .md files
TICKET_NOTICE_INTERVAL=2 ruby bin/serve.rb      # port 9292, 127.0.0.1

# real delivery: set repo + token and restart
TICKET_REPO=you/your-repo TICKET_TOKEN=ghp_xxx ruby bin/serve.rb
```

Generate the demo payloads (runs under the RVM 3.2.0 where the 5.10 SDK lives):

```sh
GEM_HOME=$HOME/.rvm/gems/ruby-3.2.0 \
GEM_PATH=$HOME/.rvm/gems/ruby-3.2.0:$HOME/.rvm/rubies/ruby-3.2.0/lib/ruby/gems/3.2.0 \
$HOME/.rvm/rubies/ruby-3.2.0/bin/ruby scripts/make_sample_event.rb

curl -s -X POST --data-binary @sample/event.json   http://127.0.0.1:9292/events
curl -s -X POST --data-binary @sample/envelope.txt http://127.0.0.1:9292/events
```

## Wiring an existing app

In the app's Sentry init, intercept in `before_send` and deliver to the
receiver:

```ruby
TICKET_URL = ENV.fetch("TICKET_URL", "http://127.0.0.1:9292/events")

Sentry.init do |config|
  config.dsn = ENV.fetch("SENTRY_DSN") # keep a valid DSN; the SDK needs it to enable sending

  config.before_send = lambda do |event, _hint|
    uri = URI(TICKET_URL)
    Net::HTTP.post(uri, event.to_json_compatible.to_json, "Content-Type" => "application/json")
    nil # returning nil stops the event from going to Sentry at all
  end
end
```

Notes:

- Returning `event` instead of `nil` double-sends (Sentry + receiver).
- The hook already runs on a background worker thread in the SDK; the POST is
  the only added latency. Keep it small, or queue it if your app also has a
  job system.
- The receiver accepts the same event as a Sentry envelope too (a DSN pointed
  at it would work: it reads the project id from the envelope's DSN header).
- The event hash the hook receives is exactly what this receiver stores and
  renders, including the full raw payload at the bottom of the ticket.

## Behavior

- **Fingerprint** (dedup key): an explicit non-empty `event["fingerprint"]`
  wins; otherwise derived from the raised exception's type + its 10 most
  recent stack frames + message. Volatile data (tags, request ids) is
  deliberately excluded so one bug is one ticket even across requests.
- **First occurrence** of a fingerprint: an issue is opened immediately
  (count is 1).
- **Recurrences**: count increments on every event, but a GitHub notification
  (comment) is only sent once per `TICKET_NOTICE_INTERVAL` (default 6h). The
  comment reports new-since-notice and total counts plus the latest event id.
- **Delivery failures** are recorded on the fingerprint and retried on the
  next occurrence (the count was already persisted, so no event is lost); the
  HTTP response still reports 200 because the sender has handed off ownership.
- **Ticket size**: GitHub rejects issue bodies over 65,536 characters, so
  rendered tickets are capped below that. The raw-payload section switches to
  compact JSON and is clipped first; only an event whose structured sections
  alone overflow gets those clipped too.
- **State** is a single JSON file written atomically; restarts and
  redeploys keep counts and throttle anchors. For a real deployment behind a
  load balancer, put state on shared storage or keep a single instance.

## Known simplifications (prototype scope)

- Inline delivery, no queue (fine at dormant-project scale).
- Single-node state file; not multi-process safe. Within one process the
  ingest-to-delivery path is serialized per fingerprint, so a single
  instance will not double-open an issue.
- Fingerprinting is intentionally simple; Sentry's own is deeper (normalized
  frames, in_app heuristics, user-supplied fingerprint arrays are honored).
- Gzip'd envelopes are accepted (the SDK gzips payloads >= 30KB).
- No authentication on the receiver endpoint itself; put it behind your
  normal internal-network/secret controls.
