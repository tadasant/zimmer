---
title: Observability
description: What Zimmer ships to an obs stack, how staging and production are told apart, and why a misconfigured deployment looks exactly like a healthy quiet one.
sidebar:
  order: 4
---

Zimmer ships two signals to an external observability stack: **logs** over OTLP/HTTP, and
**errors** to a Sentry-compatible service (GlitchTip). It ships neither metrics nor traces.

Both signals are **off by default** and turn on only when their environment variables are
present. Errors carry a second gate on top of that — they ship from `production` and `staging`
only, [whatever the DSN says](#only-production-and-staging-may-report) — because Zimmer's own
agent sessions run inside the production container and inherit its environment. The env-var
gate alone has a sharp edge worth stating up front:

:::caution[A misconfigured deployment is indistinguishable from a healthy quiet one]
`config/initializers/otel_logs_exporter.rb` and `config/initializers/sentry.rb` are **hard
no-ops** when their env vars are missing. Nothing raises, nothing warns, the app boots
perfectly — and no data ever arrives. A deployment can sit in that state indefinitely without
anything anywhere saying so. Do not infer "no errors" from "no data"; ask the app with
`bin/rails obs:status`.
:::

## What gets shipped

| Signal | Transport | Destination | Enabled by |
| --- | --- | --- | --- |
| WARN/ERROR/FATAL logs | OTLP/HTTP JSON | an OTel collector → VictoriaLogs | `OTEL_LOGS_EXPORTER_ENDPOINT` **and** `OTEL_LOGS_EXPORTER_BEARER_TOKEN` |
| Exceptions | Sentry SDK | GlitchTip | `SENTRY_DSN_BACKEND` **and** `Rails.env` ∈ {`production`, `staging`} |
| Metrics | — | — | not shipped |
| Traces | — | — | not shipped (`traces_sample_rate = 0.0`) |

Both OTLP variables are required. **Either one missing is a silent no-op** — a set endpoint
with an unset token ships nothing at all.

That table is about what the **app** ships. Host telemetry — CPU, memory, disk, load — is the
droplet's, not the app's, and it has its own two paths: DigitalOcean's metrics agent (`var.monitoring`,
on by default, readable in DO's console) and an optional Prometheus `node_exporter` on the tailnet
(`var.node_exporter_enabled`, off by default). Both are
[Terraform variables](/operate/provisioning/#terraform-variables), and Terraform gives both only to a
droplet it creates. An existing droplet has to get DigitalOcean's agent from a
[deploy-time converge](/limitations/#terraform-gives-the-digitalocean-metrics-agent-only-to-a-droplet-it-creates).

Zimmer's failures live in GoodJob background jobs and the session lifecycle, not in HTTP
requests, so that is what the log exporter is shaped around. It ships two kinds of record:

- **`rails.activejob`** — terminal job failures, as structured records carrying `job_class`,
  `queue`, `job_id`, `exception_class`, and `exception_message`. This is the primary signal.
  Only *terminal* failures are emitted: an intermediate `retry_on` attempt that later succeeds
  is not a failure, and does not page anyone.
- **`rails.logger`** — every WARN/ERROR/FATAL line, broadcast off `Rails.logger`. The
  catch-all, so a plain `Rails.logger.error` from anywhere in the app still lands.

### Client-caused rejections are re-logged at INFO, not suppressed

A request the *client* got wrong is not broken server behavior, but Rails logs several of
them at ERROR — and one ERROR line pages `#alerts`. The convention in this codebase is to
handle the exception and re-log the same event at INFO **with the request attached**, so the
signal survives without paging anyone:

| Condition | Handled by | Response | INFO line |
| --- | --- | --- | --- |
| Unmatched route | `ErrorsController#not_found` | 404 | `Unmatched route 404: <verb> <path>` |
| Failed CSRF check | `ApplicationController#invalid_authenticity_token` | 422 | `CSRF verification failed 422: <verb> <path> ip=… session_cookie=present\|absent user_agent="…" reason="…"` |
| A format the action cannot render | `ApplicationController#unknown_format` | 406 | `Unrenderable format 406: <verb> <path> formats=[…] ip=… user_agent="…"` |

None of them weakens the check it reports on. Only the log level and the information content
of the line change — CSRF verification still runs and still aborts the action before it
executes. Three controllers opt out of that check for their own reasons, and the handler
simply never fires for them: `ErrorsController` (`skip_forgery_protection`, because a 404
carries no state to protect), `McpOauthController` (`skip_forgery_protection only:` its three
callback actions), and `PushSubscriptionsController` (`skip_before_action
:verify_authenticity_token`, for the service worker).

The format row is the one where the **status is not what the handler is for**. Asking an
HTML-only action for JSON raises `ActionController::UnknownFormat`, and that exception carries a
Rails `rescue_responses` mapping to `:not_acceptable` — so 406 is the answer with or without the
handler. What the handler decides is the record. Left unrescued, the exception reaches
`ActionDispatch::DebugExceptions`, which logs at ERROR, and one ERROR record pages; handled, it
is one INFO line naming the client that asked. Production emitted exactly two of these in
fourteen days, from `TriggersController#show` and `ConnectorsController#index`
([#453](https://github.com/tadasant/zimmer/issues/453)) — two different HTML-only actions, same
exception, one page each.

Two things keep the handler narrow, and the first is easy to get wrong.
`ActionController::MissingExactTemplate` — what Rails raises when an action has no template in
*any* format on an ordinary browser page load — is a **subclass** of `UnknownFormat`, and
`rescue_from` matches subclasses, so a lone `rescue_from ActionController::UnknownFormat` would
swallow a forgotten view into a quiet 406 as well. `ApplicationController` therefore declares a
second, more specific handler that re-raises it; handler lookup runs in reverse declaration
order, so the specific one wins and a missing template stays a loud ERROR — and a GlitchTip
event, since the Sentry initializer subtracts `UnknownFormat` from its inherited exclusions for
exactly this subclass ([details](#a-rate-of-csrf-rejections-pages-a-single-one-does-not)). Second, the reach is
the web UI and nothing else: the JSON API descends from `Api::BaseController <
ActionController::API` and Administrate from `Administrate::ApplicationController`, so neither
inherits the handler and a format error on either of those surfaces is left to surface on its
own terms.

One class of genuine defect does land at INFO, and the log line is shaped to make it findable: a
`respond_to` block with no branch for the format a client actually sent raises the same
`UnknownFormat` as an HTML-only action, and nothing distinguishes them from the outside.
`InferenceController#refresh_account` is the live example — `turbo_stream` only, so a POST that
arrives without Turbo's `Accept` header gets a 406. That is why the record carries `action=` as
well as `path`: a defect of this kind shows up as one action recurring, where a client mistake
shows up as one client wandering.

Two fields carry the triage on a CSRF record. **`session_cookie`** separates client
populations: *present* means a browser that has been here before — a stale form, an expired
session, a tab left open across a deploy — and *absent* means an unauthenticated probe.
**`reason`** separates causes: `Can't verify CSRF token authenticity.` is a missing or stale
token, genuinely client-side, while `HTTP Origin header (…) didn't match request.base_url
(…)` is a *server* fault — a proxy that stopped forwarding `X-Forwarded-Proto` or `Host`
breaks every write for every real user. A sustained rate of either is the real signal; a
single record is not.

:::caution[These INFO lines are not in VictoriaLogs]
The exporter ships WARN and above, so an INFO record reaches container stdout and nothing
else. Grafana still shows the context-free WARN Rails logs from inside
`handle_unverified_request`; the attributable line next to it has to be read from the
container. See [limitations](/limitations/#a-csrf-failure-still-ships-a-context-free-warn-and-is-still-counted-per-record).

A *rate* of CSRF rejections is the exception, and it is handled separately — see
[a rate of CSRF rejections pages, a single one does not](#a-rate-of-csrf-rejections-pages-a-single-one-does-not).
:::

### WARN is also how a deliberate change gets a record

Not every WARN is a failure. `[FleetPolicy]` lines are the other use of the level: one per
persisted change to the fleet-scheduling policy — the spot gate, the concurrency limit, the
backlog top-up thresholds — naming the surface that made it, the calling session where there is
one, and every value that moved.

```logsql
{service.name="zimmer"} deployment.environment:=production "[FleetPolicy]"
```

The level is chosen for reach rather than for severity. These settings decide how much work the
fleet does, they can be moved from three separate surfaces, and a change to one is otherwise
invisible; at INFO the record would reach container stdout and nothing else, and there is no shell
on the production box to read stdout with. WARN does not page, so the record costs nobody a
notification. See [Every change to these numbers is
recorded](/sessions/spot-and-priority/#every-change-to-both-ceilings-is-recorded).

### A failure the code recovered from is logged at WARN, not ERROR

The same convention on the job side. A poller that hits a Slack 429, defers itself, and
re-reads the same work on the retry has not failed at anything — but if it logs the 429 at
ERROR, one rate-limit burst pages the on-call about an incident in which nothing was lost.
`SlackTriggerPollerJob` did exactly that twice ([#509](https://github.com/tadasant/zimmer/issues/509));
the ERROR line was the only artifact of the second one.

So the rule for a retryable external failure is: **log it at the level that matches what
actually happened to the work.**

| What happened to the work | Level | In `SlackTriggerPollerJob` |
| --- | --- | --- |
| Slack threw a fetch away before its cursor moved, so the deferred poll re-reads it | WARN | the per-channel / per-thread / per-DM rescues, and each deferral |
| The retry budget is spent — five deferrals, ~15 minutes of unavailability | ERROR | the give-up line, alongside its GlitchTip report |
| The failure loses work the deferral cannot bring back | ERROR | `#process_message`, whose caller advances the cursor past that message either way, and `#fetch_recent_history`, which degrades to an empty slice its callers finish the sweep trusting |
| Not transient at all — a renamed channel, a bad cursor, a bug in the job | ERROR | every non-`TransientError` in those same rescues |

The third row is why this is a property of the **call site** rather than of the exception. The
same `SlackService::RateLimitedError` is a recovery at one rescue and a lost message at
another, so demoting by exception class alone would silence the ones that matter.

Nothing is suppressed and no message content is dropped: Slack's own words, the channel, and
the thread stay in the line. Only the severity changes, which is what makes the ERROR that
does appear worth reading.

### A client that has already disconnected is logged at DEBUG, not ERROR

ActionCable applies the same reasoning to WebSockets, and upstream Rails surfaces three benign
client-disconnect races at ERROR. Each one is a browser tab that went away — a navigation, a
laptop sleeping, a reconnect — with the server still mid-operation. Nothing is broken, nothing
is retryable, and the ActionCable consumer re-subscribes on its own when the client comes back.
Two initializers downgrade all three:

| Race | Where it surfaces | Initializer |
| --- | --- | --- |
| A socket operation against a peer that already went away (`Errno::EPIPE`, `ECONNRESET`, `EOFError`, …) | `Connection::Base#on_error` | `action_cable_benign_socket_error_log_level.rb` |
| An inbound frame dispatched off the async worker pool after the socket closed | `Connection::Base#dispatch_websocket_message` | `action_cable_benign_socket_error_log_level.rb` |
| A stale or duplicate `unsubscribe` for a subscription the connection no longer holds | `Connection::Subscriptions#execute_command`'s catch-all rescue, reached by `#remove` | `action_cable_idempotent_unsubscribe.rb` |

The middle row is the one that bites hardest, because it is not one line per disconnect.
`#receive` hands every frame to `send_async :dispatch_websocket_message`, so a tab that drops
its socket with *n* frames in flight logs *n* ERRORs in a single burst — a session page with
three `turbo_stream_from` streams, re-subscribing on reconnect, produced six inside 10 ms
([#624](https://github.com/tadasant/zimmer/issues/624)).

The first two rows preserve upstream's log text byte for byte, so only the severity changes.
The third cannot: upstream `#remove` *raises* through `execute_command`'s catch-all rescue
rather than logging, so the patch makes the removal idempotent and emits its own DEBUG line in
place of the exception.

Only the benign set moves. A genuine WebSocket error, an unrecognized command, and a `find`
failure on the `perform_action` path all still log at ERROR.

Each override is a method body copied from a specific actioncable release, so the real risk is
silent drift: a `bundle update` that changes upstream leaves the copy in place and nothing goes
red. `test/initializers/` covers each override's contract and additionally asserts
`ActionCable::VERSION::STRING`, so a Rails upgrade fails that guard and lands the prompt to
re-read the upstream source on the upgrade PR itself.

### A lifecycle state the session has not reached yet is logged at INFO, not ERROR

The fourth variant of the same rule, and the one that catches application code rather than a
framework. A piece of session metadata that a later step writes is *absent* before that step
runs, so reporting the absence at ERROR turns a normal point in the lifecycle into a page.

`TranscriptPollerService#get_transcript_directory` reads `working_directory`, which
`AgentSessionJob` writes with the clone, before `start!` moves the session to `running`. A
`spot` session held for quota headroom sits in `waiting` for as long as the hold lasts, and
the poller can touch it minutes before it is ever spawned — so the first production
occurrence of that ERROR line was a session on which nothing had gone wrong and nothing was
left for a human to do ([#473](https://github.com/tadasant/zimmer/issues/473)).

**The session's own state is what tells the two cases apart, not the missing value** — "no
`working_directory`" is exactly what they share:

| The session is… | Level | Because |
| --- | --- | --- |
| `waiting` — held for quota, queued behind the fleet cap, waiting on a clone | INFO | it has not been spawned, so there is nothing to have written the key |
| any other state — `running`, `needs_input`, `failed`, `archived` | ERROR | the spawn should have written the key, so its absence is a real defect |

The exemption is drawn no wider than `waiting` deliberately. Widening it to "any session
without the key" would swallow the case the line exists to catch, which is the worse of the
two failures: an alert nobody needs is noise, a defect nobody sees is not. One benign ERROR
survives that choice on purpose — `restart_from_scratch` strips `working_directory` and
resumes the session to `running` before the re-clone writes a new one, and a poll inside that
window is indistinguishable by state from a genuine defect. See
[limitations](/limitations/#a-restart-from-scratch-can-still-page-before-its-re-clone-finishes).

Only the ERROR moves. The caller, `TranscriptPollerService#poll_and_broadcast`, still logs its
own WARN for the same poll and still returns `false` — a pre-spawn poll leaves a record in
VictoriaLogs either way. WARN does not page, which is the whole difference.

## How environments, builds and containers are told apart

Every batch carries four resource attributes:

```
service.name           = zimmer                 (or $OTEL_SERVICE_NAME)
deployment.environment = <Rails.env>            (production / staging)
service.version        = <commit SHA>           (omitted if the build baked none in)
service.instance.id    = <hostname>-<pid>       (or $OTEL_SERVICE_INSTANCE_ID)
```

**`deployment.environment` is the only thing separating staging from production.** Both
environments ship as `service.name=zimmer`, on purpose: one service, two deployments. Scope
every query and every alert rule with it.

```logsql
{service.name="zimmer"} deployment.environment:=staging severity_text:in("ERROR","FATAL")
```

:::danger[Alert rules must filter on `deployment.environment`]
An alert rule that selects only on `{service.name="zimmer"}` will fire on **staging** noise as
if it were production. Staging is for reading, not for paging. Scope production alert rules to
`deployment.environment="production"`.
:::

Errors are separated a second way, and a stronger one: staging and production point at
**different GlitchTip projects**. A DSN selects a project, and GlitchTip's alert rules are
per-project with no environment filter — so sharing one DSN across both environments would
make every staging error page the production alert channel, forever. Give staging its own
project and its own DSN.

### `service.version` says which deploy a record came from

`service.version` is the commit the running image was built from. Without it a burst of
errors carries no build identity at all, and pinning it to the deploy that caused it means
reading GitHub Actions job timings by hand — which is exactly what a job-claim query
crashing seconds after a Kamal cutover once cost
([#736](https://github.com/tadasant/zimmer/issues/736)).

It is baked in at build time, not read from the deploy environment:

1. `.github/workflows/release-image.yml` (all three build attempts) and
   `.github/workflows/deploy-staging.yml` pass `GIT_SHA=<commit>` to
   `docker/build-push-action`.
2. The `Dockerfile`'s `ARG GIT_SHA` / `ENV ZIMMER_GIT_SHA=${GIT_SHA}` carries it into the
   running container.
3. `OtelLogsExporter` reads `ZIMMER_GIT_SHA` at boot. `OTEL_SERVICE_VERSION` overrides it.

**An image built any other way — a hand-run `docker build`, a dev machine, `rails console`,
the test suite — has no commit baked in, and the attribute is then omitted entirely rather
than shipped empty.** A blank `service.version` would match a selector for the attribute
while identifying nothing. `bin/rails obs:status` prints which of the two states this
instance is in, so a missing field in Grafana does not have to be guessed at.

```logsql
{service.name="zimmer"} deployment.environment:=production severity_text:="ERROR"
  | stats by (service.version) count()
```

### `service.instance.id` says which container

Production runs the `web` and `worker` roles as separate containers under one
`service.name`, so without an instance identifier a burst confined to the workers reads
exactly like one affecting everything. `service.instance.id` defaults to `<hostname>-<pid>`
and `OTEL_SERVICE_INSTANCE_ID` overrides it.

The hostname is not the container id: Kamal boots each container with
`--hostname "<deploy host, truncated>-<6 random bytes>"`, regenerated on every boot. So the
value is unique per running container and changes when that container is replaced — which is
what makes it usable for "is this burst one instance or all of them?":

```logsql
{service.name="zimmer"} deployment.environment:=production severity_text:="ERROR"
  | stats by (service.instance.id) count()
```

**It identifies the container, not its role.** One instance standing out tells you the burst
is confined; it does not tell you that instance is the worker. Answering *that* would need an
attribute carrying the role, and there isn't one — cross-reference `scope.name`
(`rails.activejob` records only come from a worker) or the job attributes on the record.

## Only production and staging may report

`config/initializers/sentry.rb` sets an environment allowlist:

```ruby
config.enabled_environments = %w[production staging]
```

Any other `Rails.env` — `test`, `development`, an ad-hoc one — drops events at the client,
**even when `SENTRY_DSN_BACKEND` is set**. That last clause is the whole point, and it is not
belt-and-braces.

Zimmer runs its agent sessions *inside the production container*. That is deliberate, but it
means the production DSN is present in the environment of every agent-session shell. Without
the allowlist, the first `bin/rails` command an agent runs in a repo clone — in any
`RAILS_ENV` — initializes the SDK against the **production** GlitchTip project, and the
clone's exceptions arrive as production errors on the production Slack alert channel. It is
not a hypothetical: a `RAILS_ENV=test bin/rails db:prepare` failing against an agent's scratch
Postgres paged `#alerts` with a database error that never happened in production
([#176](https://github.com/tadasant/zimmer/issues/176)).

A guard on "is the DSN set?" cannot prevent that, because the DSN genuinely is set. Only the
environment gate holds. Two layers now enforce it:

- **The initializer** refuses to send outside production/staging — the Rails-layer guarantee.
- **The spawn env** (`CliSpawnEnv#clear_inherited_env_vars`) unsets `SENTRY_DSN_BACKEND` in
  every agent-session child process, alongside `DATABASE_*`, `RAILS_ENV`, and the operator SSH
  key. The agent's shell never sees the production DSN at all, for any tool an agent session
  spawns — not just Rails ones. A clone that wants its own DSN can still set one in its `.env`.

## An interactive `rails runner` on the box does not page

sentry-rails ships a `runner` hook that reports every uncaught `bin/rails runner` exception
with the tag `source: runner`. On the production droplet that one tag covers two things that
have nothing in common.

One is the deploy workflow's job-drain gate, which shells into the web container twice — once
with an inline one-liner to ask the *deployed* image which queues it knows about, and once
with `bin/rails runner -` to feed it the canary script on stdin. An exception there means the
deploy is unverified, and it should page.

The other is an operator typing a one-liner by hand. On 2026-09-02, five attempts at guessing
a column name (`initial_prompt`, `error`, `last_error_class`, `arguments`, `completed_at` —
none of which exists) raised five `PG::UndefinedColumn`s, which opened five GlitchTip issues,
which paged `#alerts` five times, which spawned four priority router sessions in one hour
([#767](https://github.com/tadasant/zimmer/issues/767)). Nothing was wrong with the app.

`config/initializers/sentry.rb` drops the second and keeps the first, and the only thing it
keys on is a **controlling terminal**:

```ruby
config.before_send = lambda do |event, _hint|
  begin
    source = event.tags[:source]
    attached_to_terminal = [ $stdin, $stdout, $stderr ].any?(&:tty?)

    if source.to_s == "runner" && attached_to_terminal
      Rails.logger.info("[sentry] dropped an interactive rails runner event: …")
      next nil
    end
  rescue StandardError
    # fail open — see below
  end

  event
end
```

A terminal is the *only* signal that separates them. In particular the shape of the code does
not: the drain gate uses both an inline argument and a stdin-fed script, so a filter keyed on
"the code was typed as an argument" would silence its queue-capability probe. Neither of its
invocations allocates a TTY — no `docker exec -t`, and both capture their output into a shell
variable — and no GitHub Actions step has one either. A human at a `docker exec -it` prompt
does.

:::caution[Draw this filter wider and it fails silently]
Dropping every `source: runner` event, or adding a global `SENTRY_SUPPRESS` off-switch, would
also drop the drain gate's exceptions — and nothing would tell you. There is no error when an
alert that should have paged does not.

Three things follow from that, and all three are in the code above. The predicate lives inline
in the initializer, with no autoloaded constant that could fail to resolve. It **logs what it
drops** (exception class only — a console one-liner's message can carry row data), so the
decision is greppable in the container log instead of invisible. And it **fails open**, because
the SDK does not: a raise inside `before_send` loses the event either way — swallowed by
`Sentry::Client#capture_event`'s rescue on the synchronous path, which is the one `rails runner`
takes since sentry-rails' runner hook forces `background_worker_threads = 0`, and by the
background worker thread in Puma and GoodJob. A bug in this filter would therefore be exactly
the project-wide mute it exists to avoid, so anything unexpected reports the event instead.

`test/initializers/sentry_test.rb` pins all four claims — the console typo drops, the
non-interactive runner still reports, non-runner events are untouched, a predicate that raises
still reports — because those tests are the only thing that would notice.
:::

An operator who *wants* a console exception recorded still has one: run it without a terminal
(`docker exec` with its output piped, which is what automation does anyway).

## A rate of CSRF rejections pages; a single one does not

`excluded_exceptions` does not start empty. sentry-ruby seeds it with seven names, and
sentry-rails' `after(:initialize)` hook concatenates fifteen more
(`Sentry::Rails::IGNORE_DEFAULT`'s fourteen, plus `ActionController::TooManyRequests` on
Rails ≥ 8.1.1) **before** `config/initializers/sentry.rb` runs. The initializer's own list
only appends, and nothing audited what it inherited.

`ActionController::InvalidAuthenticityToken` is in that inherited list, and the bill came due
in [#19](https://github.com/tadasant/zimmer/issues/19): `assume_ssl` on a plain-HTTP tailnet
deploy made the app's computed origin disagree with the browser's, **every write in the UI
failed CSRF validation for hours**, and GlitchTip received nothing at all — the events were
dropped in the SDK, before any transport. A human found the outage by clicking a button
([#23](https://github.com/tadasant/zimmer/issues/23)).

The default is right for what it was written for. One CSRF rejection is a stale form, a tab
left open across a deploy, or a client posting without a token. **A hundred an hour is the
app being broken for every writer**, and the two are the same exception. So the initializer
subtracts it, and `CsrfRejectionMonitor` supplies the missing distinction:

```ruby
config.excluded_exceptions -= [
  "ActionController::InvalidAuthenticityToken",
  "ActionController::UnknownFormat"
]
```

- Every rejection `ApplicationController` handles increments a counter in a **tumbling
  five-minute bucket** (`Rails.cache`, which is Redis in production).
- The rejection that pushes a bucket to **10** captures **one** exception to GlitchTip — with
  the count, the verb, the path, the user agent, whether a session cookie was present, and the
  exception message that separates a stale token from an `Origin` mismatch — under the fixed
  fingerprint `csrf-rejection-rate`, and emits **one** `WARN` so the same conclusion is
  reachable from VictoriaLogs.
- Every later rejection in that bucket is silent.

So on the `ApplicationController` path — the whole web UI — the loudest possible storm costs
one event and one WARN per five minutes, and the quiet base rate costs nothing: per the triage
on #23, the record that first tripped the log-based alert on 2026-08-02 was the only
`InvalidAuthenticityToken` in production across the 14-day VictoriaLogs retention window.

**Two surfaces have no such handler, and report per request.** `/supervisor`
(`Supervisor::ApplicationController < Administrate::ApplicationController`) and `/jobs` (the
GoodJob engine, `protect_from_forgery with: :exception`) never see `ApplicationController`'s
`rescue_from`, so a tokenless non-GET there raises through the capture middleware. Both already
log that failure at ERROR, which pages; GlitchTip receives the twin of the page, carrying the URL
and user agent the log record lacks. On this deployment the host is tailnet-only, so the only
clients that can reach either surface are tailnet members. The fixed fingerprint is what keeps
those per-request events and the rate report from sharing an issue — without it, a storm's report
could land as one more event on an issue opened weeks earlier by a single stray POST.

**`UnknownFormat` is subtracted for its subclass.** Exclusion matches with `===`, so an entry
silences every subclass of what it names. `ActionController::MissingExactTemplate` — an action with
no template in *any* format, on an ordinary browser page load: a forgotten view — is a subclass of
`UnknownFormat`, and `ApplicationController` deliberately re-raises it to keep it loud. It reached
the capture middleware and was dropped there. Plain `UnknownFormat` is still handled at INFO by
`ApplicationController#unknown_format`, so on the web UI nothing about it changes.

Three properties are worth stating because each was a choice:

**Subtraction, not a rewrite.** `-=` removes a name if the SDK ships it and is a harmless no-op if
a future sentry-rails stops. What it cannot catch is the SDK excluding a class under another name
or via a new ancestor, so `test/initializers/sentry_test.rb` pins the whole resolved list and
asserts the *behaviour* — that the fully-resolved configuration builds an event for each
subtracted class — rather than trusting the array.

**A global subtraction, not a monitor-only bypass.** The monitor could have kept the exclusion and
passed `hint: { ignore_exclusions: true }` to its own capture. That would have left `/supervisor`
and `/jobs` out of GlitchTip — silently swallowed, which is the shape #23 is about.

**It fails closed on reporting, not open.** RedisCacheStore's `failsafe` rescues a connection
error, hands it to the configured `error_handler` — which logs it at ERROR, so a dead Redis is loud
on its own — and returns `nil`. No counter means no report. Reporting *every* rejection when the
counter is unavailable would be an unbounded flood into the alert path, which is the failure this
exists to prevent. The per-record INFO line survives regardless.

**The rest of the inherited list was audited in the same pass and deliberately left alone**, with
the reason for each recorded inline in the initializer. `RoutingError` and
`ActiveRecord::RecordNotFound` are handled by `ErrorsController` and `record_not_found`, so
subtracting them reaches nothing; nine classes are malformed input at the protocol edge, each the
client's mistake with no server-side cause a rate would reveal; three are re-added by the
initializer on purpose; `ParameterMissing` (with its subclass `ExpectedParameterMissing`),
`ActionNotFound` and `TooManyRequests` are arguable, kept, and argued in the file; and
`Mongoid::Errors::DocumentNotFound`, `Sinatra::NotFound` and `ActionController::UnknownAction`
name no class loaded in this app, so they are inert.

## Configuring it

The three variables reach the container as Kamal secrets (`env.secret` in
`config/deploy.<dest>.yml`, mapped in `.kamal/secrets.<dest>`). They are deploy-time
environment rather than `mcp_secrets` in `config/credentials/<env>.yml.enc`, because the
initializers read `ENV` — and because staging's encrypted credentials are themselves
optional, so a telemetry config that depended on them would inherit that fragility.

Staging's deploy-side names are `STAGING_`-prefixed, like every other staging secret:

| GitHub Actions secret | Value |
| --- | --- |
| `STAGING_OTEL_LOGS_EXPORTER_ENDPOINT` | the collector's logs endpoint, e.g. `https://obs.example.com/otel/v1/logs` (no trailing slash) |
| `STAGING_OTEL_LOGS_EXPORTER_BEARER_TOKEN` | the shared secret the ingest gateway checks |
| `STAGING_SENTRY_DSN_BACKEND` | the DSN of a **staging-only** GlitchTip project |

`Deploy staging` prints an **observability preflight** block on every run reporting which of
these are actually set, so an unset secret is a line you can read rather than a thing you have
to discover months later.

Staging shares production's **ingest token**, and that is not an oversight. The obs stack's
ingest gateway matches one bearer value, so there is no such thing as a staging-only ingest
credential — and none is needed, because the two environments are separated by
`deployment.environment`, not by their credential. Sharing the token lets staging in; the
attribute keeps it out of production's alerts. The **DSN** is the opposite case and must not
be shared, for the reason [above](#how-environments-are-told-apart): it selects a GlitchTip
project, and a project is exactly what alerting keys on.

Once both secrets are set, `Deploy staging` verifies the claim rather than assuming it: after
the health-gated cutover it runs `bin/rails obs:smoke` inside the deployed container and
**fails the run** if the collector rejects the ingest (a 401 on the token, a 404 on the path)
or if the exporter is off despite both secrets being present. Deploying a staging box that
silently ships nothing is no longer a thing that can happen quietly — production has no
equivalent gate, since it deploys from a separate repo.

## Diagnosing it

Two rake tasks exist because "no data in Grafana" is not a diagnosis. Neither prints a bearer
token or a DSN key, so their output is safe to paste anywhere.

```bash
bin/rails obs:status
```

Reports whether each signal is ON or OFF, where it points, and the labels everything is
stamped with — including whether this image has a `service.version` baked in, and the
`service.instance.id` of the process the task itself is running in. That last one is the
throwaway `kamal app exec` container, not the web or worker container serving traffic.

```bash
bin/rails obs:smoke
```

Pushes a uniquely-tagged record through every live path — and, crucially, performs a
**synchronous ingest probe** that reports the collector's HTTP status code. The background
exporter thread can only ever warn to stderr, which means a bad token, a bad path, and an
unreachable collector are all indistinguishable from "nothing went wrong today". The probe
turns that silence into an answer:

| Result | Means |
| --- | --- |
| `✅ accepted (HTTP 200)` | ingest works; if data is still missing, the query is wrong, not the pipeline |
| `❌ rejected (HTTP 401)` | the bearer token does not match the ingest gateway |
| `❌ rejected (HTTP 404)` | the endpoint path is wrong |
| `❌ rejected (error: …)` | the collector is unreachable from this host |

It prints the marker it emitted and the exact LogsQL query that confirms the record landed.

## Retry budgets on the health surface

`HealthMonitorService#retry_budget_health` reports every bounded auto-recovery loop
Zimmer runs — SIGTERM retry, API-error retry, signal-death resume, MCP connection retry,
context-length compact, session-id conflict recovery, empty-turn restart, silent-recovery
restart, lost-clone recovery — as one uniform section, rendered on `/health`, returned by `GET /api/v1/health`, and included in the
`get_system_health` MCP tool's JSON. Per budget it carries the declared counter key, the
maximum, how many sessions have spent any of it, total attempts, how many recovered, how
many **came to rest with the budget fully spent**, and how many attempts happened in the
last 24 hours.

"Came to rest" rather than "failed", because running out is not the same ending for every
loop: all but one fail the session, and the empty-turn restart parks it in `needs_input`
with an empty transcript instead. Each budget declares its own `terminal_status`, so the
exhausted count means the same thing on every row.

That count is the one to reach for when the question is "why did this session stop": it is
answerable for every declared loop. It was answerable for two of them until #527 — the section
was built by naming metadata keys in SQL, and only SIGTERM and API-error had ever been
wired, so a session that burned through its MCP-connection or compact budget was invisible
to every health surface while the dashboard read as complete. The section is now built by
enumerating `RetryBudget.all`, so a budget appears because it was declared, which is what
brought the last two onto the surface in #727. See
[Retry budgets](/sessions/spawning/#retry-budgets).

The SIGTERM and API-error panels remain alongside it: they carry rate-limit pressure and
account-quota detail the generic section has no equivalent of. They read their numbers
from the same per-budget query rather than from a second copy of it.

## Failure mode

If the collector is down or wedged, the exporter's background thread logs once and **drops the
batch**. Exports never block a job or a log call: they happen on a separate thread behind a
bounded queue (1,000 records, ~1 MB), and a full queue drops rather than blocks. Telemetry
loss is always preferred over application stalls — so treat the log stream as best-effort, not
as an audit trail.
