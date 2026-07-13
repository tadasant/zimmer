---
name: zimmer-debug-staging
title: Debug Zimmer's Staging Environment
description: >
  Diagnose a broken or silent Zimmer staging deployment. Covers the four places
  staging's truth lives (the deploy run, the containers on the droplet, the OTLP
  logs in VictoriaLogs, the errors in GlitchTip), the `bin/rails obs:status` /
  `obs:smoke` diagnostics that exist because Zimmer's telemetry is a HARD NO-OP
  when misconfigured, LogsQL queries scoped to `deployment.environment=staging`,
  and the specific failure modes that make staging look healthy while doing
  nothing. Use when a staging deploy fails, when sessions hang, or when telemetry
  is missing.
user-invocable: true
---

# Debug Zimmer's Staging Environment

Staging fails in a small number of characteristic ways, and most of them present
as **silence rather than an error**. The single most common misdiagnosis is
treating "no data" as "no problem". Work the signals in order.

## Where staging's truth lives

| Signal | Where | Reaches it |
| --- | --- | --- |
| Did the deploy work? | `Deploy staging` workflow run | `gh run view` — always available to an agent |
| Is the app up? | `/up` on the droplet | tailnet or `https://staging.zimmer.tadasant.com/up` |
| What is it doing? | container stdout | `docker logs` on the droplet (needs SSH) |
| WARN/ERROR/FATAL history | VictoriaLogs (obs stack) | LogsQL, `deployment.environment:=staging` |
| Exceptions, grouped | GlitchTip (obs stack) | the `zimmer-staging` project |

Metrics and traces are **not shipped by Zimmer at all** — not in staging, not in
production. An empty metrics dashboard is the designed behavior, not a bug. Do
not go hunting for a broken metrics pipeline; there is no metrics pipeline.

## Start here: is the telemetry itself on?

Zimmer's telemetry initializers are hard no-ops when their env vars are missing
(`config/initializers/otel_logs_exporter.rb`, `config/initializers/sentry.rb`).
That is deliberate — it keeps dev/test/CI off the network — but it means a
**misconfigured deployment is indistinguishable from a healthy quiet one**. Ask
the app directly before you conclude anything from missing data:

```bash
# on the droplet
docker exec zimmer-web bin/rails obs:status
```

It prints, without leaking any secret, whether OTLP logs and GlitchTip are ON,
where they point, and the `deployment.environment` / `service.name` labels
everything is stamped with.

If it says OFF, the deploy is missing `STAGING_OTEL_LOGS_EXPORTER_ENDPOINT` /
`STAGING_OTEL_LOGS_EXPORTER_BEARER_TOKEN` / `STAGING_SENTRY_DSN_BACKEND`
(GitHub Actions secrets). The `Deploy staging` run also prints an
**observability preflight** block saying the same thing — check it before SSHing
anywhere.

## Prove the pipeline end to end

```bash
docker exec zimmer-web bin/rails obs:smoke
```

This emits a uniquely-tagged record through every live path and — crucially —
does a **synchronous ingest probe** that reports the collector's HTTP status
code. The background exporter can only ever warn to stderr, so without this a bad
token, a bad path, and an unreachable collector all look exactly like "no errors
happened". The probe turns that silence into an answer:

- `✅ accepted (HTTP 200)` — ingest works; if data still isn't in Grafana, the
  problem is your query, not the pipeline.
- `❌ rejected (HTTP 401)` — the bearer token does not match the obs Caddy gate.
- `❌ rejected (HTTP 404)` — the endpoint path is wrong (want `.../otel/v1/logs`,
  no trailing slash).
- `❌ rejected (error: ...)` — the collector is unreachable from the droplet.

It prints the marker and the exact LogsQL query to confirm the record landed.

## Reading staging's logs out of the obs stack

Staging and production both ship as `service.name="zimmer"`. **The label that
separates them is `deployment.environment`** — always scope your query with it,
or you will read production's errors and think they are staging's.

```logsql
# everything staging has said
{service.name="zimmer"} deployment.environment:=staging

# just the failures
{service.name="zimmer"} deployment.environment:=staging severity_text:in("ERROR","FATAL")

# a specific request/marker/job id
{service.name="zimmer"} deployment.environment:=staging "<marker or id>"
```

Terminal background-job failures are shipped as structured records carrying
`job_class`, `queue`, `job_id`, `exception_class`, and `exception_message` — so
you can go straight at them rather than grepping prose. Those are the records
that matter most, because **Zimmer's failures live in GoodJob jobs and the
session lifecycle, not in HTTP requests.**

Run a query either from the Grafana UI (`obs.tadasant.com`), or on the obs
droplet:

```bash
curl -s http://127.0.0.1:9428/select/logsql/query \
  --data-urlencode 'query={service.name="zimmer"} deployment.environment:=staging | limit 20'
```

An agent session holds **no obs credentials by default**. If you have not been
provisioned an MCP server or SSH access to the obs box, say so and ask — do not
claim you checked the logs.

## The failure modes that actually happen

These are ordered by how often they bite and how badly they mislead.

**Sessions sit in `waiting` forever; the app looks perfectly healthy.**
GoodJob runs in `:external` execution mode, so jobs only run if the dedicated
**worker** container is up. Web being healthy tells you nothing about the worker.
Check it, and check that it is not crash-looping (a worker restarting on a bad DB
password still appears in `docker ps`):

```bash
docker ps --format '{{.Names}}\t{{.Status}}'
docker inspect -f '{{.State.Running}} restarts={{.RestartCount}}' zimmer-worker
docker logs --tail 50 zimmer-worker
```

**Every session dies before the agent starts.** Almost always a secrets problem:
- `STAGING_RAILS_MASTER_KEY` unset → `config/credentials/staging.yml.enc` stays
  encrypted → `SecretsLoader` serves nothing → any MCP server with a `${VAR}`
  placeholder fails in `SecretsInterpolator`, and Slack/AlertService go quiet.
  The deploy **warns** rather than fails on this, so the run is green.
- `STAGING_API_KEYS` empty → the derived self-session key is blank → the injected
  self-session MCP server 401s against Zimmer itself.

**The deploy times out at 120s with no useful error.** The app entrypoint runs
`db:prepare` before Puma boots, so a database it cannot authenticate against
means the health gate never opens and Kamal just reports a timeout. The classic
cause: `zimmer_pgdata` is a **durable** volume and `POSTGRES_PASSWORD` only takes
effect at the *first* initdb — so rotating `STAGING_DB_PASSWORD` leaves the
already-initialized Postgres on the old password while the app sends the new one.
Read the app container's logs for the real error; the Kamal timeout is a symptom.

**`ActiveRecord::RecordInvalid` across many unrelated session tests or every
session creation.** That is the AIR catalog failing to resolve, not a model bug —
session creation validates `agent_root` and `catalog_skills` against the catalog.
See the "Known coupling" section of `CLAUDE.md`.

**Staging behaves like production (wrong MCP servers, missing prod keys).**
`RAILS_ENV` must be `staging`, not `production` — `SelfSessionInjector` keys the
injected self-session server off `Rails.env`, so a staging box running as
"production" injects the *production* server and dies on a missing
`ZIMMER_PROD_API_KEY`.

## Driving the deploy

Staging is a **persistent** Kamal-deployed droplet. It is not recreated per deploy
and it is **not** torn down nightly.

```bash
gh workflow run deploy-staging.yml -f ref="$(git rev-parse --abbrev-ref HEAD)"
gh run list --workflow=deploy-staging.yml --limit 3
gh run view <run-id> --log-failed
```

Read the run's own steps before going further: it prints the observability
preflight, health-checks `/up`, and explicitly asserts the **worker** is stably
running (Running + a stable `RestartCount`). A green run therefore already rules
out most of the failure modes above — which makes a *red* run the fastest
diagnosis you will get. Start there.

Rolling back is a redeploy of an earlier ref:

```bash
gh workflow run deploy-staging.yml -f ref=<known-good-sha>
```

## What an agent session cannot do

The session holds no DigitalOcean, Tailscale, GHCR, or obs credentials — the
runner does. Without an SSH MCP server for the staging droplet you cannot
`docker exec`, and without one for the obs droplet you cannot query VictoriaLogs
directly. Dispatch the workflow and read its logs; that path always works. When
you are missing access, **name the gap** instead of inferring a conclusion you
did not verify.

## Related

- `skills/zimmer-deploy-staging/SKILL.md` — dispatching and rolling back deploys.
- `https://docs.zimmer.tadasant.com/operate/observability/` — the full telemetry guide.
- `lib/tasks/obs.rake` — the diagnostics themselves.
