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
| Operational alerts | Slack Web API | `#eng-alerts` | Slack bot token **and** `ENG_ALERTS_SLACK_CHANNEL_ID` **and** `Rails.env` = `production` ([why prod-only](#operational-alerts-page-from-production-only)) |
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

## Operational alerts page from production only

GlitchTip is not the only thing that pages `#eng-alerts`. `AlertService.raise_alert` posts to the
channel **directly** — a separate path from the Sentry "new issue" hook, used by background
jobs (`SystemHealthMonitorJob`, `ScheduleTriggerJob`, the health checks) to page a formatted
operational alert. It has its own environment gate, and it is deliberately **narrower** than
Sentry's:

```ruby
# app/services/alert_service.rb
ALERTING_ENVIRONMENTS = %w[production].freeze
```

Production only — not `production` **and** `staging`. The Sentry path can safely allow both
because staging points at its own GlitchTip project (its own DSN). `AlertService` cannot: it
resolves a single channel ID, `ENG_ALERTS_SLACK_CHANNEL_ID`, which is the **production**
`#eng-alerts` channel. A non-production instance that inherits production's Slack bot token and
that channel ID — which staging does, running the same image with the same secrets — would page
the production channel for its own failures. That is not hypothetical: a per-minute background
poller failing on missing `gh` auth on **staging** paged `#eng-alerts` once a minute.
`AlertService` now refuses to dispatch outside `production`, at its sole Slack choke point, so
both the direct `raise_alert` path and the `AlertBatcher`-flushed path are covered.

The gate is **env-only**: it fires before the token/channel-ID check, so alerting is enabled
solely under `RAILS_ENV=production`, no matter how `ENG_ALERTS_SLACK_CHANNEL_ID` is set. It does
not replace the config-hygiene fix (don't hand a non-production instance the production channel
ID) — the two are independent defenses against paging the production channel, and this one is
the stronger because it holds even when the production channel ID is inherited, which is exactly
the situation that triggered the bug. A deployment that genuinely needs non-production alerting
must widen `ALERTING_ENVIRONMENTS` in code **and** point that environment at its own channel.

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
