# sentry_experiment

A prototype error-ticket receiver: it accepts the error event that
sentry-ruby has fully assembled (via a `before_send` hook) and turns each
unique error into a well-formatted GitHub issue ticket, with throttled
recurrence notices. No dependency on Sentry's servers and no dependency on
any gem beyond the Ruby stdlib (+ rack compatibility for mounting).

Built against the payload shape of sentry-ruby 5.10 / sentry-rails 5.10 as
installed under RVM Ruby 3.2.0, but the code runs on plain modern Ruby
(verified on 3.2 and 3.4) with zero installed gems.

## Layout

```
lib/sentry_tickets.rb          entry point
lib/sentry_tickets/config.rb   env-driven configuration
lib/sentry_tickets/event.rb    the SDK payload: fingerprint, title, sections
lib/sentry_tickets/group.rb    one fingerprint: counts, its issue, notice anchors
lib/sentry_tickets/store.rb    the groups, persisted (JSON file)
lib/sentry_tickets/ticket.rb   GitHub-issue markdown rendering
lib/sentry_tickets/github.rb   thin GitHub REST client
lib/sentry_tickets/outbox.rb   dry-run stand-in: tickets as markdown files
lib/sentry_tickets/tracker.rb  record an occurrence, deliver what GitHub is owed
lib/sentry_tickets/app.rb      the RACK app (POST /events, GET /health, /issues)
bin/serve.rb                   zero-dependency standalone server (stdlib TCPServer)
config.ru                      RACK entry (puma/rackup) for a real deployment, mounted at /sentry
scripts/make_sample_event.rb   generates a real event using the installed SDK
test/                          minitest suite
sample/                        generated sample payloads (gitignored)
data/                          groups.json + outbox/ (gitignored)
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

# an error filed only to the outbox has no GitHub issue yet; its next
# occurrence after the switch opens one. Changing TICKET_REPO works the same
# way: issues stay with the repo they were opened in.
```

Generate the demo payloads (runs under the RVM 3.2.0 where the 5.10 SDK lives):

```sh
GEM_HOME=$HOME/.rvm/gems/ruby-3.2.0 \
GEM_PATH=$HOME/.rvm/gems/ruby-3.2.0:$HOME/.rvm/rubies/ruby-3.2.0/lib/ruby/gems/3.2.0 \
$HOME/.rvm/rubies/ruby-3.2.0/bin/ruby scripts/make_sample_event.rb

curl -s -X POST --data-binary @sample/event.json http://127.0.0.1:9292/events
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
    begin
      Net::HTTP.post(uri, event.to_json_compatible.to_json, "Content-Type" => "application/json")
      nil # returning nil stops the event from going to Sentry at all
    rescue StandardError
      event # receiver unreachable: fall back to Sentry rather than losing the event
    end
  end
end
```

Notes:

- Returning `event` instead of `nil` double-sends (Sentry + receiver).
- If the POST raises (receiver down), the SDK's background worker logs the
  error and drops the event - and returning `nil` means Sentry never saw it
  either. The rescue above returns `event` so Sentry takes it as a fallback;
  drop the rescue if you would rather lose the event than double-report.
- The hook already runs on a background worker thread in the SDK; the POST is
  the only added latency. Keep it small, or queue it if your app also has a
  job system.
- `before_send` is the only intake. Don't point `SENTRY_DSN` at the receiver:
  the SDK would post envelopes to `/api/<project>/envelope/`, which it does
  not serve.
- The event hash the hook receives is exactly what this receiver stores and
  renders, including the full raw payload at the bottom of the ticket.

## Behavior

- **Fingerprint** (dedup key): an explicit non-empty `event["fingerprint"]`
  wins; otherwise the raised exception's type + the file and function of
  each in-app stack frame (every frame, when the SDK marked none in-app).
  Line numbers, messages and tags are deliberately left out: they vary
  between occurrences of one bug (a deploy shifts lines; messages carry ids
  and, on Ruby 3.2, object addresses; tags carry request ids). The message
  is used only for an exception with no stack trace, or a message event.
- **Rejected with 400**: a body that is not a JSON object, one holding
  invalid UTF-8 or a non-finite number (the SDK can produce neither), and an
  event with neither an exception nor a message. Sections of an unexpected
  shape are otherwise read as empty rather than refused.
- **First occurrence** of a fingerprint: an issue is opened immediately
  (count is 1).
- **Recurrences**: count increments on every event, but a GitHub notification
  (comment) is only sent once per `TICKET_NOTICE_INTERVAL` (default 6h). The
  comment reports new-since-notice and total counts plus the latest event id.
- **Delivery failures** are recorded on the fingerprint and retried on the
  next occurrence (the count was already persisted, so no event is lost); the
  HTTP response still reports 200 because the sender has handed off ownership.
  If GitHub answers 404 for a recurrence comment (the tracked issue was
  deleted, or the repo was re-created), the dead issue is dropped and a
  replacement opened; should that fail too, the next occurrence opens one.
- **Ticket size**: GitHub rejects issue bodies over 65,536 characters, so
  rendered tickets are capped below that. The raw-payload section switches to
  compact JSON and is clipped first; only an event whose structured sections
  alone overflow gets those clipped too.
- **State** is a single JSON file (`data/groups.json`) written atomically;
  restarts and redeploys keep counts and throttle anchors. State and outbox files carry
  event content (user ids, request bodies) and are written owner-only
  (0600). For a real deployment behind a load balancer, put state on shared
  storage or keep a single instance.

## Known simplifications (prototype scope)

- Inline delivery, no queue (fine at dormant-project scale).
- Delivery is at-least-once: if GitHub times out after creating an issue but
  before the response arrives, the retry opens a duplicate issue. Issue
  creation has no idempotency key.
- Single-node state file; not multi-process safe. Within one process the
  ingest-to-delivery path is serialized per fingerprint, so a single
  instance will not double-open an issue.
- `bin/serve.rb` is a convenience, not a server: thread-per-connection, no
  read or header timeouts, no chunked-encoding or request-size limits. A
  slow client can hold a thread open; a hostile one can hold many. For
  anything but local use, run `config.ru` behind a real app server instead.
- Fingerprinting approximates Sentry's: two raises of one exception type in
  the same method share a ticket, and `{{ default }}` in an explicit
  fingerprint is taken literally rather than expanded.
- No authentication on the receiver endpoint itself; put it behind your
  normal internal-network/secret controls.
