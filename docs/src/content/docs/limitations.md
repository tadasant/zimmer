---
title: Known limitations
description: Every bug, quirk, brittle assumption, and open question found by reading the code. This page is meant to be read, not skipped.
sidebar:
  order: 1
---

This page aggregates every known bug, quirk, and brittle assumption in Zimmer, derived by reading the
code rather than the old docs, which were themselves often wrong.

Every item names a file so you can verify it. Nothing is left out for looking bad. Items whose first
line starts with 🔴 would bite a new operator immediately.

Nearly every item below links to the issue tracking it. The few that don't are deliberate — a
platform limit or a design choice we don't intend to change (Push notifications without the Push
API; `RAILS_MASTER_KEY` staying optional on staging, below) — and each says so in place.

---

## Deployment

The deploy is Kamal onto a persistent, Tailscale-only droplet: Terraform bootstraps the box (Docker,
Tailscale, Caddy, the deploy key), and Kamal owns the app stack — a `web` role and a `worker` role
running `bundle exec good_job start`, with durable named volumes for clones and credentials. The
items below are the sharp edges that survived that migration.

### `user_data` is frozen, so the deploy key and the Caddyfile can't be updated in place

The droplet carries `lifecycle { ignore_changes = [user_data] }` — that is what stops app changes from
force-replacing it. The cost: the Kamal deploy public key and the Caddyfile are delivered **only**
through `user_data`, so rotating `KAMAL_SSH_KEY` or changing `var.domain` produces **no plan diff** and
never reaches the box. Both require an explicit `terraform taint digitalocean_droplet.zimmer` — i.e.
deliberately re-creating the droplet, which is exactly the churn this model exists to avoid.

Rotating the deploy key is rare; changing the domain is rarer. But neither is a no-op.

Tracked in [#121](https://github.com/tadasant/zimmer/issues/121).

### RAILS_MASTER_KEY is optional on staging, and silently degrades when absent

Staging *can* read encrypted credentials: `config/credentials/staging.yml.enc` is committed, and
`deploy-staging.yml` passes the `STAGING_RAILS_MASTER_KEY` secret through `.kamal/secrets.staging` as
`RAILS_MASTER_KEY`. What remains sharp is what happens without it.

The key is not required, on purpose — failing the deploy would break staging for any fork or
self-hoster that has not set the secret. And it cannot fail loudly at runtime either: ActiveSupport
reads the key as `ENV["RAILS_MASTER_KEY"].presence` (`active_support/encrypted_file.rb`), so blank and
unset are the same thing, `secrets_loader.rb` rescues the miss, and there is no `require_master_key`.
The app boots, healthy, serving **no** `mcp_secrets` — Slack triggers and `AlertService` go quiet, and
any MCP server with a `${VAR}` placeholder fails at session start. `deploy-staging.yml` emits a
`::warning::` when the secret is empty, which is the only signal you get.

Production is unaffected: its `.enc` is bind-mounted onto the droplet rather than committed, and
`PROD_RAILS_MASTER_KEY` is mandatory in practice.

The flip side, once the key *is* set: staging's `AlertService` and `SystemHealthMonitorJob` start
posting to the `ENG_ALERTS_SLACK_CHANNEL_ID` in `staging.yml.enc` — a real Slack channel that humans
watch. Staging alerts are only distinguishable from production's by the posting bot (*Zimmer
(Staging)*), so point staging at a different channel if that noise is unwelcome.

### Telemetry is a hard no-op when misconfigured, and says nothing

`config/initializers/otel_logs_exporter.rb` needs **both** `OTEL_LOGS_EXPORTER_ENDPOINT` and
`OTEL_LOGS_EXPORTER_BEARER_TOKEN`; `config/initializers/sentry.rb` needs `SENTRY_DSN_BACKEND`. Any of
them missing and the initializer does nothing at all — no raise, no warning, a perfectly healthy boot,
and no data. A deployment can sit in that state indefinitely, and nothing anywhere says so. Staging did
exactly that: every layer of the wiring was in place except the two GitHub Actions secrets, so it shipped
nothing at all, healthily, for as long as anyone cared to look.

The no-op is a reasonable default on a machine that never sets the variables, so the mitigation is
visibility rather than a hard failure. On **staging** that visibility is now enforced: `deploy-staging.yml`
prints an observability preflight, and then — when both secrets are set — runs `bin/rails obs:smoke` in the
deployed container and fails the run if the collector rejects the ingest or the exporter is off anyway.
**Production has no such gate** (it deploys from a separate repo), so there the mitigation is still only
`bin/rails obs:status` / `bin/rails obs:smoke`, run by hand. Absence of data is never, by itself, evidence
of absence of errors.

What the no-op is *not* is an environment guard. Zimmer's agent sessions run inside the production
container, so the production values are present in their environment — and a `RAILS_ENV=test`
process with a production DSN reports to the production error project, which is how a test-env
database error once paged the production Slack channel. Errors are therefore additionally gated on
`Rails.env` being `production` or `staging`
([details](/operate/observability/#only-production-and-staging-may-report)).

### A CSRF failure still ships a context-free WARN, and is still counted per record

`ApplicationController` handles `ActionController::InvalidAuthenticityToken` and re-logs it at
INFO with the verb, path, IP, user agent, failure reason, and whether a session cookie was
present, so the failure no longer emits an ERROR record and no longer pages
([details](/operate/observability/#client-caused-rejections-are-re-logged-at-info-not-suppressed)).
Three edges remain.

**The attributable line is not in VictoriaLogs.** The exporter ships WARN and above, so the INFO
record lands on container stdout and nowhere else. What Grafana still has is the WARN Rails logs
from inside `handle_unverified_request` before any application code runs — and that line names
nothing: no path, no verb, no client. So an on-call who stops at Grafana is back where
[#295](https://github.com/tadasant/zimmer/issues/295) started, and has to read the container to
get the rest. Logging it at WARN instead would put it in Grafana and still page nobody (the
production rule counts ERROR records only); it is at INFO because that is what #295 specified
and what `ErrorsController` already does for 404s. Suppressing the bare WARN is possible only
with `config.action_controller.log_warning_on_csrf_failure = false`, which would also silence it
in development, so it has been left alone.

**The alert is per-record, not a rate.** One CSRF failure is a stale form or a bot; a hundred an
hour is the app being broken for every writer, which is what
[#19](https://github.com/tadasant/zimmer/issues/19) was. Both look identical to a rule that
counts to one. Fixing that is an obs-side change and lives in `tadasant-internal` (`obs/`), not
in this repo.

**Administrate is not covered.** `Supervisor::ApplicationController` descends from
`Administrate::ApplicationController`, not from Zimmer's `ApplicationController`, so it never
sees the handler. A tokenless non-GET to any `/supervisor/*` route still raises, still logs at
ERROR, and still pages. Nothing links to those routes from the public UI, so the realistic
trigger is a probe rather than a user.

### An agent session's shell still carries the OTLP ingest token

`SENTRY_DSN_BACKEND` is scrubbed from agent-session child processes (`CliSpawnEnv`), but
`OTEL_LOGS_EXPORTER_ENDPOINT` and `OTEL_LOGS_EXPORTER_BEARER_TOKEN` are not. Two consequences: the
shared ingest token sits in every agent shell's environment, one `env` away from a transcript; and a
`bin/rails` command an agent runs in a repo clone ships that clone's WARN/ERROR lines to the real obs
stack. Neither pages anyone — the records are stamped `deployment.environment=test`, and production
alert rules scope to `deployment.environment=production` — so this is noise and credential exposure,
not false alerting. Scrubbing them too would stop agent-session log export outright, which is a
bigger decision than it looks; it has not been made.

### Staging cannot have its own OTLP ingest token

The obs stack's ingest gateway matches the `Authorization` header against a **single** shared token,
so staging authenticates with the same bearer token as production. There is no per-environment ingest
credential, and revoking staging's access means revoking production's. Separation happens *after*
ingest, via the `deployment.environment` resource attribute — which is a labeling boundary, not a
security one.

Errors do get a real boundary: staging and production point at different GlitchTip projects, because a
DSN selects a project and GlitchTip's alert rules are per-project with no environment filter.

### Nothing prevents a staging error from paging production's alert channel

The separation between staging and production telemetry is the `deployment.environment` attribute, and
it only works if the *consumer* honors it. An alert rule that selects on `{service.name="zimmer"}`
alone matches staging records identically to production ones. Zimmer emits the label correctly; it
cannot enforce that the alert rules on the other side filter by it. Those rules live in a separate
repository.

### Every agent-session clone carries the Slack bot token and the alert channel id

`AgentSessionJob#inject_secrets_to_env_file` writes `SecretsLoader.all` — the whole credential bundle
— into each clone's `.env`, and that bundle includes `SLACK_BOT_TOKEN` and
`ENG_ALERTS_SLACK_CHANNEL_ID`. Anything an agent runs inside its clone can therefore post to the real
alert channel as the real bot. An agent's shell also has no `RAILS_ENV`, so a clone that boots Zimmer
boots it as `development`.

That combination is what fired in [#272](https://github.com/tadasant/zimmer/issues/272): a clone
registered development's cron table, probed the approval endpoint at `http://localhost:3000` where
nothing was listening, and paged the production channel every five minutes. Every suppressor that
should have capped it at one message is cache-backed and swallows its own failures, so an unreachable
cache silently removed all of them at once.
[Only the deployed environments may page](/operate/background-jobs/#who-is-allowed-to-page), which
closes that path. But the gate is Zimmer's own restraint, exercised by code that happens to be
Zimmer's; it is not a scope on the credential. The token is still in the file, and nothing stops other
code from using it.

### SSH hardening only reaches a droplet that is rebuilt

SSH is now [tailnet-only](/operate/ssh-access/#ssh-is-tailnet-only): the firewall opens no public
TCP port, real OpenSSH listens on a tailnet-only `:2222`, and sshd takes password auth off. But two of
those three land through **cloud-init**, and the droplet carries `ignore_changes = [user_data]` — so
they only reach a box that is *rebuilt*.

The firewall change is the exception and the one that matters most: it is a plain resource, so a
normal `terraform apply` closes public `:22` on the existing droplet immediately. What waits for a
rebuild is the `:2222` listener and the `PasswordAuthentication no` drop-in. Until then a long-lived
droplet keeps whatever sshd posture it booted with — which, on an Ubuntu cloud image, is
**`PermitRootLogin yes` + `PasswordAuthentication yes`** (see below).

Deploy with `recreate_droplet: true` to force the rebuild, or apply the two files by hand and let the
next rebuild converge.

### Neither the sshd config files nor `sshd -T` tell you what sshd is actually doing

Two independent traps, and they stack. Both bit this repo for real.

**The config files lie.** `/etc/ssh/sshd_config.d/60-cloudimg-settings.conf` says
`PasswordAuthentication no`. sshd takes the **first** value it sees for a keyword, and cloud-init
writes `PasswordAuthentication yes` into `50-cloud-init.conf`, which sorts first — so `60`'s `no`
never won, and root password auth was genuinely accepted on both droplets while the file said
otherwise. That is why the hardening drop-in is `10-hardening.conf`: it has to sort *before* `50`.

**`sshd -T` also lies** — it is a fresh *parse* of the config on disk, not a readout of the running
daemon. Ubuntu's `ssh.socket` is `Accept=no`, so it hands its sockets to **one long-lived `sshd -D`**
that parsed its config once, at start. Write a hardening drop-in without restarting `ssh.service` and
`sshd -T` will cheerfully report `passwordauthentication no` while the live daemon keeps taking
passwords. This is exactly what happened when the fix was first applied to production by hand.

The only honest check is what the daemon *advertises on the wire*:

```bash
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password -p 2222 root@<host>
# key-only  ->  Permission denied (publickey).
# still bad ->  Permission denied (publickey,password).
```

### Production's forced root-password expiry has no converge path

🔴 DigitalOcean force-expires root's password on any droplet created without a DO-registered SSH key —
which is the deliberate posture here — and `pam_unix` then rejects
[every real-OpenSSH session on `:2222`](/operate/ssh-access/#digitalocean-force-expires-roots-password-and-that-rejects-every-openssh-session)
*after* publickey auth succeeds. cloud-init clears it at first boot, and
`scripts/clear-root-password-expiry.sh` repairs a box that already exists — including one whose
password DigitalOcean's **Reset root password** flow has just re-expired.

The staging deploy runs that script on every deploy. **Production's deploy workflow is not in this
repo** (it lives in the private mirror), so nothing converges production. Production's OpenSSH works
today only by accident: its root password happened to be changed at some point, which reset `lastchg`.
Rebuild it and it comes up broken, exactly like staging did.

Run the script by hand from a tailnet host — `scripts/clear-root-password-expiry.sh zimmer` — or add
the step to the mirror's workflow.

Tracked in [#151](https://github.com/tadasant/zimmer/issues/151).

### An agent session's SSH key is root on every host it can reach, and no session is scoped

The [operator SSH key](/operate/provisioning/#the-ssh-identity-an-agent-session-holds) that agent
sessions authenticate with is authorized for `root` — there is no unprivileged SSH user on a Zimmer
box. It opens staging, the observability host, and the CI runner, at full privilege, from any session.

There is **no per-session scoping**. Every session in the worker container inherits the same key, so
"which sessions may SSH where" is not a question Zimmer can answer: they can all go everywhere the key
goes. The only real control is which hosts authorize the key, and that is a per-host decision made
outside the app.

That control is used in exactly one place, and it is the important one: **production does not
authorize the key**. A session runs *on* production, and a session with root on its own host can take
the orchestrator down with itself inside the blast radius. Staging is disposable, so the same key
there is an accepted trade. See [who is authorized where](/operate/ssh-access/#who-is-authorized-where)
— and do not reconcile the two lists.

### Admin keys are add-only

`admin_ssh_pubkeys` appends to `/root/.ssh/authorized_keys` and never prunes. **Removing** a key from
the list does not revoke it from a running droplet — that needs a rebuild or a manual edit. Adding
does not reach a running droplet either (the list rides `user_data`, which cloud-init reads once at
creation), so the variable is really "who gets authorized on the next rebuild", not a live
access-control list. A key can be [appended live over Tailscale
SSH](/operate/ssh-access/#adding-a-key-does-not-touch-a-running-droplet) — which is how production
converges, since it cannot be casually rebuilt — but that is a separate action, not something the
variable does.

### Staging's admin key list is invisible state in an Actions variable

Staging's `admin_ssh_pubkeys` comes from the `ADMIN_SSH_PUBKEYS` repository variable, not from the
committed `staging.tfvars.example` — the file is copied verbatim into every deploy, and this repo is
public, so a key in it would be [authorized for `root` on every fork's
droplet](/operate/ssh-access/#operator-keys). The cost of moving it is that the list now lives
somewhere no diff shows: a repository setting, editable by anyone with admin, reviewed by nobody.

Unset — or set to `[]` — it falls through to an empty list, and that failure is silent in the
direction that matters. The deploy still succeeds (Kamal carries its own key), health checks still
pass, and the box is still reachable over Tailscale SSH on `:22` — only the publickey door on `:2222`
is gone, which nothing exercises until an `ssh-*` MCP server inside a session fails to attach. And
because the list rides cloud-init, an unset variable only bites on the rebuild that consumed it, long
after it was unset.

The deploy prints the effective list — key count and each key's comment — on every run, and warns
when it is empty, more loudly when `recreate_droplet` is on. That makes it a line in the log rather
than a discovery, but it is still a log nobody reads on a green deploy.

### A rebuilt droplet has exactly one fallback door, and it is the DigitalOcean console

The firewall now permits **zero public TCP**. On a `recreate_droplet` rebuild, if `tailscale up` fails
— an expired or exhausted auth key is the likely way, and the key is frozen into `user_data` at first
boot — then there is no tailnet, so no Tailscale SSH; `:2222` is unreachable from outside the tailnet;
there is no public `:22`; and Kamal cannot reach the box either. `runcmd` has no `set -e`, so the boot
completes "successfully" regardless.

Before setting `recreate_droplet: true`, confirm (a) `TAILSCALE_AUTH_KEY` is valid and not exhausted,
and (b) you can actually log into the DigitalOcean web console for the droplet.

That console door has a catch. cloud-init deletes root's password (`usermod -p '*'`) — it must, or
[pam_unix rejects every OpenSSH session](/operate/ssh-access/#digitalocean-force-expires-roots-password-and-that-rejects-every-openssh-session) —
so there is no password to type at a console login prompt. Getting one means DigitalOcean's **Reset
root password**, which mails a new one *and* force-expires it again (`lastchg=0`). So the reset that
buys you a console also re-breaks `:2222` until the next staging deploy converges it, or until
`scripts/clear-root-password-expiry.sh` is run against the box.

### 🔴 The database's connection ceiling is a plan property, and Terraform will not raise it for you

Zimmer's connection promise is derived and checked ([the connection
budget](/operate/deploying/#the-database-connection-budget)), but the *other* half — the number of
slots the cluster actually has — is fixed by the DigitalOcean plan slug, and Terraform holds the
production cluster as a data source on purpose, so it has no resize path. All Terraform can do is
refuse to plan against a cluster that is too small, which is what its `lifecycle.postcondition` does.

The order of operations is therefore: **resize the cluster first, deploy second.** A cluster that
cannot serve the budget fails `terraform apply` with the `doctl databases resize` command in the error
message. Promoting the cluster to a managed resource (with `prevent_destroy` and a one-time
`terraform import`) would let Terraform do the resize itself, at the cost of giving it a destroy path
over the one irreplaceable resource in the system. That trade has not been made.

### PgBouncer is not an option here, whatever the connection math says

The reflex for connection exhaustion is a transaction-mode pooler, and DigitalOcean ships one. It does
not work for Zimmer, for two independent reasons:

- **GoodJob forbids it.** Its README is explicit: *"GoodJob is not compatible with PgBouncer in
  transaction mode"* — it uses connection-based advisory locks and `LISTEN`/`NOTIFY`, both of which
  need a full session. The escape hatch (`lock_strategy = :skiplocked` plus
  `enable_listen_notify = false` plus `advisory_lock_heartbeat = false`) is marked experimental and
  trades away the dead-worker detection that reclaims a Zimmer agent session whose worker died.
- **It would not create headroom anyway.** A DigitalOcean pool's backend connections are allotted *out
  of* the cluster's `max_connections`, not on top of it. Pooling the `web` role — the one role whose
  connections are short-lived enough to multiplex — would save a handful of slots on a process that
  only wants eight.

Session-mode pooling maps clients 1:1 onto backends, so it buys nothing at all. The lever is the plan.

### Terraform's connection check sees the repo, not the container

`app_required_backends` in `infra/terraform/main.tf` is a literal, kept equal to
`ConnectionBudget.required_backends` by a test — so changing the app's **defaults** moves the guard
with them. Changing them through the **environment** does not: raise `GOOD_JOB_AGENTS_THREADS` or
`DB_POOL` in `config/deploy.production.yml` and the app's real promise grows while Terraform keeps
validating the old number and passes.

Nothing sets those variables today, so the shipped numbers are correct. The check that *does* see the
running configuration is `bin/rails db:connection_budget` — it reads the actual process env and the
actual server, and exits non-zero when they don't fit. Run it in the container, not on your laptop.

### A saturated `cable` pool would degrade silently

`BroadcastService` rescues every broadcast failure and deliberately does not re-raise — a failed Turbo
Stream must not kill the agent job that emitted it (`app/services/broadcast_service.rb:265`), and a
circuit breaker opens after five failures. That is the right call for the job, but it means the
`cable` pool is the one pool whose exhaustion produces no error: the symptom is UI updates that stop
arriving while the session itself runs fine. The UI at least admits it now — an open breaker lights
the "Live updates paused" banner (see
[Background jobs](/operate/background-jobs/#the-circuit-breaker-on-the-ui)) — but the banner reports
the breaker, not the pool, so diagnosing *why* still means reading the logs.

The pool is sized at 3 because `solid_cable` leases per `INSERT` and returns the connection, and only
~2% of broadcasts also run an autotrim transaction (`SolidCable::TrimJob`, a SKIP-LOCKED delete of ≤100
rows) — so saturating it would take thousands of broadcasts per second, and sixteen agent sessions
produce single or double digits. If that estimate is ever wrong, the failure will be quiet. Raise
`CABLE_DB_POOL` and `app_required_backends` together.

### Staging cannot exercise the managed-database path

Staging runs a `postgres:16` Kamal accessory on the droplet; only production has a managed cluster. So
staging *can* verify the app-side half of the connection budget — the pools each process opens, which
is where the 2026-07-13 defect lived — and it can verify the pools fit the server. It cannot exercise
the Terraform postcondition, the DigitalOcean plan ceiling, or a resize, because it has none of them.
The accessory's `max_connections=100` (the `postgres:16` default) happens to leave 97 usable backends,
the same as the `db-s-2vcpu-4gb` plan, which makes the comparison a fair one — but it is a
coincidence, not a guarantee, and nothing pins it.

### `DATABASE_SSLMODE` defaults to `require`, so a non-TLS Postgres must opt down explicitly

The default used to be `prefer`, which asks for TLS and accepts plaintext when the server does not
offer it, saying nothing either way — a deployment that lost TLS kept working, unencrypted, with
nothing to notice. The default is now `require`: TLS or no connection.

The edge that creates is the mirror image. A deployment pointed at a Postgres with `ssl = off` now
fails to connect at boot with `server does not support SSL, but SSL was required`, instead of
quietly proceeding. Every environment Zimmer ships already names its own value —
`config/deploy.production.yml` sets `require` for DigitalOcean Managed Postgres,
`config/deploy.staging.yml` sets `prefer` for the throwaway compose accessory,
`.agent-containers/.env.dev` sets `disable` — and `development`/`test` default to `prefer` via a
separate `local_default` anchor in `config/database.yml`, because local Postgres (Homebrew, the
GitHub Actions service container, the compose `db`) ships with SSL off and `require` would refuse
every connection.

So the failure lands on a *self-hosted* deployment running its own non-TLS Postgres in the
`production` or `staging` Rails environment without setting the variable. The fix is one line of
config, and the error names itself — which is the trade: a loud failure you fix once, instead of a
silent plaintext connection you never learn about.

### Rebuilding staging costs a Let's Encrypt issuance, and there are only five a week

The custom-domain cert lives in exactly one place: on the droplet, pushed there by
[`domain-cert-staging`](/operate/deploying/#custom-domain-https-over-the-tailnet). A
`recreate_droplet` rebuild destroys the box, and with it the cert — so the chained cert job has to
issue a **fresh** one every single time. Let's Encrypt allows five certificates per exact set of
identifiers per 168 hours. The sixth rebuild in a week gets:

```text
acme: error: 429 :: urn:ietf:params:acme:error:rateLimited :: too many certificates (5) already
issued for this exact set of identifiers in the last 168h0m0s
```

Nothing about the droplet is wrong when this happens: cloud-init ran, Kamal deployed, the app answers
on the tailnet, and the `domain -> tailnet IP` A record is updated (the script upserts DNS *before* it
touches ACME). What is missing is TLS — `https://staging.zimmer.tadasant.com` fails to handshake until
the window rolls forward and `domain-cert-staging` is re-run. Reach the box by tailnet IP or MagicDNS
in the meantime.

So rebuilds are cheap, but not free: the fifth one in a week is the last that gets a cert. If you
expect several in a day — chasing a cloud-init change, say — count them.

### Double-suffixed Redis URL (fixed, but the sharp edge remains)

`production.rb` builds the cache store as `"#{ENV["REDIS_URL"]}/0"`, so a `REDIS_URL` that already ends
in a database index becomes `redis://…:6379/0/0`. The old compose stack set `redis://redis:6379/0` and
hit exactly that.

`config/deploy.yml` now sets `REDIS_URL: redis://zimmer-redis:6379` — **no trailing `/0`** — so the
app's own suffixing produces a single, correct index. The trap is still there for anyone who
"helpfully" adds the `/0` back. ([#20](https://github.com/tadasant/zimmer/issues/20))

### `claude update` still runs in the background at boot — the spawn path just waits for it now

`bin/docker-entrypoint` backgrounds `claude update` and the Playwright browser install, because
running them in the foreground would hold Rails behind a 30s+ network operation until Kamal's
health check gave up. It now writes a readiness marker when that block finishes, and the spawn
path [waits on it](/sessions/spawning/#the-boot-tasks-readiness-gate) before launching a CLI.

What is left is the deliberate escape hatch. The wait is bounded by
`ZIMMER_BOOT_TASKS_TIMEOUT_SECONDS` (default 120, measured from process start), so if
`claude update` hangs, sessions spawn against whatever CLI is on disk rather than deadlocking the
worker. That case is loud — a warning in the session's own log and in the process log — but it is
still a session running on the previous deploy's CLI. Recovery respawns driven by
`ProcessLifecycleManager#handle_exit` (SIGTERM retry, context-length compaction) do not re-check
the gate; they only happen after a spawn that did.

Fixed in [#122](https://github.com/tadasant/zimmer/issues/122), which added the readiness gate. The
escape hatch above is what that fix deliberately left open.

### The tailnet reaper still no-ops without credentials — it just says so now

`scripts/tailnet-reap-node.sh` skips cleanup when `TS_API_CLIENT_ID` / `TS_API_CLIENT_SECRET` are
unset, so the MagicDNS name drifts to `zimmer-staging-1`, `-2`, … The health check compensates by
trying every online peer with that name — so it works, and you accumulate dead nodes. What changed is
the silence: the script now emits `::warning::` annotations naming the drift and the two secrets that
would stop it, on the unset path and on a failed token exchange alike.

Fixed in [#123](https://github.com/tadasant/zimmer/issues/123).

### The CI-failure alert can't be exercised from a PR

`alert-ci-failure.yml` posts main-branch CI failures to Slack. `workflow_run` only ever triggers
from the copy of the file on the **default branch**, so the listener cannot be exercised from a PR:
editing it on a branch changes nothing until it merges, and the first real proof that it fires is
the first failure on `main` afterwards. `workflow_dispatch` is wired up on it to cover the other
half — that Slack delivery itself works — without waiting for a genuine breakage.

Its `name:` is also load-bearing. `workflows: ["*"]` matches *every* workflow in the repo, including
the alert itself, so the job's `if:` excludes it by comparing against the literal string
`'CI failure alert'`. **Rename the workflow without updating that literal and it starts alerting on
itself.** (The literal is deliberate: `github.workflow` would be the tidier-looking test, but if it
ever resolved to the *triggering* workflow's name the test would become `A != A` and the alert would
silently stop firing forever. A loud failure beats a silent one.)

### A queued run that never starts is never alerted on

`alert-ci-failure.yml` fires on an allowlist of conclusions (`failure`, `startup_failure`,
`timed_out`) rather than on "not `success`", because `ci.yml` sets `cancel-in-progress` and a
*cancelled* run must not page anyone.

That leaves one real hole. If the shared self-hosted runner pool goes **offline**, main-branch runs
don't fail — they queue, and GitHub cancels them after ~24h with `conclusion: cancelled`, which is
the same conclusion a deliberate cancel produces. So the alert is silent for exactly the outage it
is most often imagined to cover. Running the alert job on `ubuntu-latest` protects against a
*degraded* pool (jobs run, jobs fail, the alert goes out), not an absent one. Noticing that CI has
gone quiet is still a human job.

### The GitHub trigger-poll liveness alarm depends on Redis, and fails quiet

`GithubTriggerHealthCheckJob` decides whether polling has stalled by reading a heartbeat the poller
writes to `Rails.cache` (Redis). When the heartbeat is **missing** — a cache flush, a Redis outage,
or a gap longer than `HEARTBEAT_TTL` (7 days) — the check cannot date the absence, so it seeds a
fresh baseline and stays quiet rather than paging on something it can't distinguish from a first
boot. A genuine stall is still caught one cycle later (the seed itself goes stale and the next check
pages), but a Redis outage silences the alarm for as long as it lasts.

This is the conservative trade: the alternative — paging on any missing key — turns every deploy and
cache flush into a false page, and a liveness alarm nobody trusts is worse than one with a known
hole. It fails quiet, not loud. The same Redis dependency already underlies `AlertService`'s dedup
and `SystemHealthMonitorJob`'s streak, so a Redis outage degrades that whole family together.

---

## Security

### The web UI has no login, by design (and the sharp edge that follows)

🔴 No login screen is deliberate. For a [single circle of trust](/intro/philosophy/), the network
perimeter is the authentication boundary (see [Auth overview](/auth/overview/)), so `ApplicationController`
has no `before_action` for auth and there are no login routes or `User` model. Zimmer's own Terraform
puts the app on a Tailscale tailnet with port 80 closed at the DigitalOcean firewall.

The sharp edge is real and load-bearing. Expose port 80 and, for most of the app, there is no second
wall: an anonymous visitor gets every session transcript, `/settings`, `/quotas` (including the OAuth
login flow), and the GoodJob dashboard.

The `/supervisor` Administrate panel is the exception, and the reason is its blast radius — it renders
`claude_accounts` (whose `oauth_config` JSONB holds plaintext Anthropic and OpenAI access and refresh
tokens), `mcp_oauth_credentials`, `x_oauth_credentials`, and `runtime_login_attempts` as *editable*
resources. It now sits behind an HTTP Basic realm keyed on `SUPERVISOR_PASSWORD` (with an optional
`SUPERVISOR_USERNAME`, default `supervisor`), compared in constant time, and it **fails closed**: with
the variable unset or blank, every dashboard returns 401 and the refusal is logged. An unconfigured deployment gets no panel rather than an
open one.

Two things that follow, in both directions:

- **You have to set the variable to use the panel at all**, including on a fresh deploy and on any
  existing deployment that has not seeded it. Until then `/supervisor` is 401 for you too.
- **One shared credential in front of one panel is not a login system.** It does not protect the rest
  of the app, it has no identity or audit trail, and rotating it requires a restart — the same
  shape as `API_KEYS`. The perimeter is still the security model.

There is no per-user authorization in `sessions_controller.rb`, and that is the design rather than a
gap: no `User` model, no owner column, nothing for a policy object to compare. The six
`# TODO: Add proper authorization checks` comments that used to imply otherwise are now a single
explicit note at the top of the class explaining why there is nothing to check.

Fixed in [#42](https://github.com/tadasant/zimmer/issues/42) — the panel is behind the Basic realm —
and [#44](https://github.com/tadasant/zimmer/issues/44), which replaced the authorization TODOs with
the note. What is above is the perimeter model itself, which no issue is open against.

### Nothing is encrypted at rest

🔴 Uniform trust means Zimmer leans on the perimeter rather than field-level encryption. No model declares
`encrypts`, no `active_record.encryption` config exists, and every OAuth token, client secret, and PKCE
verifier is a plaintext column. `XOauthCredential`'s own header says the quiet part: *"Security relies on
database access controls."* The admin panel that renders those columns is now behind a Basic realm, which
means a broken perimeter no longer exposes them in one click — but the columns are still plaintext, and
anything with database access reads them.

Tracked in [#43](https://github.com/tadasant/zimmer/issues/43).

### The elicitation endpoints are unauthenticated

`POST /api/v1/elicitations` and `GET /api/v1/elicitations/:id` skip the API key (required by the MCP
fallback protocol — the child process has no key). Anyone who can reach the host can create an
elicitation for any session id, or enumerate and poll any elicitation by `request_id`.

Tracked in [#45](https://github.com/tadasant/zimmer/issues/45).

### API keys have no scope, identity, or audit trail

Opaque strings from `ENV["API_KEYS"]`, memoized per request. Any valid key can do anything to anything.
Rotation requires a restart. No record of which key did what.

Tracked in [#46](https://github.com/tadasant/zimmer/issues/46).

### Agents run unsandboxed on the app host

Agents run as the app user, on the app host, with the app's git and `gh` credentials, spawned with
`--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox`. There is no sandbox,
and nothing in the product offers one.

Zimmer used to *say* otherwise. `Session::EXECUTION_PROVIDERS` accepted `remote_sandbox`, the MCP
`start_session` tool listed it in its enum and described it as "runs in isolated sandbox," and the
REST API docs repeated the pair. The provider behind the name
(`lib/execution/providers/remote_sandbox.rb`) is a stub: every method returns
`Result.failure("not yet implemented")`. An agent reading the tool schema could reasonably have
picked it. So the advertisement is gone — `local_filesystem` is the only accepted value and anything
else is a `422`. That removes the false claim; it does not add a sandbox.

Building one is a real project — a new runner, new images, credential brokering, cloud provisioning
— and it is backlog, not in flight. `lib/execution/` still holds the stub and its provider
abstraction, unwired from `app/`; whether to build against that seam or delete it is
[#172](https://github.com/tadasant/zimmer/issues/172).

Fixed in [#49](https://github.com/tadasant/zimmer/issues/49) as far as a fix goes here: the false
advertisement is gone. The live remainder is #172, above.

### Anyone in the workspace can trigger an agent via bot-mention, by default

The hardcoded allowlist is gone ([#52](https://github.com/tadasant/zimmer/issues/52) — it held two
Slack user IDs from a *different* workspace, so a fresh install ignored everyone, including its
owner). The default is now open: with `SLACK_BOT_MENTION_ALLOWED_USER_IDS` unset, any workspace
member who @mentions the bot in a channel it's in, or DMs it, can spawn an agent session.

That is deliberate — an unconfigured Zimmer should answer its owner — and it is bounded by the bot
only seeing channels it has been invited to. But it is a real grant, and it composes badly with the
next item (untrusted Slack text reaching the prompt). Set the allowlist
(`SLACK_BOT_MENTION_ALLOWED_USER_IDS`, comma-separated user IDs, in `mcp_secrets` or ENV) on any
workspace bigger than your circle of trust; a per-condition `allowed_user_ids` overrides it.

The same allowlist governs the passive-listening types, where the open default is a **wider** grant.
Under `bot_mention` the practical bound is "somebody had to type `<@bot>`". Under
`passive_listen_thread` it is only "Zimmer has spoken in this thread", and under
`passive_listen_channel` only "Zimmer posted in this channel in the last 6 hours". Set the allowlist
before enabling an all-channel passive condition on a workspace wider than your circle of trust.

### Triggers make the agent a trusted courier for untrusted input

[Issue #18](https://github.com/tadasant/zimmer/issues/18): there is nothing between "Slack event
arrived" and "agent running" except a `gsub` on a `prompt_template`. Untrusted Slack text is
interpolated into the prompt, and the agent is then trusted to act on identifiers it read out of that
text. No validation, no trusted identifiers.

Tracked in [#50](https://github.com/tadasant/zimmer/issues/50).

### A trigger cannot spawn a session with zero MCP servers

The three surfaces that create a session against a root directly — MCP `start_session`, `POST
/api/v1/sessions`, and the new-session form — distinguish an omitted `mcp_servers` (take the root's
defaults) from an explicit `[]` (take none). `Session.create_from_agent_root!` does not: `nil` and
`[]` both inherit the root's defaults there.

That is deliberate, not an oversight. `create_from_agent_root!` is what the dashboard quick prompt,
the chat bubble, and every [trigger](/sessions/triggers/) spawn through, and a `Trigger`'s
`mcp_servers` column is `default: [], null: false` — so `[]` is what an untouched trigger stores, not
a request for none. Reading it as "no servers" would silently strip the servers from every existing
trigger at once.

The consequence is that a trigger whose root carries privileged defaults always spawns with them.
There is no way to configure a least-privilege trigger short of giving its root narrower defaults, or
having the spawned session clear its own list with `change_mcp_servers` after it starts — which is
after the servers have already been wired for that run.

---

## Agent harness

### Failure classification is regex against CLI prose

🔴 Everything Zimmer knows about *why* a session died comes from string-matching English:

| What | Pattern | File |
| --- | --- | --- |
| Quota exhausted → rotate accounts, then park | `/hit your\b.*\blimit\b.*\bresets\b/i` | `api_error_retry_service.rb:116` |
| Auth lost → adopt/rotate/wait, respawn, then park | `/not logged in\|please run\s*\/login/i` | `auth_recovery_service.rb` |
| Context overflow → compact and retry | a pattern list | `context_length_retry_service.rb:44` |
| Corrupted npx cache → delete it | `ENOTEMPTY`, `ERR_UNSUPPORTED_DIR_IMPORT` | `npx_cache_heal_service.rb:75` |

This has already caused an outage. When Claude Code's wording changed, account rotation stopped firing:
the session fell through to the transient-rate-limit path, retried six times against an already-capped
account, and failed, with no log line saying rotation should have happened.

The matching is still prose-based — that part has not changed, and a *mis*match (prose that hits the
wrong pattern, as in that outage) still looks like an ordinary classification. What no longer happens
silently is a **no**-match: when a session dies and not one classifier recognized it,
`UnclassifiedFailureReporter` logs loudly and pages `#eng-alerts` with the unmatched stderr and
transcript text, so the next wording change surfaces as a Slack message rather than an
archaeology session. The same reporter fires when a classifier and its recovery service disagree
about the same exit.

Two gaps remain inside that, deliberately. The reporter sits on the *failure* branch, so an
unrecognized error on a Claude exit 0 or 1 — which `normal_completion_exit?` reads as a finished
turn — still reaches `needs_input` without a word. And `CodexRetryStrategy` classifies nothing but
a missing rollout, so every ordinary Codex failure is by construction an exit no classifier
matched; it answers `classifies_exits? => false` and gets the loud log without a page, because
paging on a runtime's designed-for path is how a channel gets ignored.

Tracked in [#53](https://github.com/tadasant/zimmer/issues/53).

### Auth recovery can rotate away from an account that was fine

🟡 `AuthRecoveryCoordinator` reacts to the runtime saying "Not logged in" by moving the pool — it
rotates away from the identity that failed rather than re-injecting it (that re-injection loop is
what made the message user-visible three times in a row; see
[Agent harness auth](/auth/harness/#the-recovery-decision-tree)). But "Not logged in" carries no
structured reason, so the coordinator cannot always know *why* the identity failed.

It probes the outgoing account's refresh token before rotating, which separates a dead credential
(`needs_reauth`) from a live one (`quota_exceeded`), and that is enough to get the **park reason**
right. It is not enough to distinguish "over quota" from "a transient rejection Anthropic would have
served on the next call". In the latter case the account is marked `quota_exceeded` and leaves the
pool until `QuotaResetCheckerJob`'s next sweep sees its snapshot is clear and restores it — up to
15 minutes of a healthy account sitting out.

That is the deliberate trade: an unnecessary rotation costs one account for one sweep, whereas
re-injecting a dead identity costs the user three visible auth failures and a park with the wrong
instruction. Worth revisiting if Anthropic ever exposes a structured reason.

### An Anthropic outage makes the account probes inconclusive, and they promote anyway

🟡 Bootstrap, rotation and the UI login flow all validate an account before promoting it by probing
Anthropic with its access token (`QuotaCheckService.token_rejected?`, see
[Bootstrap validates before it promotes](/auth/harness/#bootstrap-validates-before-it-promotes)).
The probe distinguishes three answers, and only *Anthropic answered and refused* condemns an account.
A probe that never reached Anthropic — timeout, DNS failure, 5xx — is treated as no evidence, and the
candidate is promoted unvalidated.

That is the deliberate direction. The alternative reads a provider outage as "every credential in the
pool is dead" and parks every session at once, which is a worse and much less recoverable failure than
promoting one account that may or may not work. The consequence to know about: during an Anthropic
outage, bootstrap gives you exactly the behaviour it had before this validation existed.

The same asymmetry applies to `ClaudeLoginDriver#capture!` — a login completed while Anthropic is
unreachable is stored rather than thrown away.

### A capped account is marked from whichever reading happens to arrive first

🟡 An account leaves the pool when a quota reading says its weekly window is spent
([#248](https://github.com/tadasant/zimmer/issues/248)) — and readings arrive from unrelated places:
a rotation snapshot, a `/quotas` page view, the 15-minute reset checker. So *when* a capped account
gets marked depends on when someone last looked at it, not on when it filled its window. An idle pool
that nobody has probed can still hand out an account whose week ran out an hour ago; rotation's own
pick-time check only fires on evidence that already exists.

The floor is `QuotaResetCheckerJob`'s 15-minute sweep, which probes `quota_exceeded` accounts — but
not `active` ones. The two paths that actually hand an account to a session close the gap for
themselves: bootstrap probes each candidate live before promoting it, and rotation snapshots the
account it activates. What is left is the window in between, where `/quotas` can show an account as
healthy on evidence that has gone stale. Making that deterministic would mean probing every active
account on a schedule, which costs a request per account per sweep for a condition the paths that
matter already check at the moment they matter.

### The quotas page can hold row-lock transactions across a token endpoint call

🟡 `ClaudeAccount#refresh_token!` serializes on the account row and keeps that lock for the whole
read-refresh-persist sequence, HTTP included (see
[Refreshing a token without burning it](/auth/harness/#refreshing-a-token-without-burning-it)). That
is what makes the token it presents provably the token it holds, and it was already the shape of the
5-minute sweep, which wrapped each refresh in `account.with_lock` before this.

What is new is that the same lock now applies on the **web** tier. `QuotasController` refreshes to
validate an account before switching, and its probe can call `refresh_token!` more than once per
account per render — so rendering `/quotas` while Anthropic's token endpoint is slow holds a
sequence of transactions, each up to the 5s-open/10s-read timeout, on a Puma thread.

Tolerable because the page is operator-facing and rarely loaded, and because the alternative — an
unserialized refresh — is the bug that drained the pool. If it becomes a problem the fix is a
`lock_timeout` on the refresh path rather than dropping the lock.

### A stale spawn identity can cost one extra respawn

🟡 `metadata["auth_identity_email"]` is what
[the recovery decision tree](/auth/harness/#the-recovery-decision-tree) compares against the pool's
current account to tell *the pool moved under me* from *I am holding the identity that failed*. It is
written per session — at spawn, and whenever the coordinator or the quota path moves that session —
so it goes stale when the pool moves for a reason this session was not part of: another session's
rotation, or an operator switching accounts from the quotas page.

A session whose record says account A, and which has since been running on account B, will read a
genuine "Not logged in" from B as *the pool already moved off A* and adopt B — the identity it was
already using. It re-spawns once into the same wall.

It self-corrects rather than looping: adopting rewrites the record to B, so the next failure takes
the rotate branch for real. The cost is one wasted respawn and one misleading log line, against a
prior behaviour of three. The rotation-collapse path avoids the same trap with a recency gate
(`AccountRotationService::COLLAPSE_WINDOW`, 60s) — a rotation older than that is the account the
caller has been living with, not a stampede to ride.

### A rotation that wedges makes other sessions wait, then guess

🟡 The pool lock (`ClaudeAccount.with_pool_lock`) is a session-level Postgres advisory lock, so it
is released if the holder's connection drops — a crashed worker cannot deadlock the pool. A holder
that is *alive but stuck* (a hung HTTP token refresh, say) is different: other sessions wait
`POOL_LOCK_WAIT` (45 s), then give up and take the `rotation_in_flight` branch, which re-spawns
against whatever credentials are on disk and charges an attempt. That is the right guess most of the
time — the stuck holder is mid-rotation and its credential write has probably landed — but it is a
guess, and three of them exhaust the session's budget and park it.

There is no visibility into *which* session holds the lock; the only signal is the
`"Pool lock held past the wait"` warning in the waiting session's logs.

### A parked session retries forever, once an hour

🟡 When the login pool runs dry, `AuthOutageParkService` parks the session and schedules a wake-up
(see [Agent harness auth](/auth/harness/#when-the-pool-runs-dry)). If the outage has *not* cleared by
then, the woken session hits the same wall and parks again. There is no cap on park cycles, so a
genuinely dead account pool produces a wake → fail → re-park cycle indefinitely, each with its own
push notification and a fresh `Trigger` row (reaped an hour after its scheduled time by
`CleanupStaleTriggersJob`). The cycle is hourly for an auth outage; for a quota outage it is however
long the derived reset says, floored at five minutes.

That is deliberate — the alternative is a terminal `failed` that no longer recovers when a human
finally re-authenticates — but it means a long outage is noisy rather than silent. The signal that
someone must intervene is the repetition itself, not a distinct state.

Two related sharp edges:

- The retry time is only derived from real reset data for a **quota** outage, and only for Claude:
  it reads `ClaudeAccountQuotaSnapshot#reset_5h` / `reset_7d`. An auth outage (a rejected identity)
  has no published reset clock at all, so it falls back to a blind `DEFAULT_RETRY_DELAY` of one hour.
- Codex has no quota API, so a parked Codex session always gets that same blind hour.
- The early wake that saves an auth park from that hour is only as good as its evidence, and the
  evidence is coarse in both directions. It cannot see an outage that heals on Anthropic's side
  without touching an account row — that one still waits out the timer. And it fires on credential
  changes that are not repairs at all: the five-minute `sync_current_account_tokens!` adopting a
  token the CLI rotated on disk moves the same digest. The budget is what makes that survivable
  rather than exact — `MAX_EARLY_WAKES` (3) per `EARLY_WAKE_WINDOW` (6 h), deliberately not reset by
  a re-park — so a session broken for a reason of its own can still burn three wakes in 45 minutes
  and spend the rest of that window on the hourly timer.

### `CodexRetryStrategy` classifies almost nothing

🔴 It returns `false` from `context_length_error?`, `api_error_for_retry?`, and
`auth_recovery_needed?`, and only matches `/no rollout found/i`. Exit 0 is treated as success.

For a Codex session that means: no context-length compaction retry, no API-error retry, no quota
rotation, and no auth recovery. Everything the Claude path does to keep a session alive, Codex does
without.

Tracked in [#54](https://github.com/tadasant/zimmer/issues/54).

### A fresh-started Codex session has no runtime id until its first poll

After a failed resume, `ProcessLifecycleManager#release_stale_runtime_session_id!` clears
`sessions.session_id` so transcript polling stops chasing the abandoned rollout. Codex mints the
replacement UUID itself, and Zimmer only learns it when `capture_runtime_session_id!` reads it off
the new rollout — a window of one poll interval where the session has no runtime id at all.

Inside that window `is_resume` is forced false (`AgentSessionJob` requires `session_id.present?`),
so a follow-up arriving right then spawns fresh and carries its prompt instead of resuming. That is
the correct degradation — a resume with no target cannot work — but it is a turn that restarts
rather than continues, and the user sees the prompt replayed in the timeline.

Reattachment also depends on `CodexTranscriptSource#fallback_transcript` matching the rollout's
recorded `cwd` against the session's `working_directory`. A session whose clone moves in the same
window has no way to find its own rollout and waits until one appears.

### The approval gate can only be verified as far as Zimmer's own doorstep

`CliSpawnEnv#apply_elicitation_env` gives both runtimes `ELICITATION_REQUEST_URL` and
`ELICITATION_SESSION_ID`, and `ElicitationEndpointHealthCheckJob` proves
every 5 minutes that the endpoint answers from the host agents run on. Neither proves that a given
MCP server *used* those variables: a server that hard-codes its own URL, or one already running from
before the change, still posts into the void and still returns a redacted value. What is guaranteed
now is that the failure is not silent on Zimmer's side — the system prompt of every session spawned
while the gate is down says so, so a redaction is never read as a policy decision. A session already
running when the gate breaks reads the status from its spawn and will not learn of it.

Fixed in [#55](https://github.com/tadasant/zimmer/issues/55). What survives is the edge of what Zimmer
can verify from its own side, which no issue closes.

### Extension env contributions are unreachable from Codex

`Zimmer::ExtensionRegistry.spawn_env_contributions` is called only from `ClaudeSpawnEnv` — despite the hook
receiving a `runtime` context that implies it's generic.

Tracked in [#54](https://github.com/tadasant/zimmer/issues/54).

### Shared code still says "Claude"

`SubagentTranscript#open_transcript_events` hardcodes `ClaudeTranscriptNormalizer`.

`TranscriptPollerService`'s waiting log now names the session's own runtime via
`RuntimeRegistry.label_for`, so it no longer tells a Codex session to wait on the Claude CLI.

Tracked in [#54](https://github.com/tadasant/zimmer/issues/54).

### The login flow screen-scrapes a TUI

Hardcoded: the command (`claude auth login --claudeai`), the authorize-URL host regex, the literal
prompt `/Paste code here/i`, and the binary path `/home/rails/.local/bin/claude`. Codex likewise, with a
device-code regex tuned to an *observed* 4–5 character split.

Tracked in [#58](https://github.com/tadasant/zimmer/issues/58).

### A timed-out headless `claude -p` child gets ~2 seconds to die, then it is the reaper's problem

`NativeClaudePrintRunner` — the default print-mode backend, behind `SessionTitleJob` and
`SendPushNotificationJob` — reaps its child after a timeout, but on a bound: poll
`wait(pid, WNOHANG)` for `REAP_WINDOW` after SIGTERM, escalate to SIGKILL, poll once more. That bound
is deliberate — the reap runs after the run's own `Timeout` budget is spent, and a blocking wait on a
child that ignores SIGTERM would hang a GoodJob worker thread. The cost is that a child which
survives SIGKILL (uninterruptible sleep, say) is left uncollected until `ZombieReaperJob`'s next
tick, with a WARN naming the pid. The windows are the caller's latency: a timed-out call whose child
dies on SIGTERM returns immediately, one that has to escalate costs about a second more, and one that
answers neither signal costs about two.

The `pty_transport` extension substitutes its own print runner, which this teardown path does not
cover.

---

## Claude Code OAuth (inherited assumptions)

Zimmer automates OAuth on top of Claude Code's undocumented internal implementation. Every item here
is a fact about someone else's private code that can change without notice. Last verified against CLI
`2.1.177` on 2026-06-14 — as of this writing, that's stale.

1. Identity is container-local; tokens are shared. `~/.claude.json` (identity) vs
   `~/.claude/.credentials.json` (tokens). Code that reads local identity to decide who owns shared
   tokens *"gets a confidently wrong answer"* on the wrong container. This caused the 2026-06-11
   cross-account contamination outage. Worked around with an owner-marker file, not fixed.
2. `oauthAccount` has two shapes across CLI versions (String vs Hash). Both must be handled.
3. Hardcoded constants: token endpoint, the CLI's public client ID `9d1c250a-…`, authorize hosts,
   redirect URI, scopes, PKCE method. If any change, refresh and login break wholesale.
4. Refresh tokens are single-use and rotate. The new pair must be persisted atomically or the account
   bricks.
5. Rotating also kills the sibling access token, so a future `expiresAt` is *not* proof a token is
   live. Zimmer's `token_expired?` still keys purely off `expiresAt`; the defense is the completeness
   invariant, not expiry logic.
6. A credential set without a refresh token is unrecoverable.
7. The CLI refreshes tokens on its own, mid-session, writing to the shared file without telling
   Zimmer. Zimmer must scrape them back or its DB copy goes stale and the next refresh `invalid_grant`s.
8. The CLI sometimes rewrites `.credentials.json` with no `claudeAiOauth` block at all. Adopting it
   blindly would brick the pool.
9. Token lifetime ~8h — inferred, not specified.

Tracked in [#58](https://github.com/tadasant/zimmer/issues/58). None of this can be *fixed* — there is
no public API to fix it against — so the issue asks for a canary that fails loudly when one of these
facts stops being true.

---

## MCP

### Codex MCP credentials are a reverse-engineered format, written on every spawn

`CodexMcpCredentialWriter` exists entirely to work around two open upstream Codex bugs
([#15122](https://github.com/openai/codex/issues/15122),
[#17265](https://github.com/openai/codex/issues/17265)). Its format was read out of
`codex-rs/rmcp-client/src/oauth.rs @ rust-v0.133.0`, and it writes two mutually incompatible schemas
(file vs macOS Keychain). The Keychain path has never been runtime-verified — all workers are Linux.

Tracked in [#63](https://github.com/tadasant/zimmer/issues/63).

### The Claude credential-key algorithm is a string copy of a private internal

`McpOauthCredential.compute_credential_key` replicates Claude Code's `server|SHA256(compact_json)[0,16]`
key format, including string-munging `": "` → `":"` to fake compact JSON. If Claude Code changes it,
every stored credential becomes unfindable — and the symptom is "the agent says it needs authorization,"
not an error.

A canary test in `test/models/mcp_oauth_credential_test.rb` pins the literal key for two fixed server
configs, so a change to Zimmer's side of the algorithm fails loudly and names the hashed preimage.
It cannot detect the other direction: if Claude Code changes *its* algorithm, the canary stays green
and lookups start missing.

Fixed in [#62](https://github.com/tadasant/zimmer/issues/62), which added that canary. The direction it
cannot cover is permanent — there is no public spec to pin the other side against.

### Codex MCP status reimplements a Rust function in Ruby

`CodexMcpStatusDetector` mirrors `codex-rs`'s `MCP_TOOL_NAME_DELIMITER = "__"` and its
`sanitize_responses_api_tool_name` character rules.

Tracked in [#63](https://github.com/tadasant/zimmer/issues/63).

### Servers without `offline_access` issue one-shot credentials

Scope acquisition just joins the server's advertised `scopes_supported`. No `offline_access` ⇒ no refresh
token ⇒ the credential is single-use and dies with no way to refresh, and Zimmer does not ask for a scope
the server did not advertise.

What it no longer does is stay quiet about it. A token exchange that leaves no refresh token on the
credential sets `refresh_token_unsupported`, and the Connectors row says the credential cannot be
renewed and will need authorizing again — while the row is still green, rather than months later as an
unexplained re-auth. The chore is real; the surprise is not.

A re-authorization that omits a refresh token keeps the one already stored, and the flag is derived
from what survives the exchange rather than from the response alone — a server that mints a refresh
token on first consent and omits it when re-authorizing a live grant stays renewable
([#309](https://github.com/tadasant/zimmer/issues/309)).

Tracked in [#64](https://github.com/tadasant/zimmer/issues/64).

### "Assume OAuth might be required"

`mcp_oauth_credential_injector.rb:137` — *"If we don't know if OAuth is required, assume it might be"* for
remote servers.

Tracked in [#103](https://github.com/tadasant/zimmer/issues/103).

### "Is this a credential header?" is a word list

🟡 `McpOauthCredentialInjector::CREDENTIAL_HEADER_PATTERN` decides whether a remote server
authenticates with a static header by looking at the header's *name*: `authorization`, `auth`,
`api-key`/`apikey`, `token`, `secret`, `password`, `credential(s)`, as whole `-`/`_`-delimited
parts. A vendor header spelled with none of those words — Azure's `X-Subscription-Key`, say —
is not recognized, and the server is classified OAuth-capable: the Connectors page offers an
Authorize button that no consent screen can satisfy, and the post-spawn classifier files its
401 as `oauth_required`. Adding the word is a one-line fix; the point is that nothing detects
the miss for you.

The list is deliberately narrow, because the opposite error is worse: a routine header read as
a credential (`Idempotency-Key`, had `key` counted on its own) hides the Authorize button on a
server that genuinely needs one, leaving no way to authorize it at all. There is no signal in
the catalog schema that would settle this outright — an explicit `auth` block per entry would,
and does not exist.

An exact two-name list (`Authorization`, `X-API-Key`) is what shipped before, and it is why the
`google-maps` entry's `X-Goog-Api-Key` rendered "Needs authorization" beside the very key that
authenticates it.

### The fallback `client_id` is the literal string `"zimmer"`

Used only when neither a statically-configured client id nor a DCR endpoint is available.
**Unclear / needs confirmation:** whether any real server accepts this.

Tracked in [#64](https://github.com/tadasant/zimmer/issues/64).

### A silently-rejected credential still has no re-auth path

To stop the dead "Authorize" button, a `401` from a server Zimmer already holds an `active` credential
for is treated as "the runtime didn't honor the injected token" — it clears the needs-auth cache and
retries rather than parking `oauth_required`. That is right for the common case (the host-global
needs-auth cache short-circuited the connection), and a provider that *says* the credential is dead
is now carved out: an error matching `REFRESH_TOKEN_REJECTED_PATTERN` (a `Token refresh failed with
<grant error>` / `Invalid refresh token` shape) retires the credential in both the DB and the runtime
store, and parks `oauth_required`.

What remains is the silent case: the server rejects the access token — revoked, or its scopes changed
— and reports only a bare `401` with no grant error, while the DB copy still looks `active` and the
runtime never attempts a refresh that would name the failure. That retries to the limit and lands in
`mcp_connection_failed` (raw error surfaced) with **no** Authorize button offered; the credential must
lapse or be deleted before re-authorization is presented again. The predicate is still
`McpOauthServerAuthorization.authorized?` (active credential exists), not "the server accepted it".

A runtime that phrases a rejected refresh differently than the pattern expects falls into this same
silent case. That is the deliberate direction to fail in — the alternative, matching a bare
`invalid_grant` anywhere in the error, retires a healthy credential whenever a server reports a
*downstream* provider's grant error, which is an unresolvable re-auth loop rather than a slow one.

---

## AIR catalog

### A dangling reference fails the entire test suite

🔴 AIR exits 0 when it drops an unresolvable reference. Zimmer's only detection is
string-matching AIR's stderr for `"references unknown"` + `"Dropping the reference"`.
`air_catalog_service.rb:23-39` is candid: *"a string copy, not a stable contract… brittle, but AIR
exposes no machine-readable signal."*

And because `test/test_helper.rb` pre-warms the catalog before `parallelize` forks, a single dangling
reference reddens every session-creating test at once. `CONTRIBUTING.md`: *"suspect the catalog before
your change."*

If AIR ever rewords that warning, Zimmer quietly starts accepting degraded catalogs.

Tracked in [#66](https://github.com/tadasant/zimmer/issues/66).

### The catalog-failure banner is per-process

Every config facade (`AgentRootsConfig`, `ServersConfig`, `SkillsConfig`, `HooksConfig`,
`PluginsConfig`, `ReferencesConfig`) rescues `CatalogError` to an empty array, so a catalog that
cannot resolve degrades the session form to empty pickers rather than a 500. On its own that made a
broken catalog look exactly like a fresh install with nothing configured
([#112](https://github.com/tadasant/zimmer/issues/112)). `AirCatalogService.resolve_failure` now
records every failed resolve — including the no-fallback case `degraded?` cannot see — and the
session form renders it as a banner.

`Mcp::Tools::GetConfigs` carries the same fact to agents, which read the catalog through those same
façades — but not the same detail. The banner prints `air resolve`'s stderr verbatim, and that process
is given `AIR_GITHUB_TOKEN`, so the MCP surface reports only *that* resolution failed and when. Same
fact, different fidelity, different audience.

The residual limit: that flag is process-local, like the rest of the in-memory catalog cache. It
describes what *this* web process last saw. With more than one web process, a form served by a worker
that has not yet retried shows the banner while its neighbour does not — the pickers and the banner
are at least always consistent with each other, because both come from the same process's cache.

### A missing artifact body is invisible until `air prepare`

AIR validates references *between* entries but never checks that a `path` exists on disk. A
registered hook or skill with no body resolves clean, slips past Zimmer's stderr marker check, and is
silently skipped by the adapter with a warning nobody reads.

`git-push-ci-reminder` sat that way for a while — registered in `hooks/hooks.json`, bundled into the
`ci-workflow` plugin, `default_in_roots: ["agent-orchestrator"]`, and with no directory behind it
([#65](https://github.com/tadasant/zimmer/issues/65)). The body exists now, and the test suites for
`SkillsConfig` and `HooksConfig` assert every registered artifact really has one — but that is a
Zimmer-side test, not something AIR enforces.

### The environment configs describe a catalog that no longer exists

`production.rb` and `staging.rb` comments say `air.production.json` *"uses `github://` URIs to pull from
tadasant/zimmer-catalog."* It doesn't — it's entirely local paths. All of `AirCatalogService`'s
github-cache machinery (catalog pins, `resolved_sha_for`, `pinnable_catalogs`) is dormant
infrastructure, and its tests skip themselves.

Tracked in [#69](https://github.com/tadasant/zimmer/issues/69).

### A background thread inside Puma, to fix a container mismatch

`~/.air/cache` is per-container, and the `*/15` refresh cron runs only in the worker — so the web
container's catalog would drift stale for a full deploy cycle. `PeriodicCatalogRefresher` runs a bespoke
background thread *inside Puma* every 300s to compensate.

Tracked in [#98](https://github.com/tadasant/zimmer/issues/98).

### The AIR CLI version is pinned in two places, and the catalog config in two files

`Dockerfile.base` bakes `@pulsemcp/air-cli@0.13.0` (plus four adapters, plus a `.air-version-<v>`
marker); `AirPrepareService::AIR_CLI_VERSION` is the version the app looks for. Separately, `air.json`
(dev/test) and `air.production.json` (in-image) declare the same six sources and differ only in their
`description`. Both pairs are still kept in step by hand — the duplication is real.

What changed is that drift now fails a test rather than a deploy: `test/contracts/air_config_parity_test.rb`
asserts every `@pulsemcp/air-*` pin and the version marker match `AIR_CLI_VERSION`, and that the two
catalog configs are identical outside `description`. A mismatched marker would otherwise make every
fresh container throw away its baked-in AIR install and re-download the CLI on a session's launch path.

Fixed in [#68](https://github.com/tadasant/zimmer/issues/68), which added that parity test. The
duplication above is what the test guards rather than removes.

### Five roots point at a different repository

`agent-orchestrator`, `agents`, `catalog-management`, and the four `catalog-mgmt-*` phases all have
`"url": "https://github.com/tadasant/zimmer-catalog.git"` — a separate repo not part of this project.
`agent-orchestrator` also has `display_name: "Zimmer"`, the same as the `zimmer` root, making them
indistinguishable in a picker. That looks like a bug.

Tracked in [#67](https://github.com/tadasant/zimmer/issues/67).

### The baseline `zimmer-router` root can't spawn downstream sessions out of the box

🔴 `zimmer-router` — the root behind every quick-router / chat-bubble submission — ships with **no**
default artifacts: no routing skill, and no session-orchestration MCP server. It resolves and starts,
but it cannot *route*. A quick-router submission therefore lands as an ordinary agent session cloning
`tadasant/zimmer` at its root, which is rarely what the prompt asked for. Treat the quick router as
"start a session from a prompt", not "dispatch to the right root", until this is finished.

The obvious wiring — `default_in_roots: ["zimmer-router"]` on the `zimmer-sessions` catalog entry —
is deliberately **not** done, because it is unsafe for a stock deployment. `zimmer-sessions`' URL in
the **in-image** catalog is the placeholder `https://zimmer.example.com/...` (only its `X-API-Key`
header is a `${VAR}`, so `SecretsInterpolator` never rewrites the host), and
`RuntimeConfigPostProcessor#retarget_zimmer_servers_to_current_env!` early-returns in production
(`return if Rails.env.production?`). Dev and staging rewrite that placeholder to the instance's real
`ZIMMER_*_BASE_URL`; a **production** instance running the in-image catalog does not, so its router
sessions would dial a dead host and — after `MAX_MCP_CONNECTION_RETRIES` — be failed outright
(`AgentSessionJob` → `session.fail!`).

That prod no-op is only sound under the assumption written into its own comment: that production
"already point[s] at the instance serving the session" — true for an instance running its **own**
catalog via `AIR_CONFIG` (see [Pointing an instance at your own catalog](/air/artifacts/#pointing-an-instance-at-your-own-catalog)),
false for one running the in-image fallback. Both configurations exist, so the safe default is to ship
no session server at all.

The auto-injected `zimmer-self-session` server is unaffected either way: `SelfSessionInjector` builds
its URL from `ZIMMER_*_BASE_URL` directly rather than from the catalog. To give the router real
dispatch, an operator must wire a session-scoped Zimmer MCP server whose URL resolves in *their*
environment — a custom `AIR_CONFIG` catalog with real URLs, or lifting the prod retarget no-op. See
`app/services/runtime_config_post_processor.rb` and `app/services/self_session_injector.rb`.

### `zimmer`, `general-agent`, and `zimmer-router` are indistinguishable to the reverse lookup

All three have `"url": "https://github.com/tadasant/zimmer.git"` and no `subdirectory`.
`AgentRootsConfig#find_for_session` prefers `metadata["agent_root_key"]`, but its fallback matches on
`(url, subdirectory)` and returns the first hit — `zimmer`. Sessions created through
`create_from_agent_root!` (which includes every quick-router session) always carry the key, so this is
latent rather than live; but a key-less session, or `Trigger#heal_stale_agent_root!`, will resolve any
of the three to `zimmer`. Same root cause as [#67](https://github.com/tadasant/zimmer/issues/67).

---

## Sessions

### 🔴 Every turn a session finishes costs a second agent turn, for the Status summary

The [Status summary](/sessions/status-summary/) is generated by **forking the session** — copying its
clone directory and running one more agent turn against the copy. The automatic trigger is the
session coming to rest, and every turn a session completes ends in exactly that transition. So on a
busy fleet the steady-state cost is roughly one extra agent turn and one extra repository copy **per
completed turn, per session**, until the fork is harvested and archived.

That is the design that was asked for, and the fork is what makes the summary specific enough to link
to a message index rather than paraphrase. But it is not a cheap feature, and there is no rate limit,
no minimum interval, and no off switch beyond not looking at it. `SessionStatusSummaryGenerator`
refuses only when the session has not moved since the last summary — which, on a turn boundary, it
always has.

Mitigations already in place: only resting transitions trigger it (a resume into `running` does not),
a generation already in flight is never duplicated, the copy leaves out installed-dependency trees
(`vendor/bundle`, `**/node_modules`) that the summarizer never uses, the fork is archived immediately
on harvest so the clone copy is reclaimed on the normal trash path, and rendering the panel or reading
the session over MCP/REST never generates.

### An interrupted clone delete still mangles a live working tree

Clone deletion — the archive/trash path, the pruning `CloneDiskGuard` triggers before a clone, and
the sweeps in `StaleCloneCleanupJob` and `OrphanCloneFilesystemCleanupJob` — is a plain recursive
`rm -rf` on the clone in place. If it starts on a tree that is still live and is interrupted partway
(a deploy, a SIGTERM, a session that turns out not to be dead), it leaves an arbitrary surviving
subset of the tree behind: files gone in readdir order, no marker, nothing that detects it. The
session whose clone that is keeps running against a tree with holes in it.

[Issue #411](https://github.com/tadasant/zimmer/issues/411) closed the two ways that spread — archive
no longer preserves the deletions as uncommitted work, and unarchive no longer replays a patch that
guts the fresh clone (see [the archive path](/sessions/lifecycle/)) — but the origin is untouched.
Making deletion atomic (rename the clone out of the way, then delete the renamed copy, so an
interrupt leaves either the whole tree or nothing) is tracked separately in
[#412](https://github.com/tadasant/zimmer/issues/412). Same family as
[#406](https://github.com/tadasant/zimmer/issues/406), the fork-side delete-race, and
[#410](https://github.com/tadasant/zimmer/issues/410), where an interrupted `BundleInstallJob` leaves
a clone permanently unusable.

It is not rare. On 2026-08-12, the day the guard shipped, it defused nine clones across nine
sessions in one afternoon, and a read-only scan of the production clones directory that evening
found 20 of 87 clones carrying a mass-deletion tree — both figures recorded in
[#415](https://github.com/tadasant/zimmer/issues/415). `MangledCloneReportJob` is what keeps that
number visible day to day.

### A session that deletes 50+ tracked files and nothing else loses those deletions on archive

The guard above separates corruption from work by shape: 50 or more deleted tracked files, and
deletions making up 95% or more of the patch. A session whose only uncommitted change is the deletion
of 50+ tracked files — "drop the vendored directory", "delete the obsolete fixtures" — has exactly
that shape, so archive drops those deletions from `working_tree.patch` and the files come back on
unarchive. The tolerance is narrow: a patch of 60 deletions needs 4 or more non-deletion entries to
stay out of the net, and one or two edits alongside the deletions are not enough.

What is lost is bounded — every dropped file still exists at `HEAD`, so `git rm` reproduces the work
in seconds — and it is not silent: the drop is logged at `.warn`, counted in the artifact metadata as
`dropped_deletions`, and stamped on the session as `mangled_clone_dropped_deletions`. Committing the
deletions before the session is archived avoids it entirely, since commits travel in the bundle
rather than the patch.

It is a `.warn` and not an `.error` because the archive-side refusal is self-healing, and paging for
each one buried the signal it was meant to carry: nine pages in one afternoon, for nine sessions that
all archived fine. The frequency is reported once a day in aggregate by `MangledCloneReportJob`
instead — see [Counting mangled clones](/operate/background-jobs/#counting-mangled-clones-without-paging-for-each-one).
The trade is deliberate: a session that legitimately deletes 50+ tracked files loses those deletions
with a warning rather than an alert, so nobody is told about *that* particular loss at the moment it
happens.

### A fork of a live clone is retried, so a fork that cannot be made now fails three times slower

`ForkSessionService` copies a clone that other processes are still writing to, and a file that
vanishes between enumeration and stat aborts the copy. That is retried — `COPY_RETRY_DELAYS` gives it
three attempts — which fixes the failure but multiplies the *failure* path: a copy that used to die
after one walk of the tree now walks it up to three times, plus 2.5 seconds of backoff, before giving
up.

The **user-initiated** fork paths (`SessionsController`, `Api::V1::SessionsController`, and the
`action_session` MCP tool) all run the fork synchronously inside the request, so a fork that cannot be
made holds a request thread for the whole of that and may hit a proxy timeout before it can return
"Failed to fork session". The budget is deliberately small for exactly this reason. Automatic
**summary** forks run in a GoodJob worker where the wait costs nothing but a thread, and they exclude
the dependency trees that make the copy slow in the first place.

The retry rides out a tree being *written to*, not a tree being *rebuilt*: a copy racing a
`bundle install` that runs for half a minute can exhaust all three attempts and still fail.

### A status-summary fork's clone is missing its installed dependencies, and does not know it

Summary forks exclude `vendor/bundle` and `**/node_modules` from the copy, because the summarizer
reads a conversation and never builds or boots anything. Two edges come with that:

- `.bundle/config` **is** copied, and it points `BUNDLE_PATH` at the `vendor/bundle` that is now
  absent, so any `bundle exec` or `bin/rails` inside a summary fork fails with "Could not find gem".
  The prompt tells the fork not to run tools, but that is an instruction, not a constraint.
- For a repository that *tracks* either directory in git (Zimmer's own does not), the pruned clone
  reads as dirty to `CloneArtifactService`, so `DeferredCloneCleanupJob` preserves artifacts and holds
  the clone for `TRASH_RETENTION_PERIOD` instead of deleting it immediately.

Neither affects a user-initiated fork, which copies the tree whole.

### Terminating a pid that is not this process's child falls back to a liveness check that lies

`ProcessTerminationService` answers "is this still running?" with a non-blocking `wait`, which reaps
as a side effect and so cannot be fooled by an exited child holding its own pid as a zombie. That
answer is only available for a pid that is a child of **the process doing the asking**. For anything
else `wait` raises `ECHILD` and the service falls back to `Process.kill(0, pid)`. That covers more
than third-party processes: a session spawned by a previous worker process, a restarted container, or
an earlier deploy is no longer anyone's child here, and recovering exactly those sessions is what
`SessionRecoveryService` exists to do.

Two things follow from that fallback. In a multi-container deploy each container has its own PID
namespace, so signal 0 reports `ESRCH` for a process that is running perfectly well next door —
`SessionRecoveryService` says so in its own header, and calls its `force_terminate_hung_process` path
best-effort for exactly that reason: the signal may land nowhere, and the process is then the
container runtime's problem. And within one namespace, a pid the OS has since recycled reads as
alive; `process_info` compares uid and process state but never the command, so a recycled pid owned
by the same user is indistinguishable from the agent that used to hold it.

Routing termination to the container that owns the pid is the fix, and it is not written.

Tracked in [#365](https://github.com/tadasant/zimmer/issues/365).

### Not every session `metadata` writer is atomic, and the whole-column writers are the majority

`Session#merge_metadata!` and friends push the merge into PostgreSQL as one statement, so they cannot
erase keys they did not name. See [Metadata races](/sessions/spawning/#metadata-races).

They are not what most of the app does. Counted against this commit, `app/` holds **34 atomic call
sites across 15 files** and **93 whole-column read-modify-writes across 27 files** — the
`update!(metadata: (session.metadata || {}).merge(…))` shape that rewrites the entire column from a
snapshot the caller read earlier. `AgentSessionJob` alone has 23 of them against 11 atomic calls.
That is not a handful of stragglers, and anyone scoping
[#70](https://github.com/tadasant/zimmer/issues/70) off a smaller number will under-estimate it
substantially.

Where a lost update is genuinely harmless: the terminal failure paths. 21 of the 93 name
`failure_reason` or `exit_status` in their payload, and 13 of `AgentSessionJob`'s 23 are immediately
followed by `session.fail!` — the session is ending, so a neighbouring key erased on the way out
changes nothing. Naming those keys is not a clean proxy on its own, though. Four of the 21 are on
sessions that keep going. `AgentSessionJob` writes `exit_status` onto a session it is *parking* for an
auth outage. `McpOauthResumeService#resume!` clears `failure_reason` on the way back to `waiting`.
And `CleanupOrphanedSessionsJob` and `DeploymentRecoveryJob` each strip `failure_reason` while
stamping `"paused_by" => "recovery"` onto a session they are about to continue — the most alive
writes in the whole set, since they are resurrecting a `failed` session, not ending one.

Where it is not harmless, the writers are on live sessions and some are hot:

- `TranscriptPollerService` — four whole-column writes, three of them inside `poll_and_broadcast`
  itself (two `update_columns` on the metadata-only paths, and the batch that carries `transcript`
  and `last_timeline_entry_at` together). This is the worker's single most frequent metadata writer,
  and it is why `interrupt_terminate_pid` is *harder* to lose than it was rather than impossible.
- `AgentSessionJob`'s `"paused_by" => "recovery"` writes, its `clone_retry_count` writes, and the
  `mcp_retry` park — all on a session that keeps running afterwards.
- Eight `update_column` metadata writes in `SessionStateMachine`'s AASM callbacks, which fire no
  callbacks of their own at all — four on `resume`, the rest on `pause`, `block_on_elicitation`, and
  the needs-input counter.
- Both session controllers (19 sites between them) and the MCP `action_session` tool, which write
  from the web process while the job's monitoring loop is writing from the worker.

No amount of atomic merging serializes two writers of the *same* key either — last writer still wins.

Tracked in [#70](https://github.com/tadasant/zimmer/issues/70).

### A killed worker reads as alive for up to 5 minutes, and a follow-up sent in that window is dropped

[Stale job supersession](/sessions/spawning/#stale-job-supersession) asks whether the worker holding a
job's lock is still alive, rather than guessing from the job's age. GoodJob answers that from either an
advisory lock (released by Postgres the instant the worker's connection dies) or a heartbeat the capsule
refreshes every 30 seconds and that expires after `GoodJob::Process::EXPIRED_INTERVAL`, 5 minutes. Which
one applies is GoodJob's `advisory_lock_heartbeat` setting, whose default enables it in **development
only** — so in production and staging the answer comes from the heartbeat alone, and a worker killed by
SIGKILL or OOM keeps reading as alive until its row expires.

What happens to a follow-up prompt sent inside that window is worth stating plainly, because it is not a
delay: `AgentSessionJob` sees a live-looking job, logs "Skipping job", and returns. Nothing re-enqueues
it, so the prompt text is never delivered. It is worse than a dropped message, because
`deliver_follow_up!` stamps `pending_follow_up_prompt` in the session's metadata first, and
`CleanupOrphanedSessionsJob` deliberately skips any session carrying that marker — on the assumption
that a job is about to pick it up. The session can therefore sit `running` with nobody driving it until
the user sends something else. Outside the 5-minute window the check works and the prompt lands.

Enabling `advisory_lock_heartbeat` in production would collapse the window to nothing, at the cost of
holding an advisory lock on the Notifier's already-retained connection for the life of every worker.
`JobLiveness` reads both signals, so flipping the setting needs no code change.

### The liveness probe can also call a live worker dead

The same probe fails in the other direction, and this one is quieter because nothing logs an error. A
worker that is running but whose `good_job_processes` row goes stale for over 5 minutes — a wedged
Notifier thread, a lost LISTEN connection, a pool exhausted under the tight budget in
`config/connection_budget.rb` — is classified `dead_worker`, and its live turn is superseded.

What the superseded turn's *process* then does is no longer left to chance:
[one live agent process per session](/sessions/spawning/#one-live-agent-process-per-session) terminates
it at the point of spawn, and the superseded job's own monitoring loop ends its turn as soon as it sees
ownership move. The misclassification still costs the interrupted turn its work in progress — that part
is unavoidable once the decision has been made wrongly — but it no longer leaves two agents racing on
one branch.

In development, where `advisory_lock_heartbeat` is on, there is a sharper variant: `GoodJob::Process.active`
only consults the heartbeat for rows registered *without* a lock, so a capsule that registered with one
and later drops it reads as dead no matter how fresh its heartbeat is, and does not re-acquire on renew.

Both are strictly less likely than the worker actually being dead — which is why the probe is written this
way — but neither is impossible, and neither announces itself.

### The spawn-time orphan check is inert outside the namespace that spawned the process

[One live agent process per session](/sessions/spawning/#one-live-agent-process-per-session) only acts
when it can prove the recorded pid is the process Zimmer started: same PID namespace, and the same start
time. Three cases are classified `unknown` and pass through untouched.

A pid recorded on **another boot or in another PID namespace** — a worker container that has since been
replaced, a role running on another host, or anything from before a reboot — cannot be checked or
signalled from here. In practice a container replacement takes its children with it, so the process
really is gone; the residual risk is a deployment where the agent outlives the recording container,
which Zimmer does not currently create.

A host with **no `/proc`** (macOS development) can capture neither signal, so the guard never fires
there. Development runs one worker on one machine, where the ownership backstop in the monitoring loop
already covers the common case.

An **identity with no provenance** — a session that was already running when the check deployed, so it
carries a `process_pid` and no `process_identity` — is unprotected until its next spawn records one.

In all three the guard stands down rather than guessing, because guessing "alive" means signalling a
process that may belong to something else entirely.

### State-machine side effects fail without surfacing

Nearly every callback is wrapped in a bare `rescue` that logs and swallows, so cleanup can be skipped
while the state advances anyway.

Tracked in [#73](https://github.com/tadasant/zimmer/issues/73).

### An elicitation Zimmer never hears the end of leaves the session parked, not resumed

Expiry is no longer a ten-minute fuse: the shipped default is an hour, `ELICITATION_EXPIRATION_MINUTES`
moves it per instance, and an MCP server's own `_meta["com.pulsemcp/expires-at"]` still wins for its
own request. A round-trip that ends without a human answer now says so on the session page instead of
leaving a session that looks merely idle.

What remains is the shape of the recovery. A [stranded block](/sessions/elicitation/#when-a-round-trip-ends-without-an-answer)
— the marker outliving its elicitation, because a state race swallowed the unblock or the MCP server
died mid-round-trip — is reconciled by leaving the session in `needs_input` with a banner naming what
happened. Zimmer does not retry the approval or resume the turn on its own: the agent process the
request belonged to may be gone, and flipping the session to `running` would create a phantom running
session with no monitoring job. The lost round-trip is surfaced, not replayed; picking it back up is
a follow-up you send.

Fixed in [#75](https://github.com/tadasant/zimmer/issues/75).

### A session's slug is claimed by retry, not by construction

`Session#generate_slug_from_title!` builds `title-yyyymmdd-hhmm` and, when that is taken, appends
`-1`, `-2`, and so on. The timestamp is minute-granular and a session with no transcript yet takes its
title from the prompt, so every session a trigger spawns in the same minute computes a byte-identical
base slug. Picking a free suffix by reading first is check-then-act, so the losing writer finds out
from `index_sessions_on_slug`; it advances the counter and re-attempts, up to `MAX_SLUG_ATTEMPTS`
(10).

That bound is the sharp edge. Ten simultaneous same-minute writers is far past anything observed — the
worst real burst was two — but a session that exhausts it keeps a `nil` slug, so it is addressable
only by numeric id, and `SessionTitleJob#apply_title` aborts before writing its title-generation log
entry. Nothing retries it later.

### Orphaned clones linger for up to 48 hours unless the disk is actually filling

`OrphanCloneFilesystemCleanupJob` on its hourly cron is patient — `AGE_THRESHOLD = 48.hours`,
`BATCH_LIMIT = 20` — so an orphaned clone normally sits on the volume for up to two days. Disk
pressure is the exception: `CloneDiskGuard` calls the same job's `reclaim_space` entry point before
each clone, which lowers the age bar to `PRESSURE_AGE_THRESHOLD = 2.hours` and stops as soon as the
volume has room. See [the second gear](/operate/background-jobs/#clone-pruning-has-a-second-urgent-gear).

What that does **not** reclaim is anything with an owning session row — a tracked `clone_path` is
never a pruning candidate, whatever the session's status and whatever the disk pressure. So a host
whose volume is full of clones belonging to real archived-but-not-yet-reaped sessions is still a
host that needs `StaleCloneCleanupJob` to catch up, or a human. The guard will say so, by name and
with numbers, instead of letting the clone die partway.

### Private repositories are cloned with a PAT, never an SSH key

`GitCloneService` and the local execution provider authenticate to private repos by rewriting an
HTTPS remote to `https://TOKEN@github.com/owner/repo.git` using the GitHub PAT in credentials.
There is no SSH-key path: an `ssh://` or `git@host:` remote gets no credential at all, and a
non-GitHub host gets none either. Tracked in
[#90](https://github.com/tadasant/zimmer/issues/90).

### A session's scratch directory survives archive, but only for the trash window

The [scratch directory](/sessions/spawning/) is durable against restarts and deploys, and it is
durable against archive — but not indefinitely. The contract is:

| Event | Scratch directory |
| --- | --- |
| Container restart, Kamal deploy | Survives (it is on the `zimmer_data` volume) |
| Archive, then unarchive | Survives, contents intact |
| Trash retention expires (`TRASH_RETENTION_PERIOD`, 4 days after archive) | Deleted by `EmptyTrashJob` |
| Archived >1h with no `trash_after`, or failed >24h, **and** the session recorded a `clone_path` | Deleted by `StaleCloneCleanupJob` |
| The session row is hard-deleted | Deleted with the row, by `Session#reclaim_session_directories` |

So a session can trust scratch for recovery state across an archive/unarchive round trip, and cannot
trust it beyond four days in the trash. Prompt attachments (`FileStorageService`,
`ImageStorageService`) are on the same schedule.

Every reaper in that table is driven by a database query, so a row deleted outright used to orphan
its scratch directory and prompt attachments on the volume permanently — nothing that could find
them was left. [#340](https://github.com/tadasant/zimmer/issues/340) closed that with an
`after_destroy_commit` on `Session` plus a filesystem-level
[orphan sweep](/operate/background-jobs/#a-deleted-session-takes-its-directories-with-it) over the
three per-session roots, the equivalent of what `ClonesDirectory.base` has always had. The sweep
runs hourly and ignores anything younger than `ORPHAN_AGE_THRESHOLD`, so a delete that skips the
callback costs a couple of hours rather than forever.

The archive/unarchive half of that used to be false in the other direction:
`DeferredCloneCleanupJob` deleted scratch about ten seconds after archive, and
`UnarchiveSessionService` had no restore path for it, so an unarchived session resumed with an empty
directory and no way to tell it apart from one it had never written to. Fixed in
[#323](https://github.com/tadasant/zimmer/issues/323) by moving the deletion to `EmptyTrashJob`,
which reaps at the trash deadline.

The remaining sharp edge is the last row: a session that fails and is left alone for 24 hours loses
its scratch directory while still being resumable. That window is deliberate — abandoned failed
sessions would otherwise accumulate on the volume forever — but it is shorter than the four days an
archived session gets.

### An abandoned pre-session upload is never reclaimed

Attachments picked in the new-session form are stored under a `temp_<uuid>` directory before a
session exists, and moved to the session's own directory when it is created. Every path that
reclaims one runs after a form submission — so an upload whose form is never submitted (the tab
closed, the draft abandoned) keeps its bytes on the durable volume with nothing left to trigger the
move or the cleanup.

The [orphan sweep](/operate/background-jobs/#a-deleted-session-takes-its-directories-with-it) that
reclaims a deleted session's directories deliberately does not take these: it establishes ownership
by looking the directory name up as a session id, and a `temp_<uuid>` has no id to look up. Sweeping
one on age alone would delete an upload a user is still composing with. The bytes are bounded by the
500 MB per-file cap and nothing else.

### Human messages are not backfilled, and cannot be

`human_messages` starts empty. Every session that existed before this shipped shows no human
messages, which reads as "Zimmer has no record here." For the gating use case that is the safe
answer, and it is honest — but it is not the same claim as "no human ever asked for this", and a
pre-existing session cannot prove authorization it genuinely received. Re-establish it live.

There is no backfill to write. The whole point is that capture keys off the authenticated actor at
the input boundary; reconstructing that actor after the fact from transcript prose is exactly the
guess the feature exists to eliminate.

The *hierarchy* is different and deliberately so: it is derived at read time from the
`custom_metadata.router_session_id` sessions already recorded, so pre-existing trees render
immediately without any migration rewriting a row.

### Two real human acts happen outside Zimmer's input boundary and are invisible

Both are cases where a human genuinely acted and no human message will exist:

- **An agent reading Slack mid-session through the Slack MCP server.** The agent fetches the
  message itself; it never crosses a Zimmer input boundary, so nothing is recorded. This is a
  *better* provenance signal than a relayed string — the agent saw the API response — and the
  record cannot represent it.
- **A human clicking Merge on GitHub.** A merge is a real human act on a real artifact, but it
  reaches Zimmer only as polled artifact state, on the same shared GitHub account every agent
  pushes through.

Neither is a bug in capture; both are boundaries Zimmer does not own. Read an empty record as
"Zimmer has no record", not as "no human acted."

### Web UI attribution is an assumption about the deployment, not a check

Anything typed into the Zimmer web UI is attributed to the user `ZIMMER_ADMIN_USER` names —
`tadasant` unless a deployment says otherwise — because Zimmer has no login and the network
perimeter is the authentication boundary (see [Philosophy](/intro/philosophy/)). The
attribution is exactly as strong as that perimeter: a second human given tailnet access would
silently be recorded as Tadas. That is the same trust model the rest of the app runs on, but a
human-message record makes it a *named* claim, which is a higher bar than the rest of the UI sets.

### `parent_session_id` is agent-settable, so a session can graft itself onto any hierarchy

Nothing checks that the caller of `start_session` (or `POST /api/v1/sessions`) is the session it
names as parent — the API key is shared by the whole fleet and identifies no one. A session can
therefore spawn a child pointed at an unrelated hierarchy, and that child will see the other
hierarchy's human messages.

What it can*not* do is turn them into authorization: those messages arrive marked `elsewhere`, and
`elsewhere` explicitly means "a human said this to another session, not to you". The `here`/`elsewhere`
distinction is the only thing standing between grafting and forged authority, so a consumer that
collapses the two — or a rendering that stops marking it — reopens this. That is why every surface
marks it and why the model refuses edits.

### An uncle edge is self-declared, so a session can attach itself as another session's senior

Uncle edges (see [Hierarchy and human messages](/sessions/hierarchy-and-human-messages/)) are
recorded from an `acting_session_id` the *caller supplies about itself*. Nothing verifies it. This is
not an oversight to be fixed later — there is no ambient caller identity to read: one API key is
shared by the whole fleet, and the MCP endpoint's scoping is per-connection, not per-session (the
self-session server injected into every session is byte-identical across all of them).

So this widens the grafting surface above in two ways:

- **No spawn required.** Grafting via `parent_session_id` means spawning a *new* session pointed at
  someone else's hierarchy. An uncle edge attaches the *calling* session to an existing hierarchy,
  and in both directions at once: the target's hierarchy grows to include the caller's, and the
  caller's grows to include the target's.
- **Any session that can follow up another can do it.** The declaration rides on `follow_up` /
  `send_now` / enqueue, so the reach is exactly the reach of the `sessions` MCP tool group (or a
  bare API key). A session holding only the `self_session` group cannot drive other sessions at all
  and so cannot do this.

What it still can*not* do is manufacture authorization, for exactly the same reason: messages pulled
in across an uncle edge arrive marked `elsewhere`, never `here`. `human_message_here?` — the question
a merge gate asks — is unmoved by any uncle edge, because an edge changes which sessions are *in
scope*, never which session a human *spoke to*. The `here`/`elsewhere` distinction remains the whole
defense.

Three things bound the damage rather than prevent it.

An edge is written into the logs of **both** sessions, naming both ids, the acting session and the
entry point that recorded it — so a graft is visible after the fact rather than silent. Both ends
matter: the shape worth catching is a session calling `follow_up` on *itself* while naming an
unrelated session as the actor, which pulls that hierarchy into its own scope without ever touching
it. Logging only the junior would leave the hierarchy that was reached into with no trace at all.

Every surface — the detail UI, the per-turn prompt injection, and the MCP/REST output — labels an
uncle edge as a *claim* of seniority rather than a fact, so a reader weighing "who is senior here" is
told what kind of assertion it is looking at.

And an edge recorded in error can be removed: `/supervisor/session_uncle_links` lists every edge with
its source and offers destroy. That is the operator escape hatch, not a product surface — there is no
way to detach an edge from the app itself yet ([#299](https://github.com/tadasant/zimmer/issues/299)).

If the trust model ever needs this closed properly, the fix is a per-session credential (a token
minted into each session's injected MCP config) rather than anything in the graph code.

### A session hierarchy is bounded, and a big one is shown truncated

The lineage graph is walked at most 8 levels deep and 150 nodes wide, in both directions — uncle
edges mean "up" fans out rather than forming a chain, so the upward walk carries the same bounds the
downward one always did. A router that has spawned hundreds of sessions renders a truncated graph
with an explicit note rather than the whole fleet. The session you asked about is always included,
but a distant cousin may not be — so "not in the graph" is not proof that no such session exists.

### A reaped subprocess loses a result Zimmer already had

`Open3.capture3` hands back `[stdout, stderr, status]`, and that status is nil whenever the child
was reaped by something other than `capture3`'s own `Process.detach` wait thread — the thread's
`waitpid` gets `ECHILD` and `wait_thr.value` returns nil. `ZombieReaperJob` is careful not to be
that something (see
[Background jobs](/operate/background-jobs/#the-zombie-reaper-only-takes-what-nobody-is-waiting-for)),
but its protection for waiters it cannot see in `ChildWaiterRegistry` is rule 2 — "still defunct a
couple of seconds later" — which is a timing argument, not a guarantee, and nothing stops future
code from reaping more bluntly.

Every call site reads that status through `SubprocessStatus`, which treats nil as a **failure**: a
result nobody can vouch for is not a result. Nothing crashes, and nothing is mistaken for success.
What is lost is the work. On the reaped path stdout and stderr are usually sitting right there and
the command very likely succeeded — only the exit code is missing — yet the caller throws the whole
response away. A poller retries on its next tick, so the cost is one wasted `gh` round trip;
`GitCloneService` and `AirPrepareService` have no next tick, so they classify it transient and
retry the clone outright.

Reading the pipes when the exit code is unknown would mean deciding a command succeeded on the
evidence of its output alone. That is the trade being made deliberately, and it is the cheaper
error.

### An automated poller message that fails to deliver is logged, not retried

`AutomatedSessionMessage#deliver_automated_message` — the path both the merged-PR message and the
merge-conflict message go through — swallows any exception raised while delivering, because one
session that cannot take a message must not abort the poller's sweep of every other session.

The state that triggered the message is written down regardless. `GitHubPullRequestPollerJob`
records the PR as `merged`, so the `open` → `merged` transition it keys on is gone by the next poll.
`GitHubMergeConflictPollerJob` records the conflict as confirmed, which suppresses re-notification
the same way. Neither message is retried.

The markers at least stay honest. The merged-PR marker is written only for PRs a message actually
went out for, so `github_pull_request_merged_notified` never claims a delivery that didn't happen,
and the session log entry is written inside the delivery transaction and rolls back with it. The
failure is in the Rails log, and nowhere else.

A crash is the case the ordering does cover. Messages go out before the markers are persisted, so a
process that dies in between re-sends on the next poll rather than dropping the notification.

### A parked session can hear about its merged PR up to a day late

`PollBackoff` slows each GitHub poller per session according to how long it has been since the user
last touched that session. Past 24 hours of no user activity the floor is 24 hours between polls,
so the merged-PR message rides that same curve.

The session most likely to be parked waiting on a merge is exactly the one with stale user activity:
it did its work, said so, and has been sitting in `needs_input` ever since. It can therefore wait a
long time to learn that the PR it was blocked on landed. The backoff exists because polling every
active session's PRs on every tick exhausts GitHub's 5000/hr authenticated rate limit at around 50
sessions, and that is the trade being made. Touching the session resets the curve to the 30-second
cadence.

---

## Triggers

### Agent-posted comments are only recognized when a known command posted them

`TranscriptHooks::GithubCommentAuthorshipHook` is what keeps Zimmer from routing its own agents'
GitHub comments back to agents, and it works by recognizing the *command* that posted the comment:
`gh pr comment`, `gh issue comment`, `gh pr review`, and `gh api` writes to a comments endpoint. A
comment posted any other way — a Python script, an MCP GitHub tool, `curl` — leaves no
`AgentPostedGithubComment` row, so it still looks exactly like a human comment and can still wake a
session. The `[CC Says]` marker remains a second line of defence for those, with the weakness that
put it here: an agent can forget it.

Deliberately narrow rather than scanning every tool result: an agent that merely *reads* a comment
gets that comment's own `html_url` back, and treating that as a post would silence a human. Covering
a new posting route means adding its pattern to `DIRECT_POST_PATTERNS`, or teaching
`gh_api_post?` the shape.

The same recognition gap sets the cost of the 60-second `ATTRIBUTION_GRACE_SECONDS` hold-down: every
human comment waits up to a minute longer (on top of the 30-second poll) before it wakes a session.

### A failed repo visibility lookup drops the comment

`GithubCommentPollerJob` only enqueues a follow-up when `GithubCommentPromptBuilder#actionable?`
says the agent is allowed to act on the repo publicly, and `actionable?` fails closed: if the
`gh api repos/OWNER/REPO` visibility call errors — rate limit, network blip, a repo that was
renamed — the repo is assumed public and the comment is skipped, with no prompt and no 👀. The
comment is still recorded in `custom_metadata`, so the poller's id-dedup means it is not
re-evaluated on the next tick: a real comment can be dropped permanently by one bad lookup.

Failing closed is the deliberate choice — acting publicly on a repo we couldn't check is worse
than missing a comment — and the blast radius is small, since `TRUSTED_OWNERS` short-circuits the
lookup entirely for `tadasant/*` (no API call, always actionable). The exposed case is a repo
owned by someone else that is actually private. The drop logs at `warn` naming the comment and
repo, which is the only signal you get.

### A failed one-time wake does not retry itself

A one-time wake whose fire raises is not destroyed: `ScheduleTriggerJob` (scheduled wakes) and
`AoEventTriggerJob` (session-scoped state-change wakes) park it in the `failed` status with the
error on the row, leave it in the list, and alert. What they do not do is try again. Parking is
what stops a persistent error (an unhealable agent root, a bad MCP reference) from re-firing
forever, and Zimmer has no way to tell that class of error apart from a blip worth one more
attempt — so it makes none and asks you.

The wake is late by however long it takes you to notice. Press **Re-arm** on the trigger (or call
`action_trigger` with `action=toggle`) and a scheduled wake fires within a minute. See
[Triggers](/sessions/triggers/#when-a-one-time-fire-fails).

A re-armed **state-change** wake is weaker than that, and the alert says so. It fires on its
watched session's transitions, so re-arming only delivers if that session transitions *again* —
and the common case for a failed wake is that the watched session was in the middle of its last
transition. Then no re-arm helps and the requester has to be resumed by hand. A broadcast
`ao_event` condition is never parked at all: it is recurring, so it alerts and keeps firing.

Two consequences worth knowing. A failure whose raise came *after* the schedule was consumed — the
session was created and only the cleanup behind it fell over — cannot be re-armed at all; the
trigger says so instead of offering a button that would do nothing, and you clear it by hand once
you have checked the session it spawned. And nothing ever reaps a failed trigger: it is deliberately
exempt from `CleanupStaleTriggersJob` and from sibling-wake cleanup, because deleting the record is
the bug. One systemic fault — a catalog rename that strands every trigger's agent root — therefore
parks every pending wake at once and leaves you a list to clear by hand.

### While Slack is rate-limiting you, Slack triggers fire late

`SlackTriggerPollerJob` is a `total_limit: 1` singleton, so while it runs it *is* Slack polling for
the whole instance. It no longer waits a throttle out on that slot: `SlackService` absorbs only a
short blip in process (`MAX_RETRIES = 3`, backing off 1s, 2s, 4s), and hands anything longer back as
a `TransientError`. The job then reschedules itself — 30s, 60s, 120s, 240s, 480s, or Slack's own
`retry_after` if that is longer — and frees the worker thread meanwhile.

What that fixes is the dropped ticks: the run is no longer parked in a `sleep` rejecting every cron
tick that lands. What it does not fix is the delay. A `last_message_ts` cursor means nothing is
*lost* — the next successful poll still sees the messages — but a trigger can fire minutes after the
message that should have fired it. After five deferrals (about fifteen minutes) the job stops
deferring, alerts, and lets the ordinary once-a-minute cron take over.

Fixed in [#77](https://github.com/tadasant/zimmer/issues/77). The delay above is what that fix traded
the dropped ticks for.

### `thread_ts` is not supported for bot mentions

You can watch a thread for new messages, but not for bot mentions, and not for passive listening
either — the passive types walk threads themselves.

Tracked in [#78](https://github.com/tadasant/zimmer/issues/78).

### Passive listening decides restraint in the prompt, not in the poller

`passive_listen_thread` fires on every new reply in a thread Zimmer has spoken in, and
`passive_listen_channel` — while the channel is inside `CHANNEL_ENGAGEMENT_WINDOW` (6 hours) — on
every new top-level message from an allowed human. The poller cannot tell "any update on that PR?"
from "thanks, that worked": both continue a conversation Zimmer is in, so both spawn a session.
Whether the session then *says* anything is decided entirely by its prompt template, and a template
that isn't written for silence turns passive listening into a session per message.

Three bounds worth knowing:

- **Channel engagement is detected from what the poll already fetched** — Zimmer's own *top-level*
  posts among the last `RECENT_HISTORY_LIMIT` (50) messages, remembered per channel in
  `bot_activity_timestamps`. In a channel busy enough that Zimmer's last post falls outside that
  window before it is ever observed, `passive_listen_channel` simply doesn't engage. A reply it left
  inside a thread never counts, by design. `passive_listen_thread` is unaffected by all of this.
- **A thread seen for the first time is clamped to `THREAD_BACKFILL_HORIZON` (24 hours).** It has no
  cursor of its own, so it falls back to the channel's top-level cursor, which in a thread-heavy
  channel can be weeks old. The clamp caps the catch-up at a day — but that day still fires, so a
  passive condition meeting a busy old thread for the first time can spawn several sessions at once,
  bounded only by the trigger's `max_sessions_per_minute` burst cap (above which the rest are
  *dropped*).
- **`participating_threads` and `bot_activity_timestamps` grow monotonically** inside the
  condition's `configuration` JSONB, exactly like the `channel_timestamps` and `thread_timestamps`
  hashes they sit beside. Nothing prunes any of the four — and because all four live on the
  *condition*, replacing a condition (for instance swapping the deprecated `passive_listen` for the
  two split types) starts from empty bookkeeping unless they are copied across by hand. That is not
  a clean slate: it both replays up to a day of thread replies and permanently loses threads whose
  parent has aged out of recent history. See the migration note in
  [Triggers](/sessions/triggers/#passive-listening-passive_listen_thread-passive_listen_channel).

### An @mention can fall between `bot_mention` and passive listening

Passive listening refuses any message that mentions the bot, so that a mention inside a participated
thread stops matching two triggers and spawning two sessions on the same text (it did, on every
mention, until it was fixed). The refusal is unconditional: `passive_candidate?` cannot see whether a
`bot_mention` condition would actually catch the message, because the poller processes conditions
independently.

So the mention is dropped by *both* paths when the deployment has no `bot_mention` condition, when
that condition is disabled or scoped to one channel while the passive condition sweeps all of them,
or when the two carry different `allowed_user_ids` (that list is per-condition). The intended shape
is a `bot_mention` condition at least as wide as the passive ones; nothing enforces it. Each drop
logs one `info` line naming the message and the condition that declined it, which is the only signal
you get.

### Everything is polled; there are no webhooks

GitHub PR status and comments are polled every 30 seconds per open PR. A 30-second latency floor and
a steady API burn.

The `github_label` and `github_issue` trigger conditions are polled too, once a minute, against
GitHub's search API. Webhooks would remove the latency floor, but they need a public ingress that
Zimmer's tailnet posture does not currently offer.

Tracked in [#79](https://github.com/tadasant/zimmer/issues/79).

### A `github_issue` trigger can fire itself

`github_issue` conditions match *any* new issue in a watched repo, with no author filter and no
exclusion of issues Zimmer itself opened. An agent fired by such a trigger that files a follow-up
issue in the same repo will fire the trigger again — and so on.

`ao_event` conditions have explicit loop protection (a session whose `metadata["trigger_id"]` is the
trigger never re-fires it); the GitHub conditions have no equivalent, because the loop runs through
GitHub rather than through a session. Until they do, don't point a `github_issue` trigger at a repo
whose triaging agent files issues.

### A `github_issue` trigger misses an issue indexed more than 30 minutes late

GitHub's search index is eventually consistent and unordered. `GithubTriggerPollerJob` re-queries a
30-minute window behind its cursor (`INDEX_LAG_GRACE`) so that an issue indexed *after* a newer one
is still picked up. Observed lag is on the order of seconds, so the window is generous — but an issue
that takes longer than that to appear in the search index falls behind the window and is never fired.
There is no reconciliation pass to catch it.

`github_label` conditions are immune to this: they compare against current state, not a cursor, so a
late-indexed item simply fires on whichever tick it first appears.

### A `github_issue` exclusion label only works if it is on the issue at creation

`exclude_labels` keeps an issue from firing a `github_issue` condition, and it is evaluated by the
GitHub *search* — a `-label:` negation — not by filtering what the poller got back. The poller ticks
every minute, so an issue that is opened and then labelled a moment later can be seen and fired
before the label lands. The escape hatch is only reliable when the label is applied at creation:

```sh
gh issue create --label "hold issue work gate" --title "…" --body "…"
```

There is no compensating check — nothing re-reads a fired issue's labels afterwards, and a session
already spawned is not withdrawn.

The reverse direction — *removing* the label later — is unpredictable rather than simply bounded,
and the reason is worth knowing. The poller re-queries a 30-minute window behind its cursor
(`INDEX_LAG_GRACE`), and that cursor advances only when an issue actually **fires**; a tick that
returns nothing leaves it where it was. So the window trails the last fired issue, not wall-clock
time. Un-holding an issue re-exposes it whenever no *other* issue has fired past it since — which,
in a repo where the held issues are the only recent ones, can be days later. Once something else has
fired and dragged the cursor forward, the same issue is behind the window and un-holding it does
nothing. Neither outcome is announced. Treat un-holding as "may or may not fire" and open a fresh
issue when you actually want the gate.

### The GitHub trigger poller needs a `gh` credential in the environment that runs it

`GithubTriggerPollerJob` runs on the **worker**, and shells out to `gh`. If that environment has no
`gh auth login` credential and no `GH_TOKEN`/`GITHUB_TOKEN`, the poller cannot search GitHub and every
`github_label`/`github_issue` trigger silently never fires. The poller detects this and skips the tick
with a single WARN rather than erroring per-condition — so the failure mode is "nothing happens", which
is quiet but easy to miss. Staging shipped without this credential, which is how the gap was found.

Check with `gh auth status` in the worker container; fix by providing a token to that environment.

### A timed-out GitHub search index skips the tick quietly, and the escalation needs Redis

When GitHub's search index times out it returns `incomplete_results: true` with a partial set.
Accepting that would corrupt the label poller's seen-set, so `GithubSearchService` re-runs the whole
search (0.5s, then 1.5s) and, if it is still short, the poller skips that condition for the tick with
a WARN. The next tick re-derives the whole seen-set, so this self-corrects — but for that minute the
condition is not polled and its trigger does not fire, with nothing in `#eng-alerts` to say so. A
label added and removed inside that window is never seen at all.

The escalation for a degradation that does not clear is a per-condition consecutive-skip counter in
Redis (`CONSECUTIVE_INCOMPLETE_SEARCHES_TO_ALERT`, 5 ticks). It fails **quiet**, not loud: if the
cache is unreachable the streak can never be counted, so a sustained single-condition degradation
would page only if it were broad enough to stall the poller's heartbeat too. That direction is
deliberate — inventing a streak from a failed cache read would page for a Redis blip on the first
index timeout, which is the noise this exists to remove.

### `BoundedSubprocess` can return a nil `Process::Status`, and only the `gh` search path guards it

`BoundedSubprocess.run` returns Open3's `wait_thr.value`, which is a `Process.detach` thread whose
`#value` is **`nil`** when the child pid was reaped elsewhere before the waiter's own `waitpid` ran
(`ECHILD`) — a race that can happen in the multi-threaded worker. A caller that then calls
`status.success?` on that nil crashes with `undefined method 'success?' for nil`. `GithubSearchService`
(the `github_label`/`github_issue` poller's search and its `gh auth status` preflight) guards both call
sites with `status&.success?`, turning a nil into an ordinary `SearchError` the poller already handles.
The other three consumers — `GitCloneService` and the two `AirPrepareService` calls, all on the
synchronous `waiting → running` launch path — do **not** yet guard it, so the same race would surface
there as a `NoMethodError` that fails that one session's launch (not a per-minute alert storm). The
durable fix is to make `BoundedSubprocess` never hand back a nil status; until then the exposure is
noted rather than fixed at the source.

---

## API

### Queue recovery mode is deliberately outside the health cooldown, and the web control is anonymous

`QueueRecoveryMode` (see [Queue recovery mode](/operate/background-jobs/#queue-recovery-mode)) is
Zimmer's escape hatch for a runaway job queue: it halts execution on `pollers`, `triggers` and
`default` for up to four hours. Two things about it are choices rather than oversights, and both cut
against the grain of the section below.

None of its three surfaces sit behind `HealthActionCooldown`. That throttle **fails closed** when the
cache cannot enforce it, and an instance overloaded enough to need recovery mode is exactly the
instance whose Redis is least trustworthy — so the throttle would have locked the escape hatch, and
above all the way back out of it, precisely when it was needed. A halt is two row-writes and is
reversible; being unable to resume is not.

And the web control inherits the dashboard's anonymity. `/health` has no authentication at all (see
[The /health dashboard runs destructive actions
anonymously](https://github.com/tadasant/zimmer/issues/312) — the whole web UI relies on
network-level access control), so anyone who can reach the page can halt instance-wide job
processing, repeatedly and unthrottled. That is a bigger lever than its neighbours on that page, even
though it is reversible, self-expiring and pages `#eng-alerts` on every transition. The REST and MCP
equivalents require an API key as usual, and MCP additionally gates on the `health` tool group, which
the `self_session` set injected into every agent session does not include.

Two knock-on effects worth knowing while the mode is on. Halting `pollers` also halts
`SystemHealthMonitorJob`, so the "Queue backlog critical" page stops firing — deliberate, since the
backlog is now the operator's own doing, but it means the mode's own enter/exit alerts are the only
signal. And enabling `config.good_job.enable_pauses` globally adds three `good_job_settings`
subqueries to every dequeue poll on all four schedulers; the table holds one row and is indexed on
`key`, but it is not nothing on a database already under the pressure of
[#329](https://github.com/tadasant/zimmer/issues/329).

### The only rate limit is on the health endpoints, and it needs a real cache

`HealthActionCooldown::COOLDOWN = 30.seconds` is the whole of Zimmer's rate limiting. It is keyed in
`Rails.cache` as `health_api_rate_limit:<action>:<digest of the API key>`, so it is per-caller — one
client's cleanup no longer locks everyone else out — and the raw key never lands in a cache key. All
three surfaces that can run these actions share that one object — the `/health` web dashboard,
`Api::V1::HealthController`, and the MCP `action_health` tool — so switching surfaces does not buy a
second run.

The web dashboard is the exception to "per caller", and unavoidably so: it has no authentication, so
there is no key to fingerprint and every visitor lands in one shared anonymous bucket. That is the
global cooldown it has always had.

The cooldown is only as real as the store behind it, and it can be unreal in two ways. A null store
drops every write and misses every read. A **dead Redis** does the same thing without being a null
store: `:redis_cache_store` is configured with an `error_handler` that logs the exception and
swallows it, so `write` returns nil and `read` returns nil rather than raising. Either way a naive
limiter answers "not limited" forever. So the cooldown writes a canary to the store and checks what
came back, and **fails closed** when it cannot: the three mutating API endpoints return
`503 {"error": "Rate limiting unavailable"}`, the MCP tool raises `Rate limiting unavailable`, and
the dashboard's buttons refuse with a flash. All of them log it. `GET /api/v1/health` and the
dashboard page itself are unaffected — they have no cooldown to enforce.

The consequence to know: an instance whose Redis is down cannot run `cleanup_processes`,
`retry_sessions`, or `archive_old` on any surface. That is deliberate — these are destructive
maintenance actions and the throttle is the only thing standing in front of them — but it is a hard
stop, not a degradation, and it arrives during a Redis outage, which is exactly when someone may be
reaching for those buttons.

Two things per-caller bucketing does *not* give you. It is not per-identity: `API_KEYS` entries are
opaque strings with no owner, so the bucket separates keys, not people. And it raises the
**aggregate** ceiling — the total rate of destructive actions now scales with the number of valid
keys, where one global bucket capped it at one per 30 seconds for the whole instance. With
`API_KEYS` holding a handful of strings that is the right trade, but it is a trade.

Fixed in [#99](https://github.com/tadasant/zimmer/issues/99). The two consequences above are the trade
that fix made, not a defect left behind it.

### A follow-up `goal` can set but never clear

`POST /api/v1/sessions/:id/follow_up` and the MCP `action_session` `follow_up` action apply a
non-blank `goal` to the session and treat a blank or omitted one as "leave the current goal alone".
There is deliberately no value that means "erase it" — the API has no way to distinguish a caller
who omitted the field from one who wants the goal gone, and silently clearing a session's stop
condition on every goal-less follow-up would be the worse failure. Clearing is
`PATCH /api/v1/sessions/:id` with `goal: ""`, or the `change_goal` action.

The HTML endpoint behind the web follow-up form reads a blank goal the other way: `params.key?(:goal)`
decides, so an *explicitly sent* empty string clears, and only an absent key preserves. That
divergence is latent rather than user-visible — `app/views/sessions/_follow_up_form.html.erb` renders
no goal field at all, so nothing in the shipped UI ever sends the key. The only web surface that
edits a goal alongside a message is the enqueued-message editor. A hand-crafted POST to the HTML
route is the one caller that can tell the two rules apart.

---

## Hardcoded values that shouldn't be

### Model IDs are a hardcoded Ruby array

`ModelCatalog::MODELS`. A new model requires a code change and a deploy.

Tracked in [#85](https://github.com/tadasant/zimmer/issues/85).

### The `X_OAUTH` bootstrap callback must be registered with X by hand

`XOauthBootstrap` sends `X_OAUTH_REDIRECT_URI` on both the consent request and the token exchange,
falling back to `http://localhost:8080/callback` (the URI already registered on the `ao-x-mcp-server`
app). X compares the two, so the value has to reach both call sites — it does — and it has to already
exist on your X app. **Registering it is a manual step on X's developer portal**; there is no API for
it, so setting the variable to an unregistered URI fails at consent time with an opaque error.

Fixed in [#104](https://github.com/tadasant/zimmer/issues/104) as far as code reaches: the variable is
sent on both call sites. Registering the URI is X's manual step and stays.

---

## UI

All four are open issues:

- [#12](https://github.com/tadasant/zimmer/issues/12) 🔴 The Undo button never appears. The
  archive `turbo_stream` response doesn't render the flash toast, so the 5-second undo window is
  unusable, even though the endpoint works.
- [#14](https://github.com/tadasant/zimmer/issues/14) Dashboard actions do full page reloads
  (restart/refresh/archive/pause explicitly opt out of Turbo). Lost scroll position, collapsed sections
  spring open, the drawer closes.
- [#13](https://github.com/tadasant/zimmer/issues/13) Card drag-reorder doesn't persist. It
  visually moves, then reverts on any reload.
- [#15](https://github.com/tadasant/zimmer/issues/15) No per-card refresh — you must refresh the
  entire category.

Also:

- Notes autosave as you type (a 1.5s debounce) and flush again on disconnect via a keepalive
  `fetch`. The disconnect flush is best-effort, so an abrupt close can drop the last sub-debounce
  keystrokes — not the note.
- The Turbo circuit breaker stops UI updates for 60 seconds when it trips (`THRESHOLD = 5`,
  `RESET_TIME = 60`). A polled "Live updates paused" banner says so while it lasts, but the updates
  dropped during the window are gone — the page catches up on its next reload, not retroactively.
  ([#86](https://github.com/tadasant/zimmer/issues/86))
- Push notifications don't work on anything without the Push API (iOS Safari outside standalone PWA).
- Reopening the installed PWA reloads the page, and Zimmer cannot stop it. iOS discards a
  backgrounded standalone PWA's web view under memory pressure, so reopening is a fresh navigation;
  Zimmer additionally reloads a session screen that comes back visible with a dead ActionCable
  connection, because a stale `<turbo-cable-stream-source>` otherwise leaves the page silently
  frozen. What survives the reload is the follow-up composer's text: it autosaves to `localStorage`
  as you type (a 300ms debounce, flushed immediately on `visibilitychange`/`pagehide`) and is
  restored on load. Scroll position, expanded panels and the other text fields on the page are not
  preserved — the composer draft is the only state carried across.
- A composer draft sits in `localStorage` for up to 7 days with no UI to clear it, and nothing
  removes it when the session is archived or you sign out. On a shared browser that is a prompt
  someone else can read. If `localStorage` is full the write fails silently and the previously
  stored, shorter draft stays behind — so a restore can hand back an older version of the text
  rather than nothing at all.
- The other text-entry surfaces — enqueued-message edit, dashboard notes, editable title and goal,
  the notes popover, elicitation forms — do not persist drafts across a reload. Notes have their own
  autosave; the rest lose in-progress text if the page is rebuilt under them.
- `start_url` in the web manifest is `/`, so a cold relaunch of the PWA lands on the dashboard rather
  than the session you were reading. The composer draft is keyed by session id and is still there
  when you navigate back, but you have to navigate back.
- The OAuth login poller gives up after 10 consecutive failed polls. Those 10 attempts back off (2s,
  4s, 8s, 16s, then 30s each) and so span about three minutes, which covers a deploy or a wifi
  handover — but an outage longer than that abandons the login and you have to start over. The panel
  says so rather than freezing on its last frame.
  ([#101](https://github.com/tadasant/zimmer/issues/101))
- A UI login whose job never dequeued — a dead or badly backed-up worker, so the CLI was never
  spawned and no heartbeat was ever stamped — has no liveness signal to go stale, and waits out the
  full 14-minute `expires_at` window before the panel reports anything. Attempts created before the
  `heartbeat_at` column shipped behave the same way.
- Alerts inside a 1-hour dedup window are swallowed, even genuinely new ones.
  ([#86](https://github.com/tadasant/zimmer/issues/86))

---

## Testing

### Playwright e2e scripts do not run in CI

🟡 CI runs the Chrome-driven Ruby system suite (`test/system/*.rb`) in the `test-system` job, but the
JavaScript Playwright scripts under `test/e2e/*.js` are still not wired in — the runner is not
provisioned with a Playwright browser, and `account_rotation_test.js` needs the real Claude Code
binary against a mock Anthropic server. The system suite covers the overlapping UI.

Tracked in [#162](https://github.com/tadasant/zimmer/issues/162). (The broader "system tests do not
run in CI" gap, [#87](https://github.com/tadasant/zimmer/issues/87), is closed by the `test-system`
job.)

### Four open flaky-test issues

[#10](https://github.com/tadasant/zimmer/issues/10) (a global `File.stub` racing background threads —
noted as having turned `main` red), [#5](https://github.com/tadasant/zimmer/issues/5),
[#3](https://github.com/tadasant/zimmer/issues/3), [#2](https://github.com/tadasant/zimmer/issues/2).

### Tests that skip themselves in CI

`preregistered_oauth_config_test.rb`, `secrets_loader_test.rb`, `references_config_test.rb`, and
`air_catalog_ref_rewriter_test.rb` (×2). Catalog pinning has zero CI coverage.

Tracked in [#69](https://github.com/tadasant/zimmer/issues/69).

### CI never runs the migrations

🟡 Both test jobs build the database with `bin/rails db:test:prepare`, which *loads* `db/schema.rb`
and never runs a migration. So a `schema.rb` that disagrees with `db/migrate/` passes CI and diverges
from production, which does run them.

`bin/rails db:schema:verify` (`lib/tasks/schema_verify.rake`) is the check: it migrates a scratch
database from zero, loads the committed schema into another, dumps both, and diffs. It drops and
recreates databases, so it refuses to run outside `RAILS_ENV=test` and is deliberately not wired into
the merge gate. What *does* run in CI is the cheap half, `test/migrations/schema_dump_test.rb`: the
dumps are in the running Active Record version's format, and `schema.rb` is at the newest migration
on disk.

**It found one real drift case.** `db/migrate/` was not replayable from zero because two
`sessions` columns existed in `db/schema.rb` without a migration. `sessions.transcript` made
`20260613193000_add_session_maintenance_indexes` fail with `PG::UndefinedColumn` when it built its
partial index, while `sessions.repository_name` was a quieter divergence: from-zero databases simply
lacked a column that prompt-building code reads. `20260613192900_add_missing_session_columns_for_migration_replay`
adds both columns idempotently before that index migration, so existing schema-loaded databases no-op
and fresh migration replays create the columns in time.

The format half is fixed. `db/schema.rb` was an `ActiveRecord::Schema[8.0]` dump under Rails 8.1, so
every `db:migrate` reformatted all ~450 lines (the 8.1 dumper alphabetizes) and every migration PR
carried an unreviewable whole-file diff. It is an 8.1 dump now.

Tracked in [#182](https://github.com/tadasant/zimmer/issues/182).

### Nothing checks the committed icons still match the master artwork

🟡 Every favicon, PWA icon and apple-touch icon is generated from
`docs/scripts/zimmer-icon-source.jpg` by `npm run icons`, and the *output* is what gets committed.
`test/integration/app_icons_test.rb` checks the committed files exist, are the size they claim, and
are wired into the manifest, the layout and the docs site — but not that re-running the generator
would reproduce them. So editing the master and forgetting to re-run the script, or editing one
generated PNG by hand, passes CI.

The obvious fix — regenerate in CI and diff — is not safe to add: sharp/libvips PNG output is not
byte-stable across versions, so the check would go red on an unrelated dependency bump. Re-run
`npm run icons` and commit whatever it writes whenever the master changes.

---

## Development environment

### The containerized dev env's "manual" path is a single shared stack, not isolated

`.agent-containers/` provides a containerized dev stack (`docker-compose.dev.yml`). The compose file
hardcodes `name: zimmer-dev-local`, so running it directly (`docker compose -f
.agent-containers/docker-compose.dev.yml up`) always uses the **same** Compose project regardless of
which clone you run it from. Two clones started that way collide — they share containers, the
`postgres_data` volume, and the port, and tearing one down (including
`DockerComposeCleanupService` cleaning up a clone) takes the other with it.

Per-session isolation comes only from `.agent-containers/ac.sh`, which passes `-p zimmer-dev-<name>`
to give each session its own project, clone, and dynamic port. That's the path agents and anyone
running several instances in parallel should use; the manual/devcontainer path is for a single
instance. This is a consequence of `DockerComposeCleanupService` deriving the project name purely
from the compose file path (no per-clone input), and isn't worth reworking that inherited service
for — use `ac.sh` when you need isolation.

---

## Product gaps

### Auto-categorization has no feedback loop

[Issue #16](https://github.com/tadasant/zimmer/issues/16): an LLM sorts new sessions into categories.
When you drag a mis-sorted session to the right one, the correction is written to
`sessions.category_id` and nowhere else — the model's original choice, its context, even a timeline
note are all discarded. The next identical session is mis-sorted identically, forever.

### A goal has zero runtime enforcement

`AgentSessionJob#build_prompt_with_goal` appends the goal's description to the prompt string. That is
the entire mechanism. Nothing checks that CI went green, that a review happened, or that the PR has the
`## Verification` section the goal demanded. The stop condition is enforced only by the LLM obeying
English.

Tracked in [#88](https://github.com/tadasant/zimmer/issues/88).

### PR ownership is a transcript heuristic, and both ways of being wrong are silent

`GithubPrUrlHook` decides which PRs belong to a session by reading its transcript for evidence that
the session *opened* one: a successful `gh pr create`, a failed one that says the branch's PR already
exists, or the agent's own prose claiming it opened a PR on this repo. Everything else — a PR read
with `gh pr view`, a PR URL arriving in a user message or a Zimmer notification — is ignored on
purpose, because recording it is how one session ends up receiving another session's review comments
and merge-conflict alerts.

Heuristics have two failure directions and neither announces itself:

- **Too loose** and a PR gets attributed to a session that had nothing to do with it. The prose path
  is the exposed edge here — an agent that writes "opened the PR at `<url>`" about someone else's
  same-repo PR would be believed. Requiring an inflected verb keeps the common "the open PR:
  `<url>`" reference out, but a genuine first-person claim about someone else's PR is
  indistinguishable from a true one.
- **Too tight** and a session's own PR is never recorded, so `GitHubPullRequestPollerJob`,
  `GithubCommentPollerJob` and `GitHubMergeConflictPollerJob` all quietly do nothing for it. A PR
  opened through a path the hook can't see — an MCP GitHub tool, the web UI — and never mentioned in
  the agent's prose lands here.

The warning log a PR-flavored goal gets when a session comes to rest (`pause`, `fail` or `archive`)
covers the second case only, and only when the goal happens to mention pull requests. There is no
check at all for the first. That warning is also written once per session and never retracted, so a
session that was warned and is then resumed or unarchived — `resume` runs from `failed`,
`unarchive_to_*` from `archived` — keeps a warning its later PR made obsolete.

Narrowed in [#214](https://github.com/tadasant/zimmer/issues/214) and widened in
[#89](https://github.com/tadasant/zimmer/issues/89).

---

## The Parameter Store resolver has never talked to Google

`SecretProviders` puts a Google Parameter Manager + Secret Manager link at the front of the
`${VAR}` resolution chain, and `docs/operate/secrets-parameter-store.md` gives the exact
provisioning runbook for the credential it needs. **No Zimmer process has ever made the call.**

The GCP half is provisioned for both environments — `zimmer-secrets-prod` and
`zimmer-secrets-staging`, each with its own service account, its three roles, audited, and
production with a canary parameter proven to `:render` — but a human did all of it, and no agent in
this deployment could have: there is no `gcloud` on the box, no GCP MCP server in the catalog, and
CI holds no IAM-admin credential.

The Kamal delivery of `ZIMMER_PARAMS_*` is wired here now for **both** environments
(`.kamal/secrets.*`, `config/deploy.*.yml`, and for staging the `env:` allowlist in
`deploy-staging.yml` too), and the env-file round trip is verified for real. What remains is
human steps that no test can stand in for. For production, two of them, both in
`tadasant-internal`: setting `PROD_ZIMMER_PARAMS_RESOLVER_SERVICE_ACCOUNT_KEY_JSON`, and naming it
in **both** places `zimmer-deploy-prod.yml` enumerates secrets. Miss the second and the Kamal
mapping resolves to blank with no error — a deploy that looks healthy while the store never turns
on. For staging, two, gating different deploy paths rather than stacking: adding
`STAGING_ZIMMER_PARAMS_RESOLVER_SERVICE_ACCOUNT_KEY_JSON` to this repo's Actions secrets, which is
what `deploy-staging.yml` needs; and giving `tadasant-internal`'s staging cutover workflow its own
`env:` passthrough and its own copy of the secret, which nothing here can see or assert. Staging's
`zimmer-secrets-staging` project is provisioned and audited, and `deploy-staging.yml` prints
whether the credential arrived.

What *is* verified here: the chain and its precedence, the degraded state when no credential is
configured, the miss-vs-outage distinction, the snapshot cache semantics, the envelope round-trip
(the envelope the Connectors page hands you is exactly what the client reads back), the fact that
a secret value never lands in a Parameter Manager payload, and that a base64 credential survives
Kamal's escaping into a container while pretty-printed key JSON does not. The Google half is
`test/support/fake_parameter_store.rb`, an in-memory fake of the two APIs behind the HTTP seam —
the production client is what runs, only the network is faked.

So: the code is ready, and wherever the credential is absent Zimmer resolves every `${VAR}` from
encrypted credentials exactly as before. What no test covers is the one thing that matters — a
live `:render` issued by Zimmer itself against real Google. The Connectors page is where that first
shows, in either environment.

---

## 🔴 The envelope Zimmer tells you to store breaks on any secret containing a quote, brace or newline

**Unfixed, and known.** No issue is filed yet — it is recorded here so it is not rediscovered from
a production symptom.

`SecretsLocation#envelope_json` — the envelope the Connectors page hands you when the Secrets
Console does not administer Zimmer's project, and the same shape written down in
[the runbook](/operate/secrets-parameter-store/#adding-a-secret) —
creates the parameter with `--parameter-format json` and puts the `__REF__` pointer inside a **JSON
string**:

```json
{"path":"/zimmer/production/mcp/static/X","secret":true,"value":"__REF__(\"//secretmanager…\")"}
```

Parameter Manager's `:render` substitutes the secret's **raw bytes** in place of that token, inside
the enclosing string literal. It does not re-escape them. So a value containing a `"`, a `{` or a
newline breaks the JSON it is being pasted into, and Google refuses the render with **`400 injection
detected`** — which `GcpClient#rendered_envelope` re-raises (it swallows only `404`), failing the
whole namespace snapshot, not just that one variable. Every `${VAR}` in the environment stops
resolving from the store at once.

That rules out most real credentials: service-account key JSON, PEM private keys, anything
JSON-shaped. Plain tokens are fine, which is why nothing has surfaced — no real secret has been
stored under `/zimmer/{env}/mcp/static/` yet, and the resolver is not yet delivered to a running
container.

**The reason no test catches it** is the more important half. `FakeParameterStore#render_version`
parses the envelope, replaces the value on the *parsed Ruby object*, and re-serializes with
`JSON.generate` — which correctly re-escapes anything. Structural substitution that Google rejects
therefore round-trips cleanly through the fake, for every possible value. The fake models the
`:render` join but not its validation, so the suite is green on inputs that fail against real
Google. Zimmer inherited both the envelope and the blind spot from strad, where the same defect
surfaced as a real production failure on an 802-byte JSON array containing 88 double-quotes.

This is not fixed here: it is a credential-path change, and it deserves its own diff and its own
review.

---

## Connector status is configuration, not reachability

The Connectors page reads the same inputs a session spawn reads — a server's `${VAR}` values,
whether an OAuth flow applies, and the stored credential. It never contacts the MCP server itself.

A **Ready** badge therefore means "Zimmer has what it needs to connect", not "the remote host
answered". A server whose token is valid but whose host is down still reads Ready. Adding a real
reachability probe would mean an outbound request per server on every page view, against
third-party endpoints, on a page that exists to be glanced at.

---

## Authorizing from the Connectors page does not release a session parked on that server

The **Authorize** button on a connector row starts an OAuth flow with no session behind it. That
is the point — you no longer have to spin up a throwaway session to authorize a connector — but it
also means there is no session to resume, so `McpOauthResumeService` never runs for that flow.

If a session is sitting `failed` with `failure_reason: oauth_required` on the very server you just
authorized from `/connectors`, the credential is stored and every future spawn inherits it, but
that session stays parked. Releasing it still takes a click on its own OAuth banner, which takes
the already-have-a-credential branch: re-inject the token, clear the runtime's needs-auth cache,
and resume.

---

## The spot gate cannot see spend it never sampled

`ClaudeUsageRateService` differentiates `ClaudeAccountQuotaSnapshot` rows, so its resolution is
whatever the sampling cadence happens to be. `ClaudeUsageSamplerJob` reads the serving account every
15 minutes, which is enough for a rate but not for a spike: a burst that starts and finishes inside
one 15-minute gap is invisible, and the forecast that follows is built on a rate that never saw it.

Two consequences worth knowing:

- The gate reacts on a 15-minute lag at best. Twenty spot sessions launched at once all evaluate
  against the same pre-burst rate and all start.
- A pair of readings that straddles a window reset is dropped rather than clamped, because the
  counters slide downward on their own and the difference measures nothing. If resets happen to line
  up with the sample cadence, usable pairs get scarce and the gate falls open on
  `insufficient_data`.

Both are deliberate — the alternative is a gate that guesses — but they mean the gate is a brake on
sustained burn, not a circuit breaker on a spike.

---

## A held spot session has exactly one thread back to life

`SpotSessionHold` defers by re-enqueueing `AgentSessionJob` with a delay, and that single delayed
GoodJob row is the *only* thing that ever restarts the session. GoodJob persists it, so it survives
a worker restart or a deploy — but if it is discarded (retries exhausted on an unrelated exception,
a manual queue purge, a failed deserialization), the session sits in `waiting` indefinitely with a
banner whose "next check" time is permanently in the past. `DeploymentRecoveryJob` will not pick it
up: that only claims sessions carrying `metadata["paused_by"] == "recovery"`, which a held session
does not have. `spot_hold_count` is recorded but nothing acts on it. A sweep for `waiting` sessions
whose `spot_hold_retry_at` is well past would close this.

---

## The genesis backfill runs in one transaction

`AddGenesisToSessions` does an `add_index` plus four full-table `UPDATE`s — one of them looped up to
ten times over a self-join — inside a single migration transaction, holding a lock on `sessions`
throughout. The lineage passes also filter on `metadata::jsonb->>'forked_from_session_id'`, which no
index can serve because `metadata` is `json` rather than `jsonb`. On a small deployment this is a
second; on a large `sessions` table it is a write-blocking pause. It was left transactional
deliberately — a half-applied backfill would leave rows classified by nothing — but a deployment
with a large table should expect the lock.

---

## Only a session's first start is gated

`SpotSessionHold` runs on the new-session path only. A follow-up, a monitoring resume and a
clone-only setup all pass through regardless of forecast, so a long-running spot session keeps
spending after the gate has closed behind it. Interrupting a conversation already underway would
strand it half-done and waste the tokens already spent, so this is the intended trade — but "spot
sessions are held" means "not started", not "not running".

---

## Genesis backfill cannot recover what was never recorded

The migration that added `sessions.genesis` reconstructs it from `metadata->>'source'`, the
trigger's condition types, and the lineage edge. The new-session form and the REST API never
stamped anything, so pre-migration rows from those two paths are indistinguishable and land on
`unknown` — which classifies **priority**. Old automated work created over the API therefore reads
as priority until it is archived. The failure mode is "runs anyway", which is the right way round,
but the historical counts on the Settings page are not a reliable census of what was automated.

---

## A zombie WebSocket is not detected on PWA reopen

`stream_visibility_recovery_controller.js` decides whether a reopened page missed anything by
asking `consumer.connection.isOpen()`, which reads `webSocket.readyState`. A socket the browser
never reports as closed — the server went away, or the OS suspended the connection without
tearing it down — still reads as open, so the controller leaves the page alone and does not
re-render it.

The page does not freeze: ActionCable's own connection monitor treats the connection as stale
after ~6s without a ping and reopens it, and `cable-reconnect` re-subscribes any stream source
that stays dark, so live updates resume on their own. What is lost is the backfill — anything
broadcast while the page was away is not recovered until the next reload or navigation.

The obvious tightening, adding `connection.monitor.connectionIsStale()` to the check, does not
work: a frozen page receives no pings while it is backgrounded, so the connection reads as stale
on *every* reopen and the controller would reload every time, which is the bug it was written to
fix ([#389](https://github.com/tadasant/zimmer/pull/389) is the earlier attempt in that area).
Distinguishing "stale because we were asleep" from "stale because the socket is dead" needs a
liveness probe after the page wakes, not a reading taken at the moment it wakes.

---

## Nothing revives a `devdb` accessory that stops

([#419](https://github.com/tadasant/zimmer/issues/419))

First, the thing that is **not** a limitation, because it keeps being written down as one: no manual
`kamal accessory boot devdb -d production` is owed. Bare `kamal deploy` does not boot accessories,
which is a true Kamal fact, but neither destination deploys with bare `kamal deploy`.
`deploy-staging.yml` runs `kamal accessory boot all -d staging` and the companion repo's
`zimmer-deploy-prod.yml` runs `kamal accessory boot all -d production`, each immediately before its
deploy, unconditionally. An accessory the destination declares gets created by the deploy.

The real gap is what happens after that. `kamal accessory boot` is idempotent by *existence*, not by
health: it runs `docker ps -a` per host and skips any host where a container is already there, and a
**stopped** container is still there. Docker's own `--restart unless-stopped`, which is what Kamal
boots accessories with, covers a crash or a daemon restart. A container that is stopped and stays
stopped is covered by nothing — no health check, and every later deploy skips right over it.

A session cannot repair that itself: the Docker socket is mounted into the worker but the worker is
not in its group ([#409](https://github.com/tadasant/zimmer/issues/409)), and there is no root. So
the only signal is a session reporting that `bin/agent-dev` found no Postgres, and the only recovery
is an operator running `kamal accessory reboot devdb -d <dest>`.

---

## An interrupted `BundleInstallJob` leaves a clone permanently broken

`BundleInstallJob` installs a clone's gems into `vendor/bundle` in the background while the agent is
already working, and it is declared `discard_on StandardError` — deliberately, so a failed install
does not retry forever. The cost is that an install interrupted partway (a deploy, a SIGTERM) never
resumes and never retries. The clone is left with a `.bundle/config` pointing at a half-populated
`vendor/bundle`, and every `bin/rails` invocation afterwards dies with `Bundler::GemNotFound` listing
gems that are plainly installed in the image.

Nothing surfaces this at the agent's prompt; the session log line is the only trace. `bin/agent-dev`
heals it with `bundle check || bundle install` before doing anything else, but any other Ruby command
in the clone hits it first.

---

## Nested Docker depends on a global, invisible Docker flag

The worker's nested-Docker mode (`ZIMMER_NESTED_DOCKER=1`) cannot start a single container
without `features.time-namespaces: false` in the host's `/etc/docker/daemon.json`. Docker puts
a `time` namespace in every OCI spec it creates and sysbox rejects it, so without the flag even
`docker run --runtime=sysbox-runc alpine echo hi` fails.

The flag is a workaround for [nestybox/sysbox#1011](https://github.com/nestybox/sysbox/issues/1011),
not configuration, and it is worse than a local hack in three ways: it is **global** (every
container on the host loses its own time namespace, not just sysbox ones), it is **invisible**
(not surfaced in `docker info` — only reading `daemon.json` reveals it), and it is
**load-bearing** (remove it and every sysbox container stops starting).

It is inert for Zimmer, which wants no per-container clocks, and it has run without incident.
The risk is a future Docker release changing or dropping the flag, which would present as
"the worker will not start" with nothing pointing at the cause. Tracked for removal once
upstream lands in [#421](https://github.com/tadasant/zimmer/issues/421) — see
[Nested Docker for agent sessions](/operate/nested-docker/).

---

## Open questions

Things the code doesn't answer, flagged here rather than guessed at:

- Does the double-suffixed Redis URL (`redis://redis:6379/0/0`) actually work? The client may tolerate
  it or may fall back to db 0. ([#20](https://github.com/tadasant/zimmer/issues/20))
- Does any real MCP server accept the fallback `client_id: "zimmer"`? It looks like it would only work
  against a server that ignores `client_id` entirely. ([#64](https://github.com/tadasant/zimmer/issues/64))
- What is `tadasant/zimmer-catalog`, and are the five roots pointing at it still live? It's a separate
  repo this documentation can't see. ([#67](https://github.com/tadasant/zimmer/issues/67))
- Is `config_preparer_class` (a `RuntimeRegistry::Bundle` slot) meant to do something? It's `nil` for
  every runtime and nothing reads it. ([#97](https://github.com/tadasant/zimmer/issues/97))
- Does the macOS Keychain path in `CodexMcpCredentialWriter` work? It has never been runtime-verified
  — every worker is Linux. ([#63](https://github.com/tadasant/zimmer/issues/63))
