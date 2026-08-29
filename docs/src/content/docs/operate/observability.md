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

Neither one weakens the check it reports on. Only the log level and the information content
of the line change — CSRF verification still runs and still aborts the action before it
executes. Three controllers opt out of that check for their own reasons, and the handler
simply never fires for them: `ErrorsController` (`skip_forgery_protection`, because a 404
carries no state to protect), `McpOauthController` (`skip_forgery_protection only:` its three
callback actions), and `PushSubscriptionsController` (`skip_before_action
:verify_authenticity_token`, for the service worker).

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
:::

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
| The retry budget is spent — five deferrals, ~15 minutes of unavailability | ERROR | the give-up line, alongside its `AlertService` alert |
| The failure loses work the deferral cannot bring back | ERROR | `#process_message`, whose caller advances the cursor past that message either way |
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

## How environments are told apart

Every batch carries two resource attributes:

```
service.name           = zimmer          (or $OTEL_SERVICE_NAME)
deployment.environment = <Rails.env>     (production / staging)
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
stamped with.

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

## Failure mode

If the collector is down or wedged, the exporter's background thread logs once and **drops the
batch**. Exports never block a job or a log call: they happen on a separate thread behind a
bounded queue (1,000 records, ~1 MB), and a full queue drops rather than blocks. Telemetry
loss is always preferred over application stalls — so treat the log stream as best-effort, not
as an audit trail.
