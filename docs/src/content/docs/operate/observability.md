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

## The same gate on the alert path

Exceptions are not the only way into `#alerts`. `AlertService.raise_alert` posts there directly,
and every poller and trigger job calls it — that is how an operator learns a Slack poll or a
trigger condition is failing.

That path needs the identical gate, for the identical reason, so `app/services/alert_service.rb`
carries its own allowlist:

```ruby
ENABLED_ENVIRONMENTS = %w[production staging].freeze
```

`AlertService.configured?` — "is there a Slack token and a channel id?" — cannot stand in for it.
A token proves nothing about *which environment is holding it*. Agent sessions run inside the
production container, and unlike `SENTRY_DSN_BACKEND` the Slack credentials are **not** stripped
from an agent's shell by `CliSpawnEnv`: `SLACK_BOT_TOKEN` is deliberately passed through to the
`slack-workspace` MCP server (`mcp.json`), so an agent's `RAILS_ENV=test bin/rails test` is
"configured" in exactly the way production is. Any alert its tests exercise then pages the
on-call channel with **fixture** data.

That is not hypothetical either. A test run of a GitHub-trigger poller paged `#alerts` with:

```
Condition 949208330 on trigger 'Ready-to-merge PR gate' (ID: 887723230) failed:
wrong number of arguments (given 2, expected 3)
```

Those ids are `ActiveRecord::FixtureSet.identify` hashes of fixture labels, and the trigger names
are fixture names — but nothing in the alert says so, so it was read back as a production outage
and triaged as one. The environment allowlist is what makes an alert's presence in the channel
mean what it claims to mean.

The guard also declines *before* the dedup cache is written, so a non-production run cannot
consume the dedup window and silence the same alert in production for the next hour.

:::note[Why one layer here, two for Sentry]
Sentry gets a second layer — `CliSpawnEnv` unsets its DSN in agent shells. The Slack credentials
cannot be unset the same way without breaking the `slack-workspace` MCP server that agent sessions
legitimately use. The environment allowlist is the layer that holds regardless, because it holds
even when the production token genuinely is present.
:::

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
