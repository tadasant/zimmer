---
title: Deploying
description: The topology, the Docker images, and the GitHub Actions workflows behind a Kamal deploy onto a persistent, Tailscale-only droplet.
sidebar:
  order: 1
---

Zimmer deploys with [Kamal](https://kamal-deploy.org/) onto a single DigitalOcean droplet, reachable
only over Tailscale. Terraform bootstraps the box (Docker, Tailscale, Caddy, the deploy key); Kamal
owns the app stack — a `web` role and a `worker` role, with durable named volumes. There is no
Kubernetes, no load balancer, and no HA. TLS is optional and off by default — setting `var.domain`
adds a tailnet-only HTTPS front door (see [below](#custom-domain-https-over-the-tailnet)).

These docs cover the **staging** deployment, which is the one this repo operates. A production
deployment is self-hosted and lives in your own private infrastructure — the `config/deploy.yml` /
`config/deploy.production.yml` and `.kamal/secrets.production` here are public-safe templates, but the
production environment (its DNS, its database, its secrets, and the workflow that drives it) is out of
scope for these docs.

## The topology

```mermaid
flowchart TB
    subgraph do["DigitalOcean"]
        subgraph droplet["Droplet: zimmer-staging (ubuntu-24-04, s-2vcpu-4gb, nyc3)"]
            subgraph kamal["Kamal (config/deploy.yml + deploy.staging.yml)"]
                WEB["web<br/>ghcr.io/tadasant/zimmer<br/>bin/thrust bin/rails server<br/>:80 via kamal-proxy"]
                WRK["worker<br/>bundle exec good_job start<br/>(no published port)"]
                RDS["redis:7 accessory<br/>(cache only)"]
                DBS["postgres:16 accessory<br/>(staging DB)"]
                VOL[("named volumes<br/>zimmer_data · claude_home · codex_home<br/>gh_config · claude_local")]
            end
            TS["tailscaled<br/>MagicDNS: zimmer-staging"]
        end
        FW["Firewall<br/>inbound: 41641/udp ONLY<br/>NO public TCP at all — not even SSH"]
    end

    GH["GHCR<br/>ghcr.io/tadasant/zimmer<br/>ghcr.io/tadasant/zimmer-base"]
    U["You (on the tailnet)"]

    GH -->|"kamal deploy"| WEB
    GH -->|"kamal deploy"| WRK
    WEB --> RDS
    WEB --> DBS
    WRK --> DBS
    WEB -.- VOL
    WRK -.- VOL
    U -->|"http://zimmer-staging (tailnet only)"| WEB
    FW -.-> droplet
```

By default there is no TLS. The web container serves plain HTTP on :80 behind kamal-proxy, and
`production.rb` sets `assume_ssl` and `force_ssl`, which works *only* because `assume_ssl` makes Rails
pretend the request arrived over TLS. The actual encryption is WireGuard, via Tailscale. A future
*public* ingress would break this subtly and badly.

Setting `var.domain` adds a real HTTPS front door (see below), still tailnet-only, which makes
`assume_ssl` true in reality.

## Custom-domain HTTPS over the tailnet

Plain HTTP with `assume_ssl` is a known sharp edge: because Rails computes `https://` origins that
never match the browser's `http://`, every CSRF-protected form POST 422s and every ActionCable upgrade
is rejected. Setting `var.domain` (e.g. `zimmer.tadasant.com`) fixes this class at the source by putting
a genuine cert on a custom name — while staying reachable only over the tailnet.

The trick is that TLS behind a tailnet is awkward: the firewall opens no public 80/443, so ACME
HTTP-01/TLS-ALPN-01 can't work — only DNS-01 can. On-box renewal would mean parking a Cloudflare token
on the droplet, so the work is split so the box holds no DNS credential:

```mermaid
flowchart LR
    subgraph droplet["Droplet (gated on var.domain)"]
        CADDY["caddy:2 on :443<br/>plugin-less, NO ACME<br/>serves /opt/zimmer/certs/{cert,key}.pem<br/>proxies to app"]
        APP2["app on :80<br/>(unchanged)"]
        CADDY --> APP2
    end
    subgraph ci["GitHub Actions — domain-cert-*.yml"]
        SH["scripts/domain-cert.sh<br/>ACME DNS-01 via Cloudflare<br/>weekly, no-op unless cert missing/<30d"]
    end
    CF[("Cloudflare DNS<br/>A record → tailnet IP (100.x)")]
    SH -->|"upsert A record"| CF
    SH -->|"push cert over tailscale ssh<br/>+ restart caddy"| CADDY
    U["Tailnet peer"] -->|"https://zimmer.tadasant.com"| CADDY
```

- **On the droplet** (`cloud-init.yaml.tftpl`, only when `var.domain` is set): a stock, plugin-less
  `caddy:2` container on `:443` that does no ACME. It serves the cert files at
  `/opt/zimmer/certs/{cert,key}.pem` and reverse-proxies to the app. The app keeps publishing `:80`, so
  the MagicDNS `http://…` path is unchanged and a Caddy misconfig can't take the box down. A self-signed
  placeholder is written at boot so Caddy can start before the real cert arrives.
- **In CI** (`scripts/domain-cert.sh`, run by `domain-cert-staging.yml`): discovers the droplet's tailnet
  IP, upserts a Cloudflare `domain → tailnet IP (100.x)` A record, issues/renews the Let's Encrypt cert
  via ACME DNS-01 through Cloudflare, pushes only the cert onto the box over `tailscale ssh`, and
  restarts Caddy (the Caddyfile sets `admin off`, so there's no live-reload endpoint — a restart re-reads
  the bind-mounted files). The Cloudflare token lives only in GitHub Actions.

The A record points at the **tailnet IP**, so tailnet peers resolve and reach it while everyone else
gets an unroutable address — same tailnet-only exposure as the MagicDNS name, now with a real cert.

:::note[Turning it on]
Mint a Cloudflare API token scoped to `Zone:DNS:Edit + Zone:Zone:Read` on the parent zone only, add it
as the `CLOUDFLARE_API_TOKEN` Actions secret (on staging → `tadasant/zimmer`; on production →
your private production repo), set `domain` in the environment's tfvars, deploy, then run the
`domain-cert-*` workflow once (`workflow_dispatch`) to issue the first cert. The weekly schedule renews
thereafter — a no-op unless the cert is missing, self-signed, wrong-name, or within 30 days of expiry, so
it issues only ~every 60 days. `domain=""` renders byte-identically to the plain-HTTP setup, so existing
deployments are unaffected.
:::

:::caution[Certs persist across image upgrades; a droplet replacement drops them]
Certs live in a host directory, so they persist across image auto-upgrades (container recreate). A
droplet **replacement** (a fresh `provision`) drops them; the next `domain-cert-*` run re-registers the A
record and re-issues.
:::

## Background jobs and durable state

`config/environments/production.rb` sets `good_job.execution_mode = :external`, which requires a
separate `bundle exec good_job start` process. Kamal runs exactly that as a dedicated **`worker`**
role (`config/deploy.staging.yml`), alongside the `web` role — so cron, pollers, orphan cleanup,
token refresh, and catalog refresh all run. The deploy workflow asserts the worker container is up
before it reports success.

On **staging** the worker role also runs under the `sysbox-runc` runtime as container-root, so agent
sessions get their own Docker daemon inside it and can use `.agent-containers/`. `Deploy staging`
carries a `nested_docker` dispatch input, **on by default**; unchecking it deploys the worker under
plain `runc` as uid 1000, which is the rollback. The workflow preflights the droplet for sysbox before
the cutover and verifies the running worker after it. Production is unaffected and still defaults off —
see [Nested Docker for agent sessions](/operate/nested-docker/).

Both roles mount the same durable named volumes, so state survives a deploy and a container recreate:

- `zimmer_data` → `/home/rails/.zimmer` — the clones (`~/.zimmer/clones`) and scratch.
- `claude_home` → `~/.claude` — Claude Code's transcripts, plus the shared credentials file
  the entire [account-rotation system](/auth/harness/) hinges on.
- `codex_home` → `~/.codex` (`CODEX_HOME`) — Codex's rollout transcripts, `auth.json`, and
  thread store.
- `gh_config` → `~/.config/gh` — the GitHub CLI's stored auth (from an interactive `gh auth login`).
  On staging the durable credential is instead `GH_TOKEN`, minted for the non-primary `tadasant-test`
  account and resolved from the Parameter Store into the process environment on every boot and poll
  tick — so it survives a rebuild without anyone logging in again. See
  [Staging `gh` auth](/operate/provisioning/#staging-gh-auth-the-tadasant-test-account).
- `claude_local` → `~/.local` — where `bin/docker-entrypoint`'s background `claude update` writes.
- The `worker` role additionally mounts `/var/run/docker.sock`, which `DockerCleanupJob` needs.

## Ops actions ship with the deploy

**Nothing Zimmer needs done in production requires a shell on the box.** A feature is not finished
when the code is deployed and an operator still has to SSH in and run something; that step is part
of the feature, and it has to ship with it.

There is no fallback here to fall back to. Agent sessions run *on* the production droplet, the
operator key is deliberately not authorized as root there, and the SSH agent root is excluded from
the catalog baked into the image — see [SSH access](/operate/ssh-access/). So an ops step that needs
a shell is a step no agent can take and a human has to be interrupted for.

Three delivery mechanisms, in order of preference:

1. **A deploy.** A migration, or — for a **one-time** step that needs application code — a
   post-deploy task in `db/post_deploy/`. That is the default answer, and it has its own section
   below. `TokenUsageBackfillJob` predates it and is the bespoke worked example of the same shape:
   it starts a sweep on the first tick after the deploy, records its progress in a table, and costs
   an indexed lookup per tick forever after. See
   [Token spend](/operate/costs/#why-a-job-and-not-a-rake-task).
2. **A scheduled idempotent job.** Anything that has to keep converging — refreshes, reconciliation
   sweeps, cleanups. Idempotence is what makes an unattended cron safe to leave running. A
   *recurring* need is a cron entry, not a post-deploy task.
3. **The app's own surfaces** — a button in the web UI, a REST endpoint, an MCP action. This is
   where operator-*triggered* actions belong. The Costs page's re-scan button,
   `POST /api/v1/costs/backfill` and `action_health`'s `backfill_token_usage` are the same request
   through the three surfaces Zimmer already exposes.

Two obligations come with it. An action that runs unattended must be **safe to run repeatedly** —
for the backfill that is the unique index on `request_id`, which makes re-ingestion a no-op. And it
must give an **observable answer** to "did it run, and what does it cover", or an operator has
traded a shell for a guess. A rake task is still fine as a developer convenience; it is not the
delivery mechanism.

## Dropping a column takes two deploys

**A migration that drops a column and the code change that stops using it cannot ship in the same
deploy.** kamal-proxy health-gates the cutover, so the old and new containers run *together* until
the new one answers `/up`. That is the same window the
[connection budget](#the-database-connection-budget) doubles for, and `bin/docker-entrypoint` has
already run `db:prepare` by the time it opens. So for its whole length the **old** processes are
serving against the **new** schema.

That is not a survivable combination. The old process booted with the column present, so its model
still defines the attribute; its `SELECT`s now come back without it, and reading the attribute raises
`ActiveModel::MissingAttributeError`.

```mermaid
sequenceDiagram
    participant Old as old container (booted pre-drop)
    participant PG as Postgres
    participant New as new container
    New->>PG: db:prepare — ALTER TABLE … DROP COLUMN
    New-->>New: boot, wait for /up to answer
    loop until /up is healthy
        Old->>PG: SELECT * FROM sessions
        PG-->>Old: row without the column
        Old--xOld: ActiveModel::MissingAttributeError
    end
    Note over Old,New: kamal-proxy cuts over, old container stops
```

Dropping `sessions.blocked_by_session_id` in one phase did exactly this: 12 `ERROR` records in 12.8
seconds across `GitHubPullRequestPollerJob`, `GithubCommentPollerJob` and
`GitHubMergeConflictPollerJob`, which crossed the backend log-error alert threshold and paged
`#alerts`. The polls it interrupted really did abort — they recovered on the next tick, but a
PR-merge notification arrived a poll interval late. See
[zimmer#482](https://github.com/tadasant/zimmer/issues/482).

### The recipe

**Deploy 1 — stop reading the column.** Add it to the owning model's `ignored_columns` and delete
every code reference: the attribute, the association, the scope, the strong parameter, the view, the
fixture column. No migration.

```ruby
class Session < ApplicationRecord
  # Phase 1 of dropping this column. Active Record stops loading it, so nothing
  # in either image reads it. Phase 2 drops the column and this line.
  self.ignored_columns += %w[blocked_by_session_id]
end
```

`ignored_columns` makes Active Record behave as if the column were already gone — no attribute
method, and it is left out of `SELECT` lists. That is what makes the *next* deploy safe: by the time
the column disappears, the old containers were never reading it either.

**Deploy 2 — drop it.** A separate pull request, merged after deploy 1 is actually live. It drops the
column *and* removes the `ignored_columns` line, and it annotates the migration with the number of
the pull request that shipped phase 1:

```ruby
# two-phase-drop: phase 2 of #474
class DropBlockedBySessionFromSessions < ActiveRecord::Migration[8.0]
  def up
    remove_reference :sessions, :blocked_by_session, index: true
  end
end
```

Leaving the `ignored_columns` entry behind is not harmless: it silently hides a column of that name
if one is ever added back.

### The guard

`TwoPhaseColumnDropGuard` (`test/support/two_phase_column_drop_guard.rb`) fails CI when a migration
removes a column in the forward direction without that annotation. It catches `remove_column`,
`remove_columns`, `remove_reference`, `remove_belongs_to`, `t.remove` inside a `change_table` block,
and `DROP COLUMN` in raw SQL, heredocs included.

It parses the migration rather than grepping it, because the direction is a syntactic fact. A
`remove_column` inside `def down`, `dir.down { }` or `revert { }` is the undo of an `add_column`, and
a regex cannot tell it from the forward body two lines above: 13 of this repo's migrations contain a
`remove_column` and only 6 of them actually drop one. The pruning is by method *name* though, so a
removal factored out of `down` into a helper is still reported. Inline it into `down` rather than
annotating a phase 1 that never happened.

The annotation is the escape hatch, and it has to name something a reviewer can go and read: a PR or
issue number (`#474`), a commit sha, or the phase-1 migration's version. It is read off the parsed
comments, so the same text inside a SQL heredoc is not evidence, and `# two-phase-drop: phase 2 of the
earlier PR` does not pass.

Two jobs run it. `bin/rails test` picks up `test/migrations/two_phase_column_drop_test.rb` in
`test-unit`, which is also where the `ignored_columns` half is checked — an entry naming a column that
no longer exists is a phase-2 cleanup someone forgot. The guard itself needs neither Rails nor a
database, so `lint` runs it directly and answers in seconds. That is also how you run it by hand:

```bash
bundle exec ruby -r./test/support/two_phase_column_drop_guard -e 'puts TwoPhaseColumnDropGuard.report'
```

Seven migrations that dropped columns before the guard existed are named in its `GRANDFATHERED`
list. That list is closed, and a `GRANDFATHER_CUTOFF` assertion keeps it that way: a new drop gets
the two deploys, not an eighth entry. The newest entry is the case for the guard — `#680` dropped
`app_settings.provenance_via_mcp_enabled` in a single phase on 2026-08-28, twelve days after the
incident, because nothing was checking.

**What it does not cover.** `rename_column`, `rename_table` and `drop_table` strand an old container
in exactly the same way, and the guard says nothing about them. Their phase 1 is not an
`ignored_columns` entry but an add-and-backfill, which is a longer recipe this repo has not written
down — see [zimmer#722](https://github.com/tadasant/zimmer/issues/722). Treat them with the same
suspicion by hand.

## One-time post-deploy tasks

**If the step runs once and then never again, write a post-deploy task.** This is Zimmer's
equivalent of the `after_party` gem, and it is the mechanism the rule above points at: you should
not have to invent the apparatus each time, and you should not have to reach for a shell.

A task is one file in `db/post_deploy/`, named like a migration:

```sh
bin/rails generate post_deploy_task prune_orphaned_widgets
# => db/post_deploy/20260830100500_prune_orphaned_widgets.rb
```

```ruby
class PruneOrphanedWidgets < PostDeployTask
  def up
    Widget.where(owner_id: nil).delete_all
  end
end
```

That is the whole authoring surface. Nothing registers it, nothing else has to be edited, and
`PostDeployTaskJob` — a two-minute cron entry on the `default` queue — picks it up within a couple
of minutes of the deploy.

### What it guarantees, and what it does not

| | |
| --- | --- |
| **Runs once** | `succeeded` is terminal in `post_deploy_task_runs`, keyed on the file's timestamp. Renaming the class does not re-run it. |
| **Never runs twice at once** | The ledger row is claimed with a conditional `UPDATE`, so two containers coming up together produce one winner and one no-op. |
| **Never wedges the deploy** | Nothing in the deploy waits on it. It is a cron job in the worker, not an entrypoint step or a Kamal hook, precisely so that a task which is slow or raises cannot hold the cutover. |
| **Never wedges the next task** | Each task is worked inside its own rescue. A failure is recorded and the task behind it still runs. |
| **Does *not* guarantee idempotency** | The mechanism cannot know whether a task that died halfway half-applied. Write `up` so that running it twice is harmless — an upsert, a `delete_all` of a shrinking set, a `WHERE … IS NULL` guard — exactly as you would a data migration. |

### Long-running work

**This is for the hour-long case as well as the ten-millisecond one.** Each task is handed a
90-second budget (`PostDeployTaskJob::SLICE_BUDGET`). A task that cannot finish inside it returns
`PostDeployTask::CONTINUE` and is resumed on the next tick from the `cursor` it saved. `sweep` is
that loop packaged — it walks a relation in key order, checkpoints after each batch, and yields the
worker when the budget runs out:

```ruby
class PruneOrphanedWidgets < PostDeployTask
  def up
    sweep(Widget.where(owner_id: nil), batch_size: 500) do |batch|
      Widget.where(id: batch.map(&:id)).delete_all
      checkpoint!(deleted: stats.fetch("deleted", 0) + batch.size)
    end
  end
end
```

The token-usage backfill's hour of wall clock is exactly this shape; it predates the mechanism and
keeps its own apparatus, but a new task of that size does not need one.

Two things to know about the budget. It is checked **between** batches, not inside one, so a single
batch query runs to completion however long it takes — pass `sweep` a relation the database can
serve from an index, or the last query of the sweep (the one that proves nothing is left) is a full
scan. And version order is honoured, but only a *failure* is not a barrier: a task that keeps
yielding is still the earliest due task on the next tick, so one written to run for hours delays the
tasks behind it by hours.

### When it fails

A task that raises is recorded on its row and retried with backoff — 1m, 5m, 15m, 30m, 1h — and
then **stops**, so a durably broken task is not burning a worker slice every two minutes. At that
point it reads as `blocked`, and the health page turns critical. "Raises" is wide on purpose: it
covers `ScriptError` as well as `StandardError`, because a task file that will not load
(`SyntaxError`, `LoadError`) and one generated but not yet filled in (`NotImplementedError`) are
both the former. A worker killed mid-task (a deploy, an OOM) leaves its claim behind; the lease
expires after 20 minutes and the abandoned claim is converted into an ordinary failure, so it
retries down the same path.

### Seeing it without a shell

One object, `PostDeployTaskRun.summary`, rendered four ways so they cannot disagree:

| Surface | Where |
| --- | --- |
| **Health page panel** | `/health` → **Post-Deploy Tasks** — status per task, counters, the error text, and a **Re-arm and run now** button |
| **REST** | `GET /api/v1/health` → `health_report.post_deploy_task_health`; `POST /api/v1/health/run_post_deploy_tasks` to re-arm |
| **MCP** | `get_system_health` reports it; `action_health` with `action: "run_post_deploy_tasks"` re-arms |
| **Supervisor** | `/supervisor/post_deploy_task_runs` — read-only, row-level: cursor, stats, lease holder, backtrace |

Re-arming is the answer to "the task failed for a reason I have now fixed". It clears the failure
count and queues a pass; it will not re-open a task that already succeeded, because re-running one
of those is what writing a new task file is for.

## The database connection budget

Managed Postgres hands out a hard, small number of connection slots, and an ActiveRecord pool is a
*promise* to use up to that many. The promise is lazy — an overcommitted app looks perfectly healthy
until real traffic calls it in, and then Postgres refuses with `FATAL: remaining connection slots are
reserved for roles with the SUPERUSER attribute`, which Rails serves as a 500. Nothing in a Rails boot
compares the promise against the server, so Zimmer does it in two places instead.

**`config/connection_budget.rb`** is the single source of truth. Two roles times two databases is four
ActiveRecord pools, and they have four different right answers — a flat number is correct for at most
one of them:

| Pool | Sized for | Why |
| --- | --- | --- |
| `web` → `primary` | Puma's threads (`RAILS_MAX_THREADS`, 3) | A request holds a connection for the request. |
| `worker` → `primary` | **every** GoodJob scheduler thread | An executing job holds its connection for the *whole job*: GoodJob's advisory lock is session-scoped, so it leases the connection stickily. Zimmer's agent jobs run for hours. |
| both → `cable` | concurrent in-flight broadcasts | `solid_cable` takes no advisory lock, so Rails leases per `INSERT` and hands the connection straight back. A broadcast from an hours-long agent job holds one for the write, not for the job. |

The same file derives GoodJob's queue string (`config/environments/*.rb` read it), so raising
`GOOD_JOB_AGENTS_THREADS` moves the pool that has to serve those threads along with it. They cannot
drift apart.

**A deploy is the peak, not the steady state.** kamal-proxy health-gates the cutover by running the
old and new containers *together* until the new one answers `/up` — so for that window every
connection exists twice. The budget multiplies by two for exactly this reason; a configuration that
only fits at steady state turns each deploy into a coin flip.

`ConnectionBudget.required_backends` is the resulting number. `infra/terraform/main.tf` refuses to
plan against a managed cluster whose **plan** cannot serve it (DigitalOcean allots 25 connections per
GiB of RAM, minus 3 reserved, and the ceiling is not otherwise tunable), and
`test/config/connection_budget_test.rb` asserts the Terraform default still equals the Ruby
derivation. To see the whole picture against a live server:

```bash
bin/rails db:connection_budget
```

It prints both halves — what the app commits to, what the server can serve — and exits non-zero when
the first exceeds the second.

## The Docker images

**`Dockerfile.base` → `ghcr.io/tadasant/zimmer-base`** — the heavy one, rebuilt by
`release-image.yml` before the app image when `Dockerfile.base` changes, and also rebuilt monthly
(cron `0 6 1 * *`) or on demand. From `ruby:3.4.6-slim`, it bakes in:

- Gems, pre-bundled to `/usr/local/bundle` with bootsnap precompiled
- Node.js 22, the Docker CLI, `gh`, the 1Password CLI, `uv`/`uvx`
- Playwright + Chromium and Puppeteer + Chrome (for browser-automation MCP servers)
- The npm and Python MCP packages listed in `mcp.json` (`bin/preinstall-mcp-packages`)
- The AIR CLI `@pulsemcp/air-cli@0.13.0` + adapters → `/opt/air-cli`
- The Codex CLI `@openai/codex@0.146.0` and Claude Code (via `claude.ai/install.sh`)

**`Dockerfile` → `ghcr.io/tadasant/zimmer`** — the app image. Copies the app onto the base, re-runs
`bundle install` (which catches Gemfile drift against the base), precompiles assets, drops to
`USER 1000:1000`, and runs `bin/thrust bin/rails server`.

### The docs never ship in the image

This documentation site is single-source. The only copy that exists is `docs/` in the repository,
built by Cloudflare Pages and served at [docs.zimmer.tadasant.com](https://docs.zimmer.tadasant.com).
A second copy bundled into `ghcr.io/tadasant/zimmer` would be one nobody deploys, nobody reads, and
nobody keeps true — the app never serves it, so nothing would ever surface the drift.

Nothing in `Dockerfile` is selective about this: the build stage does a blanket `COPY . .` and the
final stage a `COPY --from=build /rails /rails`. The docs stay out because of a single `/docs` line
in `.dockerignore`. That is a fragile place for an invariant to live — reorganize the file, or move
the docs to another path, and the second copy comes back silently.

So two checks assert the outcome instead of trusting that line. Both run
`scripts/assert-docs-excluded.sh`, which fails if it finds a top-level `docs/` directory, or —
anywhere under the tree it is pointed at — an `astro.config.*` or an `@astrojs/starlight` dependency
in a package manifest (skipping `node_modules`, where a vendored Starlight belongs to somebody else's
dependency tree). A scan it could not run exits non-zero too: a guardrail that reports OK when its own
machinery is broken looks exactly like a passing check, which is worse than no check at all.

The scan also skips the top-level `tmp/` and `log/` — anchored to the root it was pointed at, not
matched by name, so a `docs/tmp/` further down is still walked. Those are the two directories a
running test suite scribbles scratch directories into, and a directory that vanishes between
`find`'s readdir and its stat makes `find` exit non-zero, which reddens the guardrail over a race
with whatever else is running rather than over the invariant. What the prune costs differs by
caller: `.dockerignore` excludes `/tmp/*` and `/log/*` (keeping only the `.keep` placeholders), so
for the build-context audit the prune skips ground that is provably empty, while against the built
image `/rails/tmp` holds whatever the build's own `RUN` steps left there — see
[the docs guardrail does not look in the image's `tmp/`](/limitations/#the-docs-guardrail-does-not-look-in-the-images-tmp).
For churn anywhere else, the two reasons a scan can fail are told apart by retrying it: a tree that
changed underneath the walk clears on the next attempt, while a `find` that genuinely cannot run
fails every attempt and still exits 2, saying how many it took.

| Where | Against what | When it fires |
| --- | --- | --- |
| `Dockerfile`, final stage | `/rails` — the published image's own filesystem | during the release build, so an image carrying the docs is never pushed |
| `image_excludes_docs` in `ci.yml` | the real build context, via `Dockerfile.docs-audit` (busybox + `COPY . /ctx`) | on every PR, before merge |

The second is a proxy for the first, and a tight one: `COPY` can only read from the build context, so
docs absent from the context cannot reach the image. It exists because PR CI does not build the app
image — pulling the multi-GB `zimmer-base` on a shared runner for a one-line assertion is not worth
it — and catching the regression after merge is worse than catching it for a few megabytes of
busybox. The gap between them (an `ADD` from a URL, a `COPY --from` an outside image, a `RUN` that
fetches the docs over the network) is what the `Dockerfile`-side assertion is there to close.

Because the check is content-based rather than path-based, moving `docs/` to a new directory without
moving the `.dockerignore` line with it still fails. What it does **not** do is read `.dockerignore`
and look for a line — a check like that passes happily while a `COPY` reintroduces the docs by
another route.

:::caution[It matches the docs by their source, not their output]
`docs/dist/` — the *rendered* HTML Astro emits — carries no `astro.config.*` and no package manifest.
A copy of the built site at some path other than `docs/` would therefore slip past all three checks.
`docs/dist/` is gitignored and doubly excluded today, so this is a gap in what the guardrail proves,
not a hole anything currently walks through.
:::

Separately, `release-image.yml` carries `paths-ignore: ["**/*.md", "docs/**"]`, so a docs-only push to
`main` does not build an image at all.

### Static files in `public/` are not digest stamped

`config.public_file_server.headers` in `production.rb` and `staging.rb` sets the cache header for
everything under `public/` — `manifest.json`, `service-worker.js`, `404.html`, and the icons. It does
**not** cover the compiled asset bundle: Propshaft serves that under `/assets` with its own
far-future headers, and those filenames carry a content digest.

Nothing in `public/` does. Each of those files lives at a URL that never changes, so a far-future
`max-age` there pins whatever a browser fetched first — replace an icon or edit the manifest and the
change reaches nobody who already loaded the old one. The header is therefore one hour, not one year.

An hour still leaves already-cached copies stale for an hour, and copies fetched under an older,
longer header stale for as long as that header said. When you replace a file at a URL that has
already shipped, bump its `?v=` query in whatever references it — that is what the `?v=2` on
`/manifest.json` and the two reused icon `src`s is for.

:::caution[The AIR CLI version is pinned in two places]
`Dockerfile.base` bakes `@pulsemcp/air-cli@0.13.0`, and `AirPrepareService::AIR_CLI_VERSION` must
match. Nothing enforces that they agree. If they drift, the pre-baked CLI is ignored and every
worker `npm install`s a different version at runtime.
:::

:::caution[`bin/docker-entrypoint` backgrounds `claude update`]
It also backgrounds the Playwright browser install, so Rails can answer the health check instead of
waiting behind a 30s+ network operation. The block writes a readiness marker when it finishes and
exports `ZIMMER_BOOT_TASKS_MARKER`; the spawn path
[waits on that marker](/sessions/spawning/#the-boot-tasks-readiness-gate) so a session started
seconds after a deploy does not silently run the old CLI. The wait is bounded by
`ZIMMER_BOOT_TASKS_TIMEOUT_SECONDS` (default 120) — a hung update degrades loudly rather than
wedging the worker.
:::

## The workflows

Every workflow but one runs on **`runs-on: self-hosted`** — a shared self-hosted
runner pool that this repo registers against, so its CI stays off the GitHub-hosted
Actions minute quota. If you fork Zimmer you would point these at your own runners
(or switch the jobs back to `ubuntu-latest`).
See [Running on the shared self-hosted runner](#running-on-the-shared-self-hosted-runner)
for what that requires of a Rails job.

The exception is `alert-ci-failure.yml`, which runs on `ubuntu-latest` on purpose: an
alert that needs a healthy self-hosted runner in order to tell you the self-hosted
runners are unhealthy is no alert at all. That buys less than it sounds like — it covers
a *degraded* pool, where jobs run and fail, but not a pool that is flat **offline**, in
which case runs simply queue (see [CI failure alerts](#ci-failure-alerts)).

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `ci.yml` | PR + push to main | rubocop · brakeman · `Gemfile.lock` freshness · `test-unit` (Postgres + Redis services) · `test-system` (Chrome browser suite) · GHCR-retention logic · docs site build · `image_excludes_docs` (see [The docs never ship in the image](#the-docs-never-ship-in-the-image)) · `all-checks-pass` (the aggregate gate). Every job except the gate is guarded to run only on `push` and on same-repo PRs, so a fork PR never checks out or executes fork code on the self-hosted runners. The gate itself is unguarded — it must never skip, or it would block branch protection — but it has no checkout step and only reads the other jobs' results. |
| `pr-auto-close.yml` | outside PR opened/reopened | Zimmer does not accept pull requests: this politely comments and closes PRs from forks and non-members (owner/member/collaborator PRs are left open), pointing them at the issue tracker. Runs on GitHub-hosted `ubuntu-latest`, never the self-hosted pool. |
| `alert-ci-failure.yml` | any other workflow completing + manual | posts to #alerts in Slack when a workflow **fails on `main`**. See [CI failure alerts](#ci-failure-alerts) |
| `release-image.yml` | push to main (ignores `**/*.md`, `docs/**`) | rebuilds `zimmer-base:latest` first when `Dockerfile.base` changed, then builds and pushes `zimmer:{version, latest, sha-…}`, [retrying up to three times](#the-release-build-retries-ghcr-on-the-way-in-and-on-the-way-out) if GHCR throttles the pull or the push |
| `build-base-image.yml` | manual + monthly cron | rebuilds the base image outside the normal release path |
| `deploy-staging.yml` | manual only | see below |
| `teardown-staging.yml` | manual only | `terraform destroy` of the staging droplet. No longer runs nightly — staging is persistent now (see below). Run it when you deliberately want to stop paying for the box; a powered-off droplet still bills, so destroying is the only way to stop the charge. |
| `ghcr-retention.yml` | weekly cron | prunes GHCR to ≤50 versions |
| `open-transcripts-drift.yml` | daily cron + manual + PR/push touching the vendored files | re-fetches the upstream OpenTranscripts files pinned in `vendor/open_transcripts/UPSTREAM.json` and fails when the bytes have moved (see [Transcripts](/sessions/transcripts/)). Deliberately not on every PR — an upstream commit must not turn unrelated pull requests red. A scheduled failure reaches Slack through `alert-ci-failure.yml`. |
| `domain-cert-staging.yml` | weekly cron + manual | issues/renews the Let's Encrypt cert for `var.domain` via ACME DNS-01 and pushes it to the droplet (see [Custom-domain HTTPS](#custom-domain-https-over-the-tailnet)) |

### CI failure alerts

When **any** workflow in this repo fails on `main`, `alert-ci-failure.yml` posts the
repo, the workflow, the commit subject, the author and a link to the run into **#alerts**
in the Tadasant Slack workspace. Any of your other repos can carry the identical
listener under the identical secret names; if so, keep them symmetric and change them
together.

It listens with `workflows: ["*"]`, which matches every workflow in the repo — so a
workflow added later is covered the day it lands, with nobody having to remember to wire
it up.

It needs two repo secrets — `SLACK_BOT_TOKEN` and `SLACK_ALERTS_CHANNEL_ID`
([Provisioning and secrets](/operate/provisioning/#slack-ci-failure-alerts)). Without
them it logs a warning and exits 0: a missing alert secret must not turn into a second
red X on `main`. With them, a Slack rejection *does* fail the job, because a rejected
alert is a silently broken alert and this is the only place it can surface.

Three details worth knowing before you touch it:

- It fires on an **allowlist** of conclusions — `failure`, `startup_failure`,
  `timed_out` — never on "not success". `ci.yml` sets `cancel-in-progress`, so two
  pushes to `main` in quick succession cancel the first run, and a *cancelled* run must
  not page anyone. The corollary is that a run which never starts is never alerted on:
  if the self-hosted pool is offline, main-branch runs **queue**, and GitHub cancels
  them after ~24h as `cancelled`, which is indistinguishable from a deliberate cancel
  ([Limitations](/limitations/#a-queued-run-that-never-starts-is-never-alerted-on)).
- `["*"]` matches the alert **itself**, and `workflow_run` chains several levels deep, so
  the job excludes itself by comparing against the literal name `'CI failure alert'`.
  **Rename the workflow and you must update that literal**, or it starts alerting on its
  own runs ([Limitations](/limitations/#the-ci-failure-alert-cant-be-exercised-from-a-pr)).
- `workflow_run` only ever triggers from the copy of the file on the **default branch**,
  so editing it on a PR branch changes nothing until it merges. To prove Slack delivery
  works, run the workflow's `workflow_dispatch` trigger by hand — it posts a smoke-test
  message instead of an alert.

### Running on the shared self-hosted runner

The runner box is shared across several repos, so a job cannot assume it has the
machine to itself. Five things follow. The first four are what every Rails job in
`ci.yml` already does; the fifth is what every image-building job does:

- **`ruby/setup-ruby` gets `self-hosted: true` and `bundler-cache: false`.**
  `self-hosted: true` selects the Ruby already staged in
  each runner's own `$RUNNER_TOOL_CACHE` instead of downloading one — the action's
  download path extracts into a hardcoded `/opt/hostedtoolcache` the runner user can't
  write, so on this box the flag is mandatory, not optional. `bundler-cache: false`
  turns off the action's automatic `bundle install`, because we do it ourselves into
  an isolated path (below).

  :::caution[Runner toolcache seeding]
  The `tadasant-zimmer-ci-*` runners were registered with a Node toolcache but **no
  Ruby one**, so their Ruby 3.4.6 toolcache had to be seeded out of band (`ruby-build
  3.4.6` into `/opt/hostedtoolcache-runner-N/Ruby/3.4.6/x64`). That manual seed is not
  yet captured in IaC and will be lost if the runners are rebuilt — codifying it is
  part of the DigitalOcean migration ([zimmer#118](https://github.com/tadasant/zimmer/issues/118)).
  :::
- **Gems install into a per-runner path.** `bundle config set --local path
  /home/runner/.bundles/zimmer-runner-${RUNNER_NUM}` (with `RUNNER_NUM` derived from
  `$RUNNER_NAME`) keeps two concurrent jobs on the same box from fighting over one
  `vendor/bundle`.
- **Service containers publish dynamic ports.** Postgres and Redis declare
  `- 5432/tcp` / `- 6379/tcp` (not `5432:5432`), and a step resolves the assigned
  host port via `${{ job.services.postgres.ports[5432] }}` into `DATABASE_PORT` /
  `REDIS_URL`. Fixed host ports would collide when two jobs land on the same runner.
- **The heavy suites are the `test-unit` and `test-system` job keys and pin
  `PARALLEL_WORKERS`.** The runner's file-based semaphore recognizes the job **keys**
  `test-unit` and `test-system` and caps how many heavy test jobs run at once; a bare
  `test` key would go ungated. Pinning `PARALLEL_WORKERS` stops a single job from
  fanning out to `:number_of_processors` (32 on this box) and starving co-tenants —
  `test-system` pins it to 1 because its persistent per-worker Chrome profile does not
  tolerate concurrent browser instances. `test-system` runs the Chrome-driven system
  suite (`bin/rails test:system`); the companion system-test semaphore gates it.
- **Image builds get a private `DOCKER_CONFIG` and name their builder explicitly.**
  Every job that runs `docker/build-push-action` exports a fresh
  `DOCKER_CONFIG` under `$RUNNER_TEMP` before its first `docker/*` step, and passes
  `builder: ${{ steps.buildx.outputs.name }}` to each build. See
  [Why image builds isolate their Docker config](#why-image-builds-isolate-their-docker-config).
  `test/config/image_build_workflows_test.rb` fails the build if a workflow adds a
  `build-push-action` step without both.

### Why image builds isolate their Docker config

All ~14 runner workers on the box execute as the same OS user with no per-job
`DOCKER_CONFIG`, so they share one `~/.docker` — one `config.json` and one
`buildx/current`. Both are mutable state that any job can overwrite at any moment.

`docker/setup-buildx-action` creates a builder with `docker buildx create --use`, and
`--use` writes the *shared* current-builder file. `docker/build-push-action` reads that
same file to decide which builder to build on — it does not remember which builder its
own job created. So a build step that starts after a co-tenant job's `--use` lands
silently builds on **that job's** buildkit container. When the co-tenant finishes,
`setup-buildx-action`'s post step runs `docker buildx rm`, which stops the container
and deletes its instance file. The victim's in-flight build sees:

```
ERROR: failed to build: failed to receive status: rpc error: code = Unavailable
desc = closing transport due to: ... received prior goaway: ... debug data: "graceful_stop"
ERROR: no builder "builder-<some-other-jobs-uuid>" found
```

The tell is that the UUID in the error is **not** the one the job's own "Set up Buildx"
step printed. The shared `config.json` has the matching hazard: `docker/login-action`'s
post step runs `docker logout ghcr.io`, which strips GHCR credentials out from under a
concurrent job's push.

A per-job `DOCKER_CONFIG` under `$RUNNER_TEMP` gives each job its own current-builder
file and its own credential store, which removes both races; the explicit `builder:`
input makes the binding unambiguous even if that state is ever shared again.

It is exported from a step rather than declared in job-level `env:`:

```yaml
- name: Isolate Docker client state for this job
  run: |
    cfg="${RUNNER_TEMP}/docker-config"
    rm -rf "$cfg"
    mkdir -p "$cfg"
    echo "DOCKER_CONFIG=$cfg" >> "$GITHUB_ENV"
```

The `runner` context is [not available in `jobs.<job_id>.env`](https://docs.github.com/en/actions/reference/workflows-and-actions/contexts#context-availability),
so `DOCKER_CONFIG: ${{ runner.temp }}/docker-config` there expands to the empty string
and silently points every build at `/docker-config`. A step's `run:` always has
`$RUNNER_TEMP`. `image_build_workflows_test.rb` asserts both the step form and that it
precedes every `docker/*` step.

:::note[The host could also fix this]
Setting `DOCKER_CONFIG` per worker in the runner service definitions (in the private
`tadasant-internal` repo's `ci-runner/`) would fix it for every repo on the box at once,
instead of once per repo. The in-repo change here stands on its own and does not
conflict with that.
:::

### The release build retries GHCR, on the way in and on the way out

`release-image.yml` talks to GHCR at both ends of one step. It builds `FROM
ghcr.io/tadasant/zimmer-base:latest`, so buildkit **pulls** that image's layers for the length of the
build, and it **pushes** the finished image at the end. When GitHub applies a secondary rate limit to
the account — which it does across the whole account, not per workflow — either end starts failing.

Three shapes observed so far, one cause:

```
#10 ERROR: failed to copy: httpReadSeeker: failed open: unexpected status from GET request to
https://ghcr.io/v2/tadasant/zimmer-base/blobs/sha256:…: 403 Forbidden
denied: permission_denied: … "You have exceeded a secondary rate limit."
```

```
ERROR: failed to solve: failed to copy: httpReadSeeker: failed open:
content at https://ghcr.io/v2/tadasant/zimmer-base/manifests/sha256:… not found: not found
```

```
#19 ERROR: failed to push ghcr.io/tadasant/zimmer:sha-…: unexpected status from HEAD request to
https://ghcr.io/v2/tadasant/zimmer/blobs/sha256:…: 403 Forbidden
```

The middle one is a lie worth recognizing: it reads as a missing manifest, but under throttling GHCR
returns 404 for content it is simply refusing to serve — the same digest pulls fine minutes later. The
third is the push side, and it is the reason the retry wraps the whole step rather than the pull: by
the time it fires, the image is built and the only thing left to fail is the upload.

None of the three means the images are damaged or the credentials are wrong. On 2026-08-06 the same
throttle took out this workflow and the production deploy in a different repo inside the same two
minutes, and `docker login` had succeeded seconds before the deploy's pull was refused.

`Check for base image` is not what failed in any of them. It resolves the manifest through
`docker buildx imagetools inspect` for real, and in the red runs it passed *correctly* — the image
genuinely existed. What fails is the layer traffic after it, once the build is already underway.

#### Three attempts, escalating backoff, and a probe that says which side broke

The app build runs up to three times: `Build and push`, `Build and push (retry)` after 90 seconds,
`Build and push (final attempt)` after a further 240 seconds. Every attempt but the last carries
`continue-on-error`, and each is gated on *all* the attempts before it having failed. Only the last
one can fail the job.

The backoff escalates rather than repeating because the throttle is account-wide and has outlasted a
single 90-second wait. `continue-on-error` on the earlier attempts is load-bearing twice over: it
swallows their failure, and it keeps the job green so that the implicit `success()` on the later
attempts' `if` lets them run at all. The two backoff steps between them carry it for the second reason
only — a probe that exits non-zero would otherwise fail the job, and every later step, including the
remaining attempts and the production notify, would skip on its own implicit `success()`. The retry
chain would sit there intact and unreachable.

The retry is **blind** — it does not inspect the error. That is deliberate. The same throttle has
already worn three different HTTP shapes, and gating on an error signature would trade a rare wasted
rebuild for a missed retry the next time GitHub picks a fourth. Instead the gap between attempts runs
`.github/scripts/await-ghcr.sh`, which reads a manifest from each package the build touches — the base
image it pulls `FROM` and the app repository it pushes to, since a throttle need not hit both — and
reports the result as a workflow annotation:

- **Either probe refused** — GHCR was refusing this account, and the annotation says which package.
  The registry is the suspect.
- **Both answered** — the build itself is the likelier suspect, so read the build log. Note this is
  evidence, not a verdict: both probes are *reads*, so they cannot clear a write-side throttle, which
  is the exact shape the 2026-08-06 push failure took. Check whether the build died on the pull or the
  push before concluding.

That is the line to look for on a run that exhausted its attempts, because the attempts themselves are
unhelpful to read: a step that failed under `continue-on-error` renders with a red ✗ against a green
job, since GitHub has no separate rendering for it.

The retry is not free, and the cost is lopsided in a useful direction. Every attempt runs on the same
buildkit instance — `builder:` names the one this job created, and it lives for the whole job — so a
retry resumes from that builder's local cache rather than starting cold. A **push**-side failure is
therefore cheap to retry: the image is already built, and the second attempt re-does little more than
the export. A base-**pull** failure early in the graph is the expensive one, because there is nothing
cached to resume from yet. (The GHA cache is no help either way on a retry: `cache-to` exports nothing
from a failed build.)

The floor is the backoff itself. A genuinely broken build — one that fails for an ordinary reason and
will fail three times — now takes 330 seconds of waiting plus three builds to go red, and
`concurrency: release-image` with `cancel-in-progress: false` makes the next push queue behind all of
it. That is the trade: slower bad news, in exchange for not paging anyone over a registry hiccup.

Every attempt takes its tag list from the `tags` output of `Compute version` rather than spelling it
out three times, and `image_build_workflows_test.rb` asserts the chain stays wired: attempts in order,
each gated on every prior one failing, identical build inputs, `continue-on-error` on all but the
last, and a probing backoff step in every gap. Each of those, alone, is enough to produce a workflow
that publishes nothing and reports the release green.

What the retry does **not** cover is the base-image half of the same job. `Check for base image` and
`Build & push base image` are single-shot, and they talk to the same throttled registry — so a
throttled `imagetools inspect` fails closed into `need_base=true` and escalates a read hiccup into a
*full base rebuild and push* against a registry that is currently refusing the account. That path
fails the job before the app build's first attempt is ever reached. It has not bitten yet; all three
observed failures were the app build.

### Staging deploys are Kamal container swaps onto a persistent droplet

The droplet is no longer cattle. Terraform provisions it **once** and then leaves it alone; Kamal
deploys the app onto it. `deploy-staging.yml`:

1. Builds the base image (`:staging`) and app image (`:staging-<sha>`).
2. `terraform apply` — reconciles the **existing** droplet through remote state. It does not reap
   anything, and a re-run updates in place rather than recreating.
3. Joins the tailnet, resolves `zimmer-staging`'s peer IP from `tailscale status --json`, and loads
   the Kamal deploy key.
4. `kamal accessory boot all -d staging`, then `kamal deploy -d staging --version=<tag>
   --skip-push`. The boot line is unconditional, because `kamal deploy` on its own does not boot
   accessories and a newly declared one would otherwise never appear; it costs nothing to repeat,
   since `accessory boot` skips a host that already has the container (production's pipeline, in the
   companion repo, runs the same line before its own deploy). kamal-proxy boots the new container
   alongside the old one, health-checks it on `/up`, and only then flips traffic. A container that
   never goes healthy leaves the old one serving.
5. Re-verifies `/up` over the tailnet and asserts the **worker** container is running too — the
   worker is where agent sessions actually execute.
6. Smoke-tests the app it just deployed: `/up/deep`, a real page render, a CSRF round trip, and an
   Action Cable upgrade. See below — this is the step that decides whether the deploy is called
   healthy.

If the rebuild path (`recreate_droplet`) runs without `TS_API_CLIENT_ID` / `TS_API_CLIENT_SECRET`,
`scripts/tailnet-reap-node.sh` still skips the stale-node cleanup — a fork that never configured a
Tailscale OAuth client must not have its rebuild fail over it — but it now says so as a GitHub
Actions **warning** rather than an info line nobody reads. The consequence of a silent skip surfaces
much later and somewhere else: the rebuilt droplet registers as `zimmer-staging-1` and the MagicDNS
name drifts off the box you deployed.

### The `ref` input is resolved before anything is checked out

`Deploy staging` takes a `ref` — a branch, a tag, or a commit SHA — and pinning a deploy to a
known-good commit is how a rollback is driven. `actions/checkout` only special-cases a **full
40-character SHA**, though; anything shorter it treats as a branch or tag name. An abbreviated
SHA (`9e95b4d`) therefore had it fetch `refs/heads/9e95b4d*` and `refs/tags/9e95b4d*`, match
nothing, retry three times, and fail sixty seconds in with

```text
The process '/usr/bin/git' failed with exit code 1
```

which never mentions the ref. An abbreviated SHA is exactly what `git log --oneline` prints and
what gets pasted into a pinned redeploy, and the input's own description said "SHA", so the trap
was baited.

The job now checks itself out once to get `scripts/` on disk, runs
`scripts/resolve-deploy-ref.sh`, and checks out whatever that returns:

- **Empty** — the exact commit the run was dispatched from (`github.sha`), so the two checkouts
  cannot land on different commits if someone pushes to the branch in between. No request made.
- **A full SHA** — passed through untouched. Checkout already handles it, and asking the API
  about it could only *narrow* what the workflow accepts.
- **Anything else** — one `GET /repos/{owner}/{repo}/commits/{ref}`, sent with the `.sha` media
  type so the answer is the forty characters and nothing else. That endpoint resolves branches,
  tags, and abbreviated SHAs alike.

Because the ref is interpolated into a URL path, it is first held to a deliberately narrow shape
— `[A-Za-z0-9._/@+-]`, never containing `..`. That is *narrower* than `git check-ref-format`: a
branch legitimately named `fix#123` is refused, and the message says so in those words rather
than claiming the branch is invalid. Its full SHA is always a way through.

A ref that does not exist now fails in about a second, names itself, and quotes GitHub's own
sentence (`No commit found for SHA: 9e95b4d`). A ref that could not be resolved *because the API
was unreachable* says that instead — with curl's own reason attached — because those send an
operator to two different places. So a 4xx is never retried, while a transport failure gets three
attempts with a backoff between them.

### `/up` is a liveness ping; `/up/deep` is the health check

`/up` is Rails' built-in endpoint, and it answers 200 for any process that finished booting. A
container with a dead database, an unreachable Redis, or a cache store that silently drops every
write answers it 200 all the same. A deploy gate that asks only `/up` therefore declares a fully
broken deploy healthy — which is what happened.

`GET /up/deep` (`app/services/deep_health_check.rb`) answers 200 only when every backing service the
app cannot serve a page without has answered a real round trip, and `503` naming the one that did
not:

| Check | What it does | What only it catches |
| --- | --- | --- |
| `database` | `SELECT 1`, then one indexed row from a real application table | A Postgres that connects but has none of the app's tables — wrong database, unmigrated volume |
| `cache` | Writes a per-request canary and **reads it back** | `:redis_cache_store`'s `error_handler` swallows connection errors, so a dead Redis makes `write` and `read` return `nil` instead of raising. Reading the value back is the only way to tell a working store from one quietly discarding everything |
| `redis` | `PING` on the connection the cache store actually holds | Turns "the cache is not storing anything" into "Redis is unreachable, and here is what it said". Reported as `skipped` where no Redis is configured (development, test), which is not a failure |

```json
{
  "status": "error",
  "failed": ["cache"],
  "checks": {
    "database": { "status": "ok", "adapter": "PostgreSQL" },
    "cache": { "status": "error", "error": "the cache store did not return the value it just wrote (read back nil)" },
    "redis": { "status": "error", "error": "Redis::CannotConnectError: Error connecting to redis://[redacted]@…" }
  },
  "checked_at": "2026-08-01T20:13:38Z"
}
```

Two deliberate properties. It is **unauthenticated**, like `/up`, so a deploy gate and an uptime
monitor can reach it — which is why anything it echoes from a backing service is scrubbed of
`scheme://user:password@` credentials and truncated. And it is **not** behind
`HealthActionCooldown`: that limiter guards the destructive maintenance actions and fails closed, so
it would answer "rate limited" for precisely the broken-cache case this endpoint exists to report,
and a health endpoint that refuses a monitor's second poll in 30 seconds is not a health endpoint.
What makes that safe is that the probe is cheap and fixed-cost — one `SELECT 1`, one single-row
indexed read, one cache round trip, one `PING`, less work than any page the same visitor could
request instead.

The post-deploy smoke step asserts four things, and every one of them fails the run (unlike the
telemetry probe, which warns — broken telemetry is not a reason to withhold a working deploy):

| Assertion | A failure means |
| --- | --- |
| `GET /up/deep` → 200 | A backing service is down; the body names which |
| `GET /` → 200 | The app is serving errors on its own root page |
| `POST` without a CSRF token → 422, then with the page's token → 404 | The session cookie or `secret_key_base` did not survive the deploy: every GET looks perfect while every form in the UI 422s. The target is a session id that cannot exist, so the authorized request 404s having changed nothing |
| `GET /cable` upgrades to a WebSocket | Turbo Streams cannot connect — every live update in the UI (timelines, status badges, notification counts) is dead |

Two things follow from this that did not used to be true:

- **Rollback is one command.** `kamal rollback <version> -d staging` (the host retains the last 5
  images).
- **State survives a deploy.** `web` and `worker` share durable named volumes (`zimmer_data`,
  `claude_home`, `codex_home`, `gh_config`, `claude_local`), which are re-attached to each new
  container instead of being destroyed with the droplet.

### `CanaryJob` is what the post-deploy drain gate enqueues

`/up/deep` proves the web process can reach its backing services. It says nothing about whether the
`worker` container is claiming jobs — and on 2026-08-13 a deploy passed every automated check while
production processed zero background jobs for ten hours. The post-deploy drain gate closes that hole:
it enqueues a canary onto `default`, `pollers`, `triggers` and `agents` at negative priority, and
fails the deploy if the worker does not claim and finish each one inside a bounded timeout.

The job it enqueues is `app/jobs/canary_job.rb` — a no-op that logs its token and returns. Everything
about it is a constraint rather than a feature:

- **It touches no database, no network and no shell.** Anything it starts touching is a way for a
  liveness gate to fail for a non-liveness reason, on every production cutover.
- **It declares no concurrency control.** A `total_limit`/`enqueue_limit` rule makes GoodJob
  `throw :abort` at enqueue time, so no row is ever written; a `perform_limit` writes a row that is
  deferred rather than run. The gate cannot tell either from a dead queue — it would fail deploys of
  a healthy fleet.
- **It is not dead code, and its name is load-bearing.** The gate resolves the class by name and
  falls back to a business job if it is absent. That fallback was
  `CleanupExpiredElicitationsJob`, which is a singleton sweep
  (`include SingletonSweep` → `total_limit: 1`) that runs every five minutes — so a canary enqueued
  onto it during a tick it was already running produces no row at all, and the gate reds a healthy
  deploy. Renaming or deleting `CanaryJob` reinstates exactly that.

One thing the gate still cannot see:
[queue recovery mode](/operate/background-jobs/#queue-recovery-mode) pauses `default`, `pollers` and
`triggers` via `GoodJob.pause`, and that pause is persisted in `good_job_settings`, so it survives a
deploy. A cutover that lands while recovery mode is active fails the drain check on three of its four
queues with a perfectly healthy worker. The gate is the piece that has to learn to read
`GoodJob.paused(:queues)` and skip rather than fail; nothing in this repo can do it for it.

`test/jobs/canary_job_test.rb` holds each of those lines, including a round trip through a real
GoodJob row on all four queues.

### The worker watchdog is converged on every deploy

Everything above proves the deploy is healthy *at the moment it finishes*. `Install the worker
watchdog (converge)` installs the thing that keeps asking: `scripts/install-worker-watchdog.sh`
drops `scripts/worker-watchdog.sh` on the host as `/usr/local/sbin/zimmer-worker-watchdog` and
drives it from a 60-second systemd timer.

It exists because a container can pass every check in this document while running nothing. A
cgroup OOM under `sysbox-runc` can leave the worker reporting `Status=running, Restarts=0` with
`docker exec` permanently broken ([#502](https://github.com/tadasant/zimmer/issues/502)), so the
probe is a real `docker exec` rather than a status read. What it does on a confirmed wedge, and the
manual ladder for the rung it will not take on its own, are in
[When the worker wedges](/operate/nested-docker/#when-the-worker-wedges).

Two properties of the step itself. It runs **unconditionally**, not gated on `nested_docker`: an
unexecable worker is worth catching under plain `runc` too, and a deploy that disarms sysbox should
not silently disarm its watchdog. And it is a **converge**, not a one-off install — the droplet is
persistent and cloud-init only ever runs at first boot, so re-running is how a changed script
reaches a box that already exists. Same shape as `Clear forced root-password expiry (converge)`.

#### Calling it from a deploy that is not this one

Production's deploy lives in the private companion repo, and it does not reach its droplet the way
the step above does: it goes over the tailnet with a generated ssh config, because its runner
hygiene check forbids the key and the `Host *` stanza in the shared runner `$HOME` that a bare `ssh
root@host` depends on. Two environment variables are the whole interface for that, and both are
inert when unset — staging's `bash scripts/install-worker-watchdog.sh "$STAGING_HOST"` above is
unaffected by their existence.

| Variable | What it does |
| --- | --- |
| `ZIMMER_WATCHDOG_SSH_EXTRA` | Extra arguments for every `ssh` the installer runs, split on whitespace. `-F <config>` is the motivating case. They go *first*, ahead of the installer's own options, because ssh takes the first value it obtains for an option — so a caller can override `ConnectTimeout` or the host-key policy and cannot be overridden by them. |
| `ZIMMER_WATCHDOG_RECOVER` | `0` or `1`, rewritten into `/etc/default/zimmer-worker-watchdog` on **every** run. Unset — staging, and any host nobody has declared a value for — keeps the old behaviour: seed the commented template if the file is absent, then never touch it again, so an operator's edit survives a deploy. |

Recovery is the setting production cares about. It restarts the worker container, and on a host
running real agent sessions that kills every one of them, so production runs detect-and-alert only.
A value that merely *starts* right is not enough — it has to be re-asserted, including on a droplet
rebuilt from scratch and on one somebody edited by hand:

```bash
ZIMMER_WATCHDOG_SSH_EXTRA="-F ${SSH_CONFIG}" \
  ZIMMER_WATCHDOG_RECOVER=0 \
  bash scripts/install-worker-watchdog.sh "$PROD_HOST"
```

### What changed, and why

The old flow re-rendered the whole app stack into cloud-init's `user_data` — a **replace-forcing**
attribute on `digitalocean_droplet`. Any change to the image or an env var therefore destroyed and
rebuilt the droplet (and everything on its disk). Combined with ephemeral Terraform state, which
forced the workflow to hand-reap the droplet and firewall through the DigitalOcean API before every
`apply`, staging was torn down and rebuilt constantly.

Now: the app stack lives in Kamal (`config/deploy.*.yml`), `user_data` is only a bootstrap, and the
droplet carries `lifecycle { ignore_changes = [user_data] }` (deliberately *not*
`create_before_destroy` — the tailnet hostname is fixed). A config or app change can no longer replace
the box. The cost of freezing `user_data` is that the deploy key and Caddyfile can't be updated in
place — see [Known limitations](/limitations/#user_data-is-frozen-so-the-deploy-key-and-the-caddyfile-cant-be-updated-in-place).

`monitoring` is in that same `ignore_changes` list, for the same reason from the other direction. The
droplet asks for DigitalOcean's metrics agent (`monitoring = true`) so a newly created box gets host
CPU/memory/disk/load history for free, but the attribute is `ForceNew` in the provider — setting it on
a droplet that already exists is a replace, not an update, and both environments apply with
`-auto-approve`. Ignoring it keeps a routine `apply` from destroying the host over a metrics agent.
The trade is that an existing droplet only gets the agent when it is rebuilt: DigitalOcean offers no
API action to enable it, and its documented remedy is a root shell on the box, which this deployment
does not have. See
[Known limitations](/limitations/#the-digitalocean-metrics-agent-reaches-only-a-droplet-terraform-creates-never-one-that-exists).

## Terraform, briefly

```bash
cd infra/terraform
cp staging.tfvars.example staging.tfvars
export TF_VAR_do_token=… TF_VAR_tailscale_auth_key=… TF_VAR_deploy_ssh_pubkey="$(cat ~/.ssh/kamal.pub)"
export AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=…   # DO Spaces keys, for the state backend
# Operator keys, if you want the publickey door on :2222. In CI this comes from the
# ADMIN_SSH_PUBKEYS Actions variable; it is never committed. Unset means [].
export TF_VAR_admin_ssh_pubkeys='["ssh-ed25519 AAAA… you@laptop"]'
terraform init -input=false -backend-config=backend.staging.hcl
terraform apply -input=false -auto-approve -var-file=staging.tfvars
```

Creates: the droplet, the firewall, and a reserved IP (a stable public address across rebuilds).
`manage_project` stays **`false`** by default — a project name is account-unique and a pre-existing
one 409s, so a DO Project (just a console folder) isn't worth the failure mode; flip it on with a
one-time `terraform import` if you want one.

Terraform no longer knows anything about the app: no image ref, no secrets, no database wiring. Those
are Kamal's. It also does **not** create a DNS record — when `var.domain` is set, the `domain-cert`
workflow owns the A record (pointing at the tailnet IP), which keeps the Cloudflare credential out of
Terraform.

Staging runs a Postgres accessory container on the droplet, wired by Kamal — nothing external to
provision. A self-hosted production deployment would instead point at its own database (Terraform can
reference one as a read-only data source rather than creating it), but that lives in your own private
infrastructure, not here.

→ [Provisioning and secrets](/operate/provisioning/)
