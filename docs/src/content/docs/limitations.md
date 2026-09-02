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

### A deployment that configures no git identity still cannot commit

`GitIdentityProvisioner` writes `user.name` / `user.email` into `~/.gitconfig` at boot from
`ZIMMER_GIT_USER_NAME` / `ZIMMER_GIT_USER_EMAIL` ([provisioning](/operate/provisioning/#the-git-identity-an-agent-session-commits-with)).
Set neither, or only one, and it writes nothing: a session in that deployment still meets
`Author identity unknown` on its first commit, exactly as it did before that class existed.

**No issue tracks this, deliberately** — it is a design choice, not a defect awaiting a fix.

That is the deliberate half of the fix, not an oversight. The alternative is a default identity baked
into the repo, which would put Zimmer's guess — `Zimmer Agent <zimmer@localhost>` — into a
self-hoster's git history, silently and irreversibly. A missing identity fails loudly at commit time
and the session can recover; a wrong one is in the history forever. So the failure mode is preserved
on purpose for a deployment that has not said who it is, and the boot log says so in one line naming
both variables.

### The DigitalOcean metrics agent reaches only a droplet Terraform creates, never one that exists

`digitalocean_droplet.zimmer` sets `monitoring = true`, so a droplet this module creates boots with
DigitalOcean's metrics agent — CPU, memory, disk and load history, and the only metrics DO's own
resource alert policies can evaluate. It is free.

It is also **create-time only**, and there is no second path. `monitoring` is `ForceNew` in the
provider (the schema flag, in every 2.x release including the `~> 2.43` pin; the Update function has
no `monitoring` branch), and DigitalOcean's API exposes no droplet action to enable it — the
`droplet_action.type` enum runs `enable_backups` through `snapshot` with nothing for monitoring, and
`godo`, the client the provider itself uses, has no method for it. So on a droplet that already
exists, asking for the agent is a *destroy and recreate*. Both environments apply with
`-auto-approve`, and the production apply owns the box every Zimmer session runs on. `monitoring`
therefore sits in `ignore_changes` alongside `user_data`, which suppresses that diff and the
replacement with it.

What is left for an existing droplet is DigitalOcean's own remedy: open a root shell on the box and
run `curl -sSL https://repos.insights.digitalocean.com/install.sh | sudo bash`. **This deployment has
no clean way to do that.** A root shell on production is the thing
[Ops actions ship with the deploy](/operate/deploying/#ops-actions-ship-with-the-deploy) exists to
rule out — the operator key is not authorized as root, and the DigitalOcean console fallback needs
the root password that [has no converge path](#productions-forced-root-password-expiry-has-no-converge-path).
So in practice the production droplet gets the agent when it is next rebuilt, and not before.

That gap is a departure from this repo's own rule that an ops step must ship with the deploy, and it
is tracked in [#651](https://github.com/tadasant/zimmer/issues/651) — the plausible fix is an
idempotent deploy-time install over the root SSH access Kamal already holds. Adjacent, and different:
[#442](https://github.com/tadasant/zimmer/issues/442) wants a `node_exporter` in cloud-init for an
external monitoring plane, which is a different agent feeding a different consumer.

Two smaller edges. `ignore_changes` also means Terraform will not turn the agent back off, or back on
if someone disables it — both cheaper than a replace. And it is unconfirmed whether a hand-installed
agent makes the API report `monitoring` in the droplet's `features[]`, which is what the provider
reads; if it does not, config and state stay divergent forever, harmlessly.

The DO agent reports host metrics. App telemetry goes to the self-hosted OTLP stack — see
[Observability](/operate/observability/).

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

### The release build's retry masks a flake

`release-image.yml` builds the app image up to three times before giving up, because an account-wide
GHCR secondary rate limit intermittently breaks both the `zimmer-base` pull on the way in and the
`zimmer` push on the way out (see
[Deploying](/operate/deploying/#the-release-build-retries-ghcr-on-the-way-in-and-on-the-way-out)).
That is the right trade for a registry hiccup, but it is still a **blind** retry: it does not read the
error, so it cannot tell a throttled push from a genuinely rejected one, and it buys its quiet by
making real breakage slower to surface — 330 seconds of backoff plus three builds before it goes red,
with `concurrency: release-image` queueing the next push behind all of it. (The builds themselves are
not as expensive as that sounds: every attempt runs on the same long-lived buildkit instance, so a
retry resumes from its local cache. A push-side retry re-does little more than the export; only an
early pull-side failure costs close to a full rebuild.)

Blindness is the deliberate half of that trade — the same throttle has already appeared as a 403 on a
base blob, a 404 on a base manifest, and a 403 on a push HEAD, so matching error strings would miss
the fourth shape. What it costs is precision: a build broken for an ordinary reason still burns the
full retry budget before going red. `.github/scripts/await-ghcr.sh` softens that by reading a manifest
from both the base and app packages between attempts and annotating which was refused — but the
annotation only *reports*, nothing acts on it, and because both probes are reads they cannot clear a
write-side throttle even when both come back green.

The blindness extends to two more of the registry steps in the job — three of the four points it
touches GHCR are retried, and `Build & push base image` is the one that is not. `Log in to GHCR` runs `.github/scripts/ghcr-login.sh` — the same `docker login` a
`docker/login-action` step would run, three times, backing off 90s then 240s — because a single-shot
login is a single point of failure in front of everything else: on 2026-09-02 one
`net/http: TLS handshake timeout` reaching `ghcr.io/token` failed the release 48 seconds in and
skipped every step after it. And `Resolve base image` retries its `imagetools inspect` three times,
5s then 15s apart, because that read fails *closed* into `need_base=true` — a hiccup there does not
fail the job, it escalates into a full base rebuild and push against a registry that may already be
refusing the account.

Neither retry is free of the same objection. The login now takes up to 5.5 minutes of backoff to
report a token that is genuinely wrong, and the base resolve pays 20 seconds of waiting on every
legitimate base bump, since a base declaration that really did change is absent and so exhausts the
retries every time. `Build & push base image` itself is still single-shot: a throttle that survives
the resolve's retries and then kills the base build fails the job before the app build's first
attempt is reached. That path has not been observed failing; all the real incidents were the app
build and the login.

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

### Every agent-session clone carries the Slack bot token, the alert channel id, and the operator's user id

`AgentSessionJob#inject_secrets_to_env_file` writes `SecretsLoader.all` — the whole credential bundle
— into each clone's `.env`, and that bundle includes `SLACK_BOT_TOKEN`,
`ENG_ALERTS_SLACK_CHANNEL_ID` and `OPERATOR_SLACK_USER_ID`. Anything an agent runs inside its clone
can therefore post to the real alert channel as the real bot, and — since the operator's user id
travels with the token that can DM them — DM the operator directly. An agent's shell also has no `RAILS_ENV`, so a clone that boots Zimmer
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

### A node can report Online while every connection to it times out

`tailscale status` and the Tailscale API both answer from the **control plane**: `Online`,
`connectedToControl` and `lastSeen` say the node is holding its control connection, not that a packet
can reach it. Those are different things, and they come apart under load. A host thrashing on memory
starves `tailscaled` of the CPU it needs to service the data path, so every connection — `:22`, `:2222`,
HTTP over the tailnet — times out with no TCP handshake at all, for minutes at a stretch, while the
control connection (long-lived, cheap, already established) keeps reporting the node perfectly healthy.

The failure looks like a network fault and is actually a capacity fault. Two things mislead you:

- **`Connection timed out`, not `refused`.** Nothing is rejecting the connection, so it reads like a
  firewall or a routing problem. It is neither.
- **Every control-plane check passes.** The deploy's `Prepare Kamal SSH + resolve host` step gates on
  `.Online==true` from `tailscale status --json`, so it resolves the host successfully and the *next*
  step fails to reach it seconds later. The Tailscale API agrees throughout, reporting
  `connectedToControl: true` with a current `lastSeen`.

`scripts/clear-root-password-expiry.sh` distinguishes the two cases and says which one it hit, because
its advice differs: an unreachable host is not a broken password, so there is nothing to repair by
hand. When you see that message, look at the host's memory and load — start with `dmesg -T | grep -i
"killed process"` — rather than at its SSH configuration. Note that the outage clears on its own in a
few minutes, so `:22` answering by the time you investigate does not mean the deploy failed spuriously.

Tracked in [#469](https://github.com/tadasant/zimmer/issues/469).

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

### The database retry helpers miss most mid-flight connection deaths, and hold a thread longer when the pool is full

`DatabaseRetry` (`app/jobs/concerns/database_retry.rb`) and `ControllerDatabaseRetry`
(`app/controllers/concerns/controller_database_retry.rb`) retry `PG::ConnectionBad`,
`PG::UnableToSend`, `ActiveRecord::ConnectionNotEstablished` and `ActiveRecord::Deadlocked`. A
connection that dies *while a statement is in flight* — a Postgres restart, a failover, an admin
disconnect — usually raises none of those. `PostgreSQLAdapter#translate_exception`
(`postgresql_adapter.rb:818`) turns a libpq failure into `ActiveRecord::ConnectionFailed`, which
descends from `QueryAborted` → `StatementInvalid`, not from `ConnectionNotEstablished`, so it is not
on the list and the block is not retried. The translation keys on the libpq message: a
`PG::ConnectionBad` whose message does *not* end in a newline, or one matching `connection is
closed` / `no connection to the server`, becomes `ConnectionNotEstablished` instead and *is* retried.
So whether a given death is retried depends on the wording libpq chose.

It is mostly harmless, because the adapter itself reconnects: the *next* statement on that connection
verifies and reconnects, so the caller after this one succeeds. What is lost is this helper's retry —
the caller that hit the death still sees the error. Tracked in
[#779](https://github.com/tadasant/zimmer/issues/779).

The helpers deliberately do *not* reconnect by hand
([#708](https://github.com/tadasant/zimmer/issues/708)): `ActiveRecord::ConnectionTimeoutError` (the
pool is full) inherits from `ActiveRecord::ConnectionNotEstablished` (this connection is broken), so a
reconnect keyed on the parent class fires on exhaustion — leasing a *sticky* connection out of an
already empty pool, and on a GoodJob thread tearing down the Postgres session holding the job's
advisory lock.

The cost of leaving the retry in place is time. Under exhaustion each attempt blocks for the pool's
`checkout_timeout` (unset in `config/database.yml`, so the 5s default), and all three attempts now
run: a caller can hold its Puma or GoodJob thread for roughly 16s (jobs, backoff `0.5s + 1s`) or 15s
(controllers, `0.3s + 0.6s`) before giving up, against roughly 10s when the reconnect aborted the
loop early. That is a thread held longer precisely when threads are scarce — accepted deliberately,
because the alternative was permanently removing a connection from the pool.

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

### The docs guardrail does not look in the image's `tmp/`

🟡 `scripts/assert-docs-excluded.sh` — the check that keeps the documentation site out of the
published image, described in [The docs never ship in the image](/operate/deploying/#the-docs-never-ship-in-the-image) —
skips the top-level `tmp/` and `log/` of whatever tree it is pointed at. It has to: those are the
directories a running test suite scribbles scratch directories into, and one vanishing mid-walk
makes `find` exit non-zero and reddens the guardrail over an unrelated race.

For the build-context audit that is free, because `.dockerignore` excludes `/tmp/*` and `/log/*`
from the context anyway. For the `Dockerfile` assertion, which runs against `/rails` in the built
image, it is a real if narrow blind spot: `/rails/tmp` there holds whatever the build's own `RUN`
steps left behind (`assets:precompile` writes `tmp/cache`), so a `RUN` step that wrote a copy of the
docs into `/rails/tmp` would ship uncaught.

Nothing walks through that hole today, and it is the same class of gap as the `ADD`-from-a-URL and
`COPY --from`-an-outside-image routes the deploying page already names: all three need a deliberate
`Dockerfile` edit, which is a reviewed change, rather than the silent `.dockerignore` drift the
guardrail exists to catch.

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

### Transcript redaction is defense in depth, not a guarantee

🟡 `TranscriptRedactor` runs on every transcript as it is read, before anything is stored, rendered or
archived (see [Transcripts](/sessions/transcripts/)). It catches the credentials Zimmer itself issues by
exact value, and credentials with a recognizable shape by pattern. Neither tier is complete, and the
gap is worth naming precisely:

- **A secret with no shape that Zimmer never issued is not caught.** A password an agent read out of
  someone else's config file, the body of an `op read`, a session cookie captured during browser
  automation, an API key a user pasted into a prompt. There is no pattern for "arbitrary high-entropy
  string" here on purpose — one would shred ordinary output and destroy the debugging value that is the
  reason transcripts exist at all.
- **The known-value tier is only as fresh as its sources.** It rebuilds at most once a minute, and if
  the Parameter Store is unreachable it degrades to the shape patterns and logs a warning rather than
  failing the poll. A credential rotated seconds ago can pass through unredacted.
- **The generic name-then-value rule over-redacts sometimes.** `api_key: your_api_key_here` in a README
  an agent read gets scrubbed. That is the intended direction of the trade, but it does mean a redacted
  span is not proof a real credential was there.
- **A redaction reaches the agent's own memory, not just the archive.** When a clone is recreated,
  `AgentSessionJob#restore_regressed_transcript_if_needed` writes the stored transcript back to the file
  the runtime reads on `--resume`. That copy is redacted, so the resumed conversation contains
  `[REDACTED:…]` where the credential was — correct for a credential, and a real loss of context if the
  span was over-redacted.
- **Any `${VAR}` the catalog declares is redacted by exact value, whether or not it is a secret.**
  Today every one of them is (`SLACK_BOT_TOKEN`, `STRAD_API_KEY`, `ZIMMER_PROD_API_KEY`). The first
  externalized-but-not-secret variable — an org slug, a model id, a base URL — will start being scrubbed
  out of every transcript that mentions it.
- **A line the patterns cannot finish scanning is destroyed rather than redacted.** The rules carry
  their own 10-second timeout instead of Rails' global one-second cap. Both bound a single search, and
  the slowest single search any transcript here has produced is 2.2 s, so there is a factor of four in
  hand. If the 10 s is reached anyway, the pass retries line by line and replaces the offending line
  with `[REDACTED:UNSCANNABLE_LINE]` — the line count survives, nothing unscanned is emitted, and that
  line's content is gone. It is the least bad of three bad options; the other two are dropping the
  whole transcript update, which is what [#472](https://github.com/tadasant/zimmer/issues/472) was,
  and emitting a line no pattern finished looking at.
- **That guarantee covers the pattern pass, not the PEM block walk.** `scan_patterns` is the part that
  cannot raise on a timeout. The line walk that finds multi-line PEM armor still can, in principle:
  its three regexps carry the same 10-second timeout, but they are not rescued, because "assume a
  timeout means key material" closes a block at one of their call sites and opens one at another, and
  four different fallbacks for a case none of them can reach is worse than the gap. They are
  literal-prefixed or `\A`-anchored, so a non-armor line fails at the first character.

None of this changes what a transcript is. Do not treat one as safe to expose because it has been
through the redactor; the endpoint serving it still has no authorization check, and redaction lowers the
blast radius of a leak rather than preventing one.

Redaction is also irreversible and applies only from the moment it shipped. Transcripts captured before
that still hold whatever the agent printed until `bin/rails open_transcripts:redact_stored` is run
against them.

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

The same allowlist governs `dm_message` and the passive-listening types, where the open default is a
**wider** grant. Under `bot_mention` the practical bound is "somebody had to type `<@bot>`". Under
`passive_listen_thread` it is only "Zimmer has spoken in this thread", and under
`passive_listen_channel` only "Zimmer posted in this channel in the last 6 hours". Under
`dm_message` it is only "somebody opened a DM with the bot" — and on the DM path the allowlist is
enforced by *enumeration* (Zimmer polls only the allowed users' conversations) with no second check
behind it, so an unset allowlist means every workspace member's DM spawns a session. Nothing in the
Triggers form renders `allowed_user_ids`, so a condition created there always falls through to the
env var. Set the allowlist before enabling an all-channel passive condition, or a `dm_message` one,
on a workspace wider than your circle of trust.

### Triggers make the agent a trusted courier for untrusted input

[Issue #18](https://github.com/tadasant/zimmer/issues/18): there is nothing between "Slack event
arrived" and "agent running" except a `gsub` on a `prompt_template`. Untrusted Slack text is
interpolated into the prompt, and the agent is then trusted to act on identifiers it read out of that
text. No validation, no trusted identifiers.

Tracked in [#50](https://github.com/tadasant/zimmer/issues/50).

### Quoted PR comment context is allowlisted; the diff hunk is not

The [PR comment poller](/operate/background-jobs/#the-allowlist-covers-quoted-context-too-not-just-the-trigger)
withholds the *body* of any quoted comment whose author is outside `GithubCommentAllowlist`, because
a body is prose a stranger typed. Two things it does not cover:

An outside contributor's legitimate thread context goes into the same bin. A session woken by a
comment on a PR that a non-allowlisted person also commented on sees who spoke and not what they
said, and is told not to fetch it. That is the accepted cost of the gate, and the only way back is
to add the account to the allowlist — the same decision as letting them wake sessions.

The `diff_hunk` on an inline review comment is still interpolated into the prompt verbatim. GitHub
builds it from the PR's own branch rather than from anything the commenter typed, so the text is
code Zimmer's own agent usually wrote — but it is untrusted-adjacent on a PR from a fork, and
nothing labels it.

### A message queued by anyone coalesces a recurring trigger's next fire

[Coalescing](/sessions/triggers/#coalescing-a-repeated-fire) asks whether the reused session has
**any** pending message, not whether it has one this trigger queued. So a message a human (or another
session) queues onto a reused session also folds away that trigger's next scheduled fire.

Per-trigger provenance would not fix it. The rows that caused the 2026-08-29 incident were written by
`SpotSessionHold#queue_behind_scheduled_turn`, which holds a session and a prompt and has no idea
which trigger sent it — a `trigger_id` column on `enqueued_messages` would have matched none of them,
and the accumulation would have continued. The broad predicate is the one that actually catches the
bug, and it is the same one the `running?` branch has always used.

The cost is normally bounded at one occurrence: the session consumes its queue, and the next fire
lands. It is also no longer silent — the fold increments `missed_fire_count`. But "normally" is doing
real work in that sentence; see the next entry.

### A `waiting` session's queue has no sweep, so coalescing can wait on a turn that never comes

[Coalescing](/sessions/triggers/#coalescing-a-repeated-fire) skips the fire, and skipping the fire also
skips the **resume**. `Session#deliver_follow_up!` does two things to an idle session — it delivers the
prompt *and* it transitions the session to `running`, which is what eventually drains the queue. A
coalesced fire does neither.

For the case this was built for that is fine: a spot session held at the quota gate always has a
re-check job scheduled, so it takes a turn on its own. It is not fine in general, because **nothing
sweeps a `waiting` session's pending queue.** `EnqueuedMessage#deliver_if_session_already_idle` only
schedules a drain for a `needs_input` session; `HeartbeatSweepJob` does nothing for `waiting` and
explicitly skips a session that has pending messages. So a `waiting` reuse target holding a message
queued through the web form, the REST endpoint or MCP — none of which checks session state — can sit
there, with the trigger coalescing every fire against it.

Before this change the trigger's own fire resumed the session and incidentally un-stuck it. That was
accidental rather than designed, and it is the same resume that filed a duplicate prompt every time,
which is the bug being fixed. The honest position is that coalescing stopped masking a pre-existing
gap: the queue drain, not the trigger, is what should wake a `waiting` session. Tracked in
[zimmer#690](https://github.com/tadasant/zimmer/issues/690).

The mitigation is that it is loud rather than silent — `missed_fire_count` climbs and the alert fires
on the second miss, and the alert text tells the operator to check that something will actually make
the session take a turn.

### A coalesced fire runs the earlier prompt, so `{{date}}` in a reused template goes stale

When a recurring trigger's fire is [coalesced](/sessions/triggers/#coalescing-a-repeated-fire) into a
prompt the reused session is still holding, the prompt that eventually runs is the **first** one
queued, not the latest. For a template that interpolates `{{date}}` or `{{time}}`, the run therefore
carries the date of the night it was first queued rather than the night it actually executes.

Coalescing by refreshing the queued row's content instead would keep the interpolation current, but
Zimmer cannot tell which pending row belongs to which trigger — `enqueued_messages` records no
provenance beyond `origin`, and rewriting an arbitrary pending row would corrupt a message a human or
another session queued. Skipping is the safe direction to be wrong in: the work runs once with a
stale timestamp rather than twice, or not at all.

The mitigation is that the miss is no longer silent — `missed_fire_count` says how many occurrences
were folded together, so a stale date in a groomer's output has a visible explanation.

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

### The Pi runtime ships with the pi-extensions packages unpublished

🔴 Pi has no MCP, hooks or plugin support of its own. Zimmer supplies all three as Pi
extensions listed in `PiExtensions::REGISTRY`, but only one of the three is on npm today:

| Extension | State | What is missing without it |
| --- | --- | --- |
| `pi-mcp-adapter@2.32.1` | published, installed in the base image | — |
| `@tadasant/pi-hooks@0.1.0` | **not published** (404) | lifecycle hooks do not fire on Pi |
| `@tadasant/pi-plugins@0.1.0` | **not published** (404) | an AIR plugin's bundled artifacts do not activate on Pi |

`npm install` is all-or-nothing, so naming an unpublished package in `Dockerfile.base` would
404 and fail the whole base image. The two pending packages are therefore marked
`pending_publish` in the registry, `PiExtensions#resolved_paths` passes `pi -e` only for
entrypoints that exist on disk, and `PiExtensions.status_summary` reports the gap through
`CliStatusService` so the answer is reachable without a shell on the box.

**A Pi session today gets skills and MCP, and does not get hooks or plugins.** When
`v0.1.0` publishes, the fix is one `Dockerfile.base` line plus dropping the two
`pending_publish:` flags — no code change, and `pi_extensions_test.rb` asserts the
Dockerfile and the registry agree.

### A Pi session gets no per-server MCP status, no MCP OAuth, and no token-usage ingestion

🟡 Three things a Claude Code session gets for free do not reach a Pi session, all for the same
underlying reason — Pi keeps the relevant state somewhere Zimmer does not write or read:

- **No per-server MCP status.** Pi writes no MCP log files, and the `pi-mcp-adapter` extension
  routes every server through one `mcp` proxy tool, so a transcript shows `mcp` being called and
  never names the server behind it. `NullMcpStatusDetector` fills the bundle slot and reports
  nothing, so a Pi session's servers stay at their `pending` placeholder rather than turning
  green or red. (The slot is a null object rather than `nil` on purpose:
  `TranscriptPollerService` dereferences it unconditionally, so `nil` there would raise on every
  poll.)
- **No MCP OAuth credential delivery.** `mcp_credential_writer_class` is `nil` for Pi, because
  `pi-mcp-adapter` holds OAuth tokens in its own state rather than in a host-global file Zimmer
  owns. `McpOauthCredentialInjector#credential_store?` makes injection a logged no-op instead of
  a raise — which matters, because `McpOauthController#reinject_and_resume` calls injection and
  the resume service inside one `rescue`, so a raise would leave a Pi session parked on an OAuth
  gate permanently un-resumable. **An OAuth-backed MCP server does not work on Pi.**
- **No token-usage or cost ingestion.** `TokenUsageIngestionService` reads
  `~/.claude/projects`, which is Claude-specific, so Pi sessions contribute nothing to spend
  tracking.

### A Pi session's status summary always takes the cheap path

🟡 `SessionStatusSummaryGenerator#pool_exhausted?` asks the runtime's auth provider whether
its account pool has anything left, and falls back to a one-shot headless generation when it
does not. `PiAuthProvider` pools no accounts at all — Pi resolves a provider API key from the
session environment per request — so that question is always answered "exhausted" and a Pi
session's status summary is never generated by forking the session.

The outcome is right for the wrong reason. A fork would run on Pi and would need the same
provider key the (nonexistent) pool cannot vouch for, so the cheap path is the correct one
here. But it is reached by a predicate that means "the pool is empty" being asked of a
runtime that has no pool, rather than by anything that knows Pi does not pool credentials.

### Pi classifies fewer exits than Codex

🟡 `PiRetryStrategy` returns `false` from `context_length_error?`, `api_error_for_retry?` and
`auth_recovery_needed?`, so a Pi session gets no context-length compaction retry, no
API-error retry, and no auth recovery — everything the Claude path does to keep a session
alive, a Pi session does without. Failures are surfaced rather than hidden (they fall through
to `ProcessLifecycleManager`'s generic failure handling), and `classifies_exits?` is `false`
so the expected shape of a Pi failure does not raise a standing unclassified-exit page.

One of the three costs less than it looks: with no pooled accounts there is nothing for the
auth-recovery path to rotate *to*, so a working `auth_recovery_needed?` would have nowhere to
go. The other two are real gaps waiting on the Pi failure signatures being characterized.

`failed_resume_recovery_needed?` is a different case and is *correctly* `false`: Pi's
`--session-id` creates a missing session rather than exiting non-zero, so the Codex "no
rollout found" condition cannot arise. A lost transcript is handled instead by
`PiTranscriptSource#rotates_transcript_files?` being `false`, which makes a shortened read get
repaired from Zimmer's stored bytes before the resume.

### Failure classification is regex against CLI prose

🔴 Everything Zimmer knows about *why* a session died comes from string-matching English:

| What | Pattern | File |
| --- | --- | --- |
| Quota exhausted → rotate accounts, then park | `/hit your\b.*\blimit\b.*\bresets\b/i` | `api_error_retry_service.rb` |
| Unparseable tool call → retry with backoff | `/tool call could not be parsed/i`, `/tool call was malformed/i` | `api_error_retry_service.rb` |
| Auth lost → adopt/rotate/wait, respawn, then park | the `error` types `authentication_failed` / `oauth_error`, plus a prose net | `auth_recovery_service.rb` |
| Context overflow → compact and retry | a pattern list | `context_length_retry_service.rb` |
| Corrupted npx cache → delete it | `ENOTEMPTY`, `ERR_UNSUPPORTED_DIR_IMPORT` | `npx_cache_heal_service.rb` |
| Held runtime session id → resume it, or mint a new one | `/session id\b.*\balready in use/i` | `claude_retry_strategy.rb` |

The tool-call row is the one that *cannot* be anything but prose. Claude Code writes its report of an
unparseable tool call as a `<synthetic>` entry with no `error` field at all, so there is no type to
read — the residual risk is the mirror of the others: a genuine API-side error whose prose happens to
mention a malformed tool call gets retried six times before it pages, instead of paging at once. See
[Spawning](/sessions/spawning/#not-every-api-error-in-the-transcript-is-the-api).

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

The normal-completion branch is covered too. Claude exits 0 or 1 for a finished turn, so an exit
there is the one a stale classifier can hide behind — on 2026-08-20 a reworded auth failure ended
production session 6412 that way and left a human's message unanswered with nothing but the
transcript to find it by. `handle_exit` therefore asks a last question with no prose in it: *is the
last conversational entry in the transcript an API error?* If it is, the turn did not complete
however the runtime worded it, and the session fails — with the unmatched text in an alert when the
wording is one nothing recognises — rather than parking as finished. See
[Agent harness auth](/auth/harness/#a-turn-that-dies-on-an-api-error-can-never-look-finished).

Two gaps remain inside that, deliberately. A stale classifier still costs a **failed session** rather
than the recovery it should have got: the held-session-id row above is one of those — Claude reports
that refusal with exit 1 and writes nothing to the transcript at all, so no terminal API error exists
for the backstop to see and the only state check that catches it is the empty-turn restart (see
[Spawning](/sessions/spawning/)), which covers the first turn of a session and not a later one. And `CodexRetryStrategy` classifies nothing but a missing rollout, so
every ordinary Codex failure is by construction an exit no classifier matched; it answers
`classifies_exits? => false` and gets the loud log without a page, because paging on a runtime's
designed-for path is how a channel gets ignored. The terminal-error backstop reads Claude's
transcript format and `CodexRetryStrategy` does not answer the question at all, so Codex never
reaches it.

Tracked in [#53](https://github.com/tadasant/zimmer/issues/53).

### Telling you the pool is dead requires the pool

🟡 `needs_reauth` is reported by emitting the `account_needs_reauth` Zimmer event, which fires a
Trigger, which spawns a `general-agent` session holding the `slack-workspace` MCP server to send the
DM ([a dead account tells you so](/auth/harness/#a-dead-account-tells-you-so)). Spawning that session
needs a working account.

One dead account among six is fine — the pool rotates and the notifier session runs on any of the
others. A pool where *every* account is dead cannot spawn the session that would say so. Two things
bound it rather than fix it: the seeded trigger is `priority` rather than the `spot` that `ao_event`
derives, so the one session whose job is to report a dead pool is not itself gated behind a healthy
account under quota; and when the spawn fails anyway, `AoEventTriggerJob#handle_fire_failure` raises
an `#eng-alerts` post, which needs no account at all.

So the floor is a channel post rather than a DM. That is a real downgrade — a feed entry you scroll
past instead of a nag aimed at the person who can fix it — but it is not silence, and it is strictly
better than the native DM path it replaced, which failed silently for
[three different configuration reasons](/operate/background-jobs/#when-an-alert-is-a-dm-instead-of-a-channel-post)
none of which any health check looked at.

### Auth recovery can rotate away from an account that was fine

🟡 `AuthRecoveryCoordinator` reacts to the runtime saying "Not logged in" by moving the pool — it
rotates away from the identity that failed rather than re-injecting it (that re-injection loop is
what made the message user-visible three times in a row; see
[Agent harness auth](/auth/harness/#the-recovery-decision-tree)). But "Not logged in" carries no
structured reason, so the coordinator cannot always know *why* the identity failed.

It probes the outgoing account's refresh token before rotating, which separates a dead credential
(`needs_reauth`) from a live one, and it takes a live quota reading on the way past. Those are enough
to get the **park reason** right, and enough that a rotation no longer invents a `quota_exceeded`
label out of nothing — an account rotated past on `auth_recovery` whose reading is clear stays
`active` ([A rotation is not evidence about quota](/auth/harness/#a-rotation-is-not-evidence-about-quota)).

What remains, in three parts. The session still rotates away from an account that may have been
fine, so the pool moves for a rejection Anthropic might have served on the next call — that costs
the *session* a re-spawn and moves everyone else onto a different identity, but it no longer costs
the account its place in the pool. Because the account keeps that place, it is also the top-priority
candidate for the *next* rotation, so an account the runtime keeps rejecting while its credential
refreshes cleanly can be handed back and forth; per session that is bounded by
`AuthRecoveryService::MAX_RECOVERY_ATTEMPTS`, but nothing bounds it across sessions, and there is no
cooldown on a recently-rotated-away account. And when the reading genuinely does say a window is
spent, the label outlives the evidence — Claude's windows slide, so the account is servable again
before `QuotaResetCheckerJob`'s next sweep restores the column, up to 15 minutes of a healthy account
sitting out. The park decision and `auth_health` look past that last one ([One predicate for "is the
pool drained"](/auth/harness/#one-predicate-for-is-the-pool-drained)); the paths that pick an account
to spawn with do not, deliberately.

That is the deliberate trade: an unnecessary rotation costs one session a re-spawn, whereas
re-injecting a dead identity costs the user three visible auth failures and a park with the wrong
instruction, and a fabricated `quota_exceeded` costs the whole pool an account. Worth revisiting if
Anthropic ever exposes a structured reason.

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

### A deleted account's quota snapshots are kept forever

🟢 Deleting a `ClaudeAccount` detaches its quota snapshots rather than destroying them, so the
evidence of how the account behaved survives the delete-and-re-authenticate loop
([#241](https://github.com/tadasant/zimmer/issues/241), and
[Deleting an account keeps its history](/auth/harness/#deleting-an-account-keeps-its-history)). The
cost is that the delete used to be the only thing that ever removed a snapshot:
`claude_account_quota_snapshots` has no prune job, for live accounts either. A detached reading is
therefore permanent unless `claude_accounts:clear_all` takes it, and nothing reads it — the rate
metric skips detached rows on purpose, and `/quotas` only ever looks up snapshots by live account id.

Small in practice: snapshots are written on rotation, on a `/quotas` view, and by the reset checker,
so the table grows at operator pace rather than at session pace. The honest fix is a retention job
for the whole table, not a carve-out for orphans — deleting exactly the rows this change exists to
preserve would undo it.

Login attempts are the opposite shape and worth not confusing with this: `CleanupRuntimeLoginAttemptsJob`
hard-deletes every terminal attempt after a day, detached or not, so that history outlives its
account by at most 24 hours.

### An account whose label has drifted is back on the page before it is back in the pool

🟡 `/quotas` derives the badge it shows for an account from that account's own latest reading
(`ClaudeAccount#effective_status`, see
[The status column is sticky](/auth/harness/#the-status-column-is-sticky-the-badge-on-quotas-is-not)),
so a cleared account stops presenting as "Quota Exceeded" the moment a reading says so. The
`status` column it is derived *around* is what `ClaudeAccount.available` and `AccountRotationService`
read, and that still only changes when something writes to it: `QuotaResetCheckerJob`'s 15-minute
sweep, or `QuotasController#auto_heal_accounts` on a page load or refresh.

So there is a window where the page tells the truth and the pool has not caught up — an account
displayed as Active that rotation would still skip. It closes on the next sweep, or immediately if
you are the one looking at the page, since loading it heals. Making the pool itself derived would
mean joining every availability check to the latest snapshot per account and acting on a reading
that may be minutes old, which is the wrong trade for the path that hands an identity to a session.

Two edges of the same asymmetry are worth knowing. A page load restores the **account** but does not
resume the sessions parked on it — only `QuotaResetCheckerJob` calls
`AuthOutageParkService.wake_parked_sessions!`, so those sessions wait for the sweep or their own
timer. And the derivation needs a reading to work from, which **Codex accounts never have**: nothing
snapshots quota for that runtime and the sweep is Claude-only, so a Codex account marked
`quota_exceeded` on rotation keeps the label and stays out of its pool until something else moves it.

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

### A parked session waits for one event, and only that event

🟡 When the login pool runs dry, `AuthOutageParkService` parks the session and creates nothing — no
timer, no per-session trigger (see [Agent harness auth](/auth/harness/#when-the-pool-runs-dry)). What
wakes it is the `quota_available` edge, fired once per recovery, which spawns one fleet-maintenance
session that starts spot work in precedence order. Parked **priority** sessions keep a direct sweep
of their own every fifteen minutes.

That removes the wake → fail → re-park cycle the timers produced, and with it the dozens of
`Auth outage retry for session #N` rows the trigger list used to carry. It also concentrates the
whole spot wake into one event, and the sharp edges are all about that concentration:

- **A missing or broken fleet trigger stalls the whole spot queue.** The trigger is seeded by a
  migration and points at the `fleet-maintenance` agent root; if it is deleted, disabled, or its root
  does not resolve, no spot session wakes. A fire that delivers no session **re-arms** the edge
  (`QuotaAvailabilityMonitor.rearm!`) so the next sweep tries again rather than spending the one
  chance — but a permanently broken trigger is a permanently stalled queue, visible only as spot
  sessions sitting in `waiting`.
- **The trigger defers to its own pending session, and a stuck one holds the queue.** The seeded
  trigger has [`skip_if_pending_session`](/sessions/triggers/#skip-while-a-session-is-still-pending)
  on, because the fleet session it spawns is itself parked by the exhaustion it exists to answer —
  without it, every recovery stacked up another sibling carrying the identical prompt (102 sessions
  on the trigger, ten of them in one afternoon). The cost is that a fleet session which never takes
  its turn and never leaves `waiting` suppresses every later wake, and unlike a broken trigger this
  one re-arms nothing: a skip counts as handled, deliberately, or the edge would be spent and put
  back on every sweep forever. Archiving or failing the stuck session releases it, and the trigger
  page names the session it is deferring to.
- **An auth park is woken by different evidence than a quota park**, and only the quota one has an
  edge of its own. `accounts.available` never goes false→true for a rejected identity, so a *spot*
  session parked `auth_unrecoverable` is woken only because the fifteen-minute sweep notices its pool
  fingerprint changed and asks for the wake on its behalf. Between sweeps it waits.
- **The fingerprint is coarse in both directions.** It cannot see an outage that heals on Anthropic's
  side without touching an account row, and it fires on credential changes that are not repairs at
  all — the five-minute `sync_current_account_tokens!` adopting a token the CLI rotated on disk moves
  the same digest. `MAX_EARLY_WAKES` (3) per `EARLY_WAKE_WINDOW` (6 h), deliberately not reset by a
  re-park, is what makes that survivable rather than exact. Past the budget the session stays parked
  until a human resumes it or the pool changes enough for a later sweep to grant one.
- **Codex has no quota API**, so a parked Codex session is never woken by a quota edge at all — its
  pool is read for availability only.
- **`auth_outage_pool_recovers_at` is an estimate, not a schedule.** It is derived from
  `ClaudeAccountQuotaSnapshot#reset_5h` / `reset_7d` for a quota park, shown in the banner, and read
  by nothing.
- **A window at its utilization limit defers the wake for as long as it holds.** The edge fires only
  when the pool has recovered *and* no quota window is holding spot work at `at_utilization_limit`,
  because starting spot work is all the fleet session can do — see [When the pool runs
  dry](/auth/harness/#when-the-pool-runs-dry). The deferral is re-asked every fifteen minutes and
  costs no edge, but a weekly window whose spot budget is spent holds for days, and every parked spot
  session waits out that whole stretch. That is the correct outcome — none of them could have
  started — and it is still a wake that does not happen. Parked *priority* sessions are not affected:
  the same sweep resumes them directly.
- **The deferral is a spot-shaped precondition on an event anyone can listen to.** `quota_available`
  is a user-configurable `system_event`, and the check is applied when the event is *fired*, not per
  listener. An operator trigger that listens on it to do **priority** work is therefore deferred by
  the spot gate too, even though nothing would have held that work — the event's contract is now "the
  pool recovered and spot work can run", and there is no way for a trigger to opt out of the second
  half. The shipped `fleet-maintenance` wake is the only listener on this deployment, so today this
  costs nothing.

### The idle-fleet event is sampled, latched and floored, and each of the three has an edge

🟡 [`no_sessions_in_progress`](/sessions/triggers/#no_sessions_in_progress) fires when the deployment
has had nothing to do for five minutes. Idleness is a level rather than an edge, so `FleetIdleMonitor`
manufactures one — and the machinery that does it has known limits:

- **It is sampled once a minute, so the clock starts up to a tick late.** `fleet_idle_since` is
  written at the first observation with nothing to do, not at the moment the last session finished,
  so "five continuous minutes" is really "five minutes since we noticed", ±60 seconds. The
  `SessionStateMachine` hook closes the opposite gap — a session that starts and finishes between two
  ticks still re-arms — but nothing narrows the start.
- **One stuck `waiting` spot session suppresses it indefinitely.** A queued spot session counts as
  work in hand, deliberately, so a session stranded in `waiting` that nothing will ever start (see the
  hold and park edges above) also means the fleet never reads as out of work. Status-summary forks are
  excluded for exactly this reason; nothing else is.
- **The hourly floor is a blunt instrument.** `MIN_FIRE_INTERVAL` exists because the session the
  event spawns re-arms the latch by running, so without it a quiet deployment would get one spawn
  every five minutes or so, forever. One hour is a number chosen to be obviously safe rather than
  tuned, and it applies even when the previous fire delivered nothing.
- **Neither column is surfaced anywhere.** `fleet_idle_since` and `fleet_idle_event_fired_at` are
  readable only from the database, so "why has this not fired?" is not answerable from `/health`,
  `get_system_health`, or any page. The monitor logs its transitions, and that is the whole story a
  human gets.

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

### A fresh start after a lost rollout is silent, and the agent has no history

`CODEX_HOME` is a durable volume, so a deploy does not destroy in-flight Codex conversations. A
rollout can still go missing — a recreated volume, a disk sweep, Codex's own retention — and when
it does, `ProcessLifecycleManager#handle_failed_resume_recovery` starts a new
conversation carrying only the prompt that triggered it. Zimmer's timeline stays whole (the poller
carries the stored transcript forward), the process exits 0, and the session parks in `needs_input`
exactly as a completed turn does. Nothing in the *conversation* says the history is gone.

So the user sees an agent that has forgotten what it was doing, with no way to tell that apart from
an agent that answered badly. The recovery is logged at `warning` on the session, which is one pane
away from where the symptom appears. Restoring the prior transcript into the fresh conversation, or
marking the discontinuity in the timeline, is unbuilt.

### The approval gate can only be verified as far as Zimmer's own doorstep

`ELICITATION_REQUEST_URL` and `ELICITATION_SESSION_ID` reach a stdio MCP server on both runtimes —
`CliSpawnEnv#apply_elicitation_env` puts them on the agent process, and
`RuntimeConfigPostProcessor#inject_elicitation_env!` writes them into the server's own `env` table in
the generated config, which is the only channel Codex honors. `ElicitationEndpointHealthCheckJob` proves
every 5 minutes that the endpoint answers from the host agents run on. Neither proves that a given
MCP server *used* those variables: a server that hard-codes its own URL, or one already running from
before the change, still posts into the void and still returns a redacted value. What is guaranteed
now is that the failure is not silent on Zimmer's side — the system prompt of every session spawned
while the gate is down says so, so a redaction is never read as a policy decision. A session already
running when the gate breaks reads the status from its spawn and will not learn of it.

Fixed in [#55](https://github.com/tadasant/zimmer/issues/55) and
[#397](https://github.com/tadasant/zimmer/issues/397). What survives is the edge of what Zimmer
can verify from its own side, which no issue closes.

### On Codex, a clone's `.env` reaches the agent but not its stdio MCP servers

Codex rebuilds every MCP server's environment from `HOME`/`LANG`/`PATH`/`PWD`/`SHELL` plus what the
config entry's own `env`/`env_vars` name, so nothing Zimmer exports to the agent process is inherited.
Zimmer bridges exactly the names it knows a server needs: the two `ELICITATION_*` variables (written
into each stdio entry's `env` by `RuntimeConfigPostProcessor`) and `SSH_PRIVATE_KEY_PATH` (forwarded
via `env_vars` by the Codex post-processor). Anything else an operator puts in a clone's `.env` reaches
the agent and, on Claude, the servers that inherit its environment — but on Codex it stops at the agent.

The asymmetry is silent, which is the part worth knowing: a server that reads a variable it never
received behaves as if the operator never set it. A catalog entry that names the variable in its own
`env`/`env_vars` is the way through today.

### The npx bin-permission repair only reaches Claude sessions, and only on the next launch

`NpxBinExecutableGuard` restores the execute bit on `_npx` bin targets that a package published
without one — the failure that orphaned production session 4388 three times in 31 minutes
([#467](https://github.com/tadasant/zimmer/issues/467)). Two edges come with it.

It runs from `ClaudeSpawnEnv#configure_mcp_env`, so a Codex session never calls it. A Codex session's
npx servers do install inside the clone — `RuntimeConfigPostProcessor` writes `NPM_CONFIG_CACHE` into
each entry's own `env` table, so the guard's clones-base safety check would accept the paths — but
nothing on the Codex spawn path invokes the guard, so a bin target that lost its execute bit there
stays broken.

And it repairs the tree it finds on the way *in*, so a package that installs broken during a launch
is repaired on the launch after it — the retry `AgentSessionJob#schedule_mcp_retry` already schedules.
A session recovers by itself; it does not connect on the first attempt.

### A cold clone pays the npm download for every npx MCP server

`RuntimeConfigPostProcessor` points each npx MCP server's `NPM_CONFIG_CACHE` at the session's clone.
`NPM_CONFIG_CACHE` moves the *whole* npm cache, not just the `_npx` install root — `_cacache`, the
tarball store, comes with it. So the packages `bin/preinstall-mcp-packages` warms into the image's
`~/.npm` at build time are not read by any MCP server, and the first launch in a fresh clone fetches
every one of them from the registry.

That has been the case on Claude since the per-clone cache landed, and Claude absorbs it with
`MCP_TIMEOUT=180000` (3 minutes). Zimmer sets no equivalent for Codex, whose own default startup
timeout is much shorter, so a Codex session on a cold clone is the case most likely to time out on a
large package. Tracked in [#702](https://github.com/tadasant/zimmer/issues/702).

The fix is not to un-pin the cache — a host-shared cache is what
[#595](https://github.com/tadasant/zimmer/issues/595) was — but either to warm the clone's cache at
prepare time or to give Codex entries an explicit startup timeout.

### No extension can ship in a built image

`.dockerignore` excludes `/app/extensions/*/`, so an extension added to `app/extensions/` is absent
from the Docker image: `ExtensionRegistry` skips the class that no longer resolves, and every seam
falls back to native behavior. A deployed Zimmer therefore cannot run any extension, and a setting
behind one cannot be changed on the deployed app — which is why MCP tool search is a plain
`AppSetting` column rather than the extension it used to be.

Tracked in [#91](https://github.com/tadasant/zimmer/issues/91).

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

🔴 This has already fired once. The Claude CLI self-updates on the worker, and `2.1.232` started
rendering its authorization link as an OSC 8 hyperlink — which the parser mangled into a URL no
browser could open, breaking UI logins with no Zimmer deploy and no failing test. What the parser
now tolerates, and how to capture output when it drifts again, is in
[Auth harness](/auth/harness/#the-screen-scrape-is-only-as-stable-as-the-clis-output).

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
10. `invalid_grant`'s two meanings are separated only by an `error_description` string. Zimmer keys on
    `/expired|revoked/i` to tell a dead credential from a spent value; if Anthropic reworded that
    field tomorrow, every rejection would read as merely stale and a genuinely dead account would take
    three strikes to surface instead of one. Nothing detects the rewording.

Tracked in [#58](https://github.com/tadasant/zimmer/issues/58). None of this can be *fixed* — there is
no public API to fix it against — so the issue asks for a canary that fails loudly when one of these
facts stops being true.

---

## A dead pooled account takes about half an hour to reach you

`ClaudeAccount#refresh_token!` no longer condemns an account on a single `invalid_grant` whose body
says only that the value it presented was rejected — that mistake accounted for 14 of the 15
`needs_reauth` marks over an eleven-day window and made Tadas re-authenticate the same live account
four times in a fortnight ([#530](https://github.com/tadasant/zimmer/issues/530)). It now takes three
such rejections, spread across at least 15 minutes each, before the account is marked.

The cost is on the other side. An account whose credential really is dead, in the way that does *not*
say "expired" — revoked out of band, or a chain Zimmer orphaned before the fix landed — stays `active`
for at least half an hour while the strikes accumulate. Two strikes must be 15 minutes apart and the
sweep runs every 5 minutes, so the floor is ~30 minutes and the usual case is 30–45. During that
window rotation can hand a session an account that cannot mint an access token. It is a deliberate
trade of a slower true positive for far fewer false ones, not an oversight.

The strikes are on `claude_accounts.stale_refresh_failures` / `last_stale_refresh_failure_at`. They
are on the account's Administrate record page but **not** on `/quotas`, which is where anyone actually
looks — so "why is this account still active when every refresh fails?" is a question `/quotas` cannot
answer.

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
runtime never attempts a refresh that would name the failure. That retries to the limit and then
[leaves the server out](/air/mcp-servers/#when-a-server-cannot-connect-the-server-is-left-out-not-the-session)
(raw error surfaced in the session log) with **no** Authorize button offered; the session runs on
without that server's tools, and the credential must lapse or be deleted before re-authorization is
presented again. The predicate is still `McpOauthServerAuthorization.authorized?` (active credential
exists), not "the server accepted it".

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

### AIR parses the config files it just wrote without a guard, and names no file when it fails

`@pulsemcp/air-sdk` `JSON.parse`s each of the adapter's `configFiles` — `.mcp.json` and
`.claude/settings.json` — with no `try`/`catch` in `transform-runner.js`, and `@pulsemcp/air-core`
does the same for `air.json` and the catalog indexes. Every parse of those same two config files
inside the *Claude adapter* is guarded; the SDK's and core's are not. So a failed parse exits 1 with
Node's bare parse error — no path, no file, nothing to act on.

For the two files in the target directory it is only reachable as a race, which was verified against
the pinned CLI: neither an already-corrupt `.mcp.json` nor an already-corrupt `.claude/settings.json`
reproduces it, because the adapter rescues its own parse failure and rewrites both from scratch
before the SDK reads them. It takes a second writer changing one between the adapter's write and the
SDK's read, which `air prepare` invites by running over a session directory a previous job may still
be tearing down. A malformed `air.json` or catalog index reaches the same signature by a different,
deterministic route.

Zimmer cannot fix the upstream parse, so it treats the signature as transient, retries it, and
prepends its own description of the target's config files to the error (skipped when AIR's message
already carries a path). That is a workaround for a message that should have carried one: if AIR ever
adds it, the enrichment becomes redundant rather than wrong. Tracked upstream of Zimmer's fix in
[zimmer#590](https://github.com/tadasant/zimmer/issues/590). First seen in production 2026-08-21 (session 6787), which was ~16 hours into a task
on a clone already prepared many times. The unhandled error failed the whole job; what recovered it
was Zimmer's orphan cleanup restarting the session ~20s later, at the cost of a full MCP reconnect
mid-work — not anything the prepare path chose.

### The environment configs describe a catalog that no longer exists

`production.rb` and `staging.rb` comments say `air.production.json` *"uses `github://` URIs to pull from
tadasant/zimmer-catalog."* It doesn't — it's entirely local paths. All of `AirCatalogService`'s
github-cache machinery (catalog pins, `resolved_sha_for`, `pinnable_catalogs`) is dormant
infrastructure, and its tests skip themselves.

Tracked in [#69](https://github.com/tadasant/zimmer/issues/69).

### A background thread inside Puma, to fix a container mismatch

`~/.air/cache` is per-container, and the `*/15` refresh cron runs only in the worker — so the web
container's catalog would drift stale for a full deploy cycle. `PeriodicCatalogRefresher` runs a bespoke
background thread *inside Puma* every 300s to compensate. It waits on a `Concurrent::Event` rather than
sleeping, so `stop!` wakes it immediately and an in-flight `air update` runs to completion instead of
being killed mid-write — see
[The streaming thread is asked to stop, never killed](/sessions/spawning/#the-streaming-thread-is-asked-to-stop-never-killed)
for why an asynchronous kill on a thread that touches the database is not an option.

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
sessions would dial a dead host and — after `RetryBudget::MCP_CONNECTION` is spent — be failed outright
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

### A retired queued message is recorded, not re-delivered

Archiving a session moves whatever is still queued for it to `undelivered`
([lifecycle](/sessions/lifecycle/)). That closes the silence — the archive line names the messages,
an alert fires (unless the caller forced past the archive guard, having been shown the messages —
that discard is recorded on the log plane instead of paged), and the queue can no longer claim a
delivery that is not coming — but nothing
re-routes them. If the session is later unarchived, the retired messages stay retired: `undelivered`
is terminal precisely so a weeks-old message cannot arrive as if it had just been sent. Getting the
content acted on means someone re-sending it.

Every caller-facing archive surface refuses over a queued message in every state, and `force` is the
deliberate override ([lifecycle](/sessions/lifecycle/)) — so the retirement path runs on a forced
archive or a system-initiated one, and in both cases someone or something has already decided the
message is going. What it does not do is re-route the content: getting it acted on still means a
human re-sending it.

**Deleting a session is the uncovered path, and it is worse than archiving one.** `DELETE
/api/v1/sessions/:id` and its web twin consult nothing, and `Session has_many :enqueued_messages,
dependent: :destroy` means the rows are destroyed outright rather than retired — so there is no
`undelivered` record, no archive line naming what was lost, and no alert. Now that every archive
surface refuses, delete is the only caller-facing way left to drop a queued message in silence.

System-initiated archives — `HealthMonitorService`'s stale sweep, status-summary fork cleanup,
`SessionStatusSummaryHarvestJob` — do not consult the guard at all, so they discard silently apart
from the record the retirement leaves. That is deliberate (a refusal they could hit would be a
fleet-wide stuck state with no human to clear it), but it does mean a queue on a session the stale
sweep reaches is discarded without anyone being asked.

Nothing stops a *new* `pending` row being created for an already-archived session either — the three
`create` surfaces have no session-status guard, unlike `follow_up` and `send_now`, which reject an
archived target. That re-creates the stranded state after the archive callback has already run.
Tracked separately in [#549](https://github.com/tadasant/zimmer/issues/549). Those same surfaces are
equally unguarded against a session in `needs_input`, but that case is now handled rather than
refused: an `after_create_commit` hook schedules the delivery, because an idle session is exactly
the condition the message is waiting for.

### Three states still hold a queued message on an idle session

A session no longer comes to rest in `needs_input` with a message queued for it — the `pause`
transition schedules the delivery ([lifecycle](/sessions/lifecycle/)). The invariant has edges.

`EnqueuedMessageDrainJob` refuses to deliver in three states, and in each the message waits for that
state to clear rather than for anyone to notice: blocked on an MCP elicitation (the agent process is
still alive), parked by `AuthOutageParkService` on a quota or auth wall, and `paused_by: "mcp_retry"`
with a retry already scheduled. Each is the right call — delivering would spawn a second process
against one clone, or burn the message on the wall that caused the park — and each ends in the
message going out on the turn that follows. But a park that never clears holds the message
indefinitely, and nothing says so.

Only `needs_input` is covered. A session that pauses straight into a scheduled sleep goes dormant in
`waiting` with its queue intact, which is correct — it has a wake armed, and that wake's turn drains
the queue — but a session whose wake is later destroyed keeps the message with it. A session in
`failed` holds its queue too; the recovery sweeps prefer a queued user message when they
auto-continue one, so it usually goes out, but only if a sweep reaches the session.

The terminal case is an alert, not a resolution. After three failed attempts the job stops and pages,
leaving the messages `pending` — deliberately, because they are still deliverable and retiring them
to `undelivered` would destroy a message to record that one job could not deliver it. What that means
in practice is that the invariant is restored by a human giving the session a turn, and until then
the session is idle with work queued for it — and any session watching it for `session_needs_input`
is woken, because a session stuck at rest is a rest (see the settle-window entry below).

### A `session_needs_input` wake arrives up to 30 seconds late

`pause` fires at every turn boundary, including boundaries the session leaves again microseconds
later, so `session_needs_input` is held for `SessionStateMachine::NEEDS_INPUT_SETTLE_WINDOW` and
dropped unless the session is still at rest when the window closes — see
[a turn boundary is not a rest](/sessions/lifecycle/#a-turn-boundary-is-not-a-rest).

The cost is latency on the one event that can flap. A session waiting on a peer that pauses to ask a
question learns about it up to 30 seconds after the fact, and `AoEventTriggerJob` runs on its own
queue precisely *because* wakes are latency-sensitive. `session_failed` and `session_archived` are
not settled and still fire on the transition, so the event that ends most waits — a child
self-archiving — is unaffected. Broadcast (unscoped) `session_needs_input` conditions inherit the
delay too, which matters for a trigger that spawns a session on any autonomous session going idle.

The window is a constant with no per-trigger override, on the grounds that no caller wants a wake
about a state the watched session had already left. If a use case ever does need the un-settled edge,
it needs a new option rather than a smaller constant.

There is a second edge in the other direction. The rest check is status-only, so a session whose
queued message is still undelivered when the window closes — the three states below — **does** wake
its watchers. That is deliberate: nothing re-emits this event, so suppressing there would lose the
wake rather than delay it. The consequence is that the three states below now also mean a watcher
gets woken about a session that is idle with work stuck behind it, which is the honest signal but not
a finished one.

### 🔴 Every turn a session finishes costs a second agent turn, for the Status summary

The [Status summary](/sessions/status-summary/) is generated by **forking the session** — copying its
clone directory and running one more agent turn against the copy. The automatic trigger is the
session coming to rest, and every turn a session completes ends in exactly that transition. So on a
busy fleet the steady-state cost is roughly one extra agent turn and one extra repository copy **per
completed turn, per session**, until the fork is harvested and archived.

That is the design that was asked for, and the fork is what makes the summary specific enough to link
to a message index rather than paraphrase. But it is not a cheap feature, and there is no rate limit,
no minimum interval, and no off switch beyond not looking at it. On the automatic path
`SessionStatusSummaryGenerator` refuses when the session has not moved since the last summary — which,
on a turn boundary, it always has — when the session is in the trash, when its clone has been
reclaimed, and when there is structurally nothing to summarize (no transcript, or a session that is
itself a summary fork).

Mitigations already in place: only resting transitions trigger it (a resume into `running` does not),
a generation already in flight is never duplicated, the copy leaves out installed-dependency trees
(`vendor/bundle`, `**/node_modules`) that the summarizer never uses, the fork is archived immediately
on harvest so the clone copy is reclaimed on the normal trash path, and rendering the panel or reading
the session over MCP/REST never generates.

### A regenerated summary for an old session is written in an empty directory

Pressing **Regenerate** on a session archived long ago works, but not by restoring anything.
`DeferredCloneCleanupJob` deletes an archived session's clone once the ten-second undo window closes,
so there is no working tree left to fork; the fork is given an **empty, freshly `git init`ed
directory** to run in instead (empty so there is nothing to read, a repository because `codex exec`
refuses to start outside one), and answers from the conversation Zimmer forked it with.

That is sound for the summarizer, which is told not to run tools — but it is a real constraint on what
the blurb can contain. A summary fork for a session whose clone is gone cannot read a file, check out
a branch, or run `git log` against any real history; anything not in the transcript is not available
to it. In practice the
prompt already forbids all of that, so the difference shows up only if the summary prompt ever grows a
step that touches the filesystem. It would silently degrade for exactly the old sessions this path
exists to serve.

The scaffolded directory belongs to the fork, is reclaimed when the fork is archived on harvest, and
nothing about the source session is restored, mutated, or left behind. See
[Status summary](/sessions/status-summary/#what-a-scaffolded-fork-leaves-behind).

### The last-moment clone ownership check can refuse a legitimate delete

Every clone deletion by a reaper goes through `CloneReaper`, which re-asks the database who owns the
directory at the instant of deletion and refuses if a live session still does — see
[A clone is only deleted if nobody live still owns it](/operate/background-jobs/#a-clone-is-only-deleted-if-nobody-live-still-owns-it).
It closes the window that destroyed three sessions' uncommitted work on 2026-09-02
([#808](https://github.com/tadasant/zimmer/issues/808)), and it is deliberately biased toward
refusing.

Two ways that bias costs something:

- **Ownership is matched on the basename as well as the path.** That is what makes the check immune
  to a `clone_path` stored under a relocated or symlinked base. Clone basenames carry a timestamp and
  four random bytes, so a collision is effectively impossible — but if one ever happened, the guard
  would refuse to delete a genuinely dead clone because an unrelated live session shares its name.
- **It fails closed.** If the ownership query cannot be answered — the database is down, the
  connection pool is exhausted — nothing is deleted for as long as that lasts. Under sustained disk
  pressure that is the worse of the two failures to have chosen, because `CloneDiskGuard`'s
  reclamation path cannot free anything either.

Both cost disk, and disk is reclaimed by the next sweep. The alternative failure is a running agent's
uncommitted work, which exists nowhere else.

That bias is also why the failed-clone rollback paths (`GitCloneService#discard_failed_clone`,
`ForkSessionService#discard_partial_clone`) deliberately do **not** go through the guard. They
dispose of a directory the caller just created and no session references, so there is nothing to
protect — and a refusal there would leave a partial tree that makes the next `git clone` fail with
"destination path already exists", which is not classified as transient, turning a retryable clone
failure into a permanent session failure.

An unarchive is protected by a **time-bounded marker**, not by its status: `unarchive_started_at` is
honoured for `Session::UNARCHIVE_GRACE_PERIOD` (30 minutes). An unarchive that somehow outran that —
a `git clone` riding out the full timeout plus every retry, behind a very slow artifact replay — is
back to being reapable while it is still running. The bound is the price of not letting an unarchive
that crashes between the stamp and the `ensure` pin a clone on disk forever.

### A clone delete that cannot rename falls back to a non-atomic in-place delete

Clone deletion goes through `AtomicCloneRemoval`: the clone is renamed to a sibling
`<clone>.deleting-<hex>` tombstone and the tombstone is deleted. `rename(2)` is atomic within a
filesystem, so an interrupt — a deploy, a SIGTERM, the worker container being recreated — leaves
either the whole tree at the clone's path or nothing at it, never a half-tree wearing the clone's
name. Whatever is left behind is a tombstone, which no consumer resolves and which the sweeps in
`StaleCloneCleanupJob` (hourly) and `OrphanCloneFilesystemCleanupJob` (six-hourly) reap.

The residue is the case where the rename itself cannot be done — a cross-device rename (`EXDEV`, if
the clones base were ever a mount point with the clone below it) or a permission error. Skipping the
delete there would leak the bytes forever and, on the archive path, leave a caller believing the
clone is gone, so the fallback is the old in-place `rm -rf`. In that narrow case an interrupt can
still mangle the tree — the pre-existing hazard, taken visibly rather than silently. Two things make
it visible: it logs at `.error`, which is loud enough to page; and it drops a sibling
`<clone>.deleting-<hex>` marker *file* before deleting, so an interrupt leaves a half-tree that is
labelled and reapable rather than anonymous. The marker is removed when the delete finishes. That
labelling is also what makes "the fallback did not fire" a checkable claim — it is how #808 was
triaged, and it is only worth anything if the line is loud enough to have been there.

Two smaller edges remain. The tombstone is only unresolvable by *name*: a process that already holds
an open path inside the clone keeps reading it as the tree is unlinked. And the per-session
directories `StaleCloneCleanupJob` sweeps — scratch, the Claude config dir, the two prompt-attachment
trees — are still deleted in place; they are not clones and nothing resolves a partial one as state,
but an interrupt there still leaves a subset behind.

The guards from [#411](https://github.com/tadasant/zimmer/issues/411) stay in place either way:
archive does not preserve a mass-deletion tree as uncommitted work, and unarchive refuses to replay
one. Historically this was not rare — on 2026-08-12, the day that guard shipped, it defused nine
clones across nine sessions in one afternoon, and a read-only scan of the production clones directory
that evening found 20 of 87 clones carrying a mass-deletion tree, both figures recorded in
[#415](https://github.com/tadasant/zimmer/issues/415). `MangledCloneReportJob` is what keeps that
number visible day to day, and with the origin fixed in
[#412](https://github.com/tadasant/zimmer/issues/412) it is the signal for whether anything still
produces one.

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

### A failed artifact preservation holds a whole clone for four days

When `CloneArtifactService#create_artifacts` fails, `DeferredCloneCleanupJob` cannot delete the clone
— it is the only remaining copy of that session's unpushed work — so it holds it for
`TRASH_RETENTION_PERIOD` and lets `EmptyTrashJob` reap it at the deadline. The alternative, deleting
the work because the copy of it failed, is worse. What the hold costs, for as long as it lasts:

- The clone's `.env` sits on disk for four days rather than the hour `StaleCloneCleanupJob` would
  have taken, and [that file carries the real Slack bot token](#every-agent-session-clone-carries-the-slack-bot-token-and-the-alert-channel-id).
- So does the whole tree, `node_modules` and `vendor/bundle` included, with nothing capping how many
  such clones accumulate.
- The session's Docker Compose resources stay up until the deadline, because teardown happens on the
  delete path this branch returns before. (`EmptyTrashJob` does tear them down; the one-hour stale
  sweep never did, so the hold trades a longer leak for one that actually ends.)

Unarchiving inside the window takes `UnarchiveSessionService`'s quick path, which adopts the clone
as it stands — it applies none of the mass-deletion validation the artifact path applies, so a clone
that is itself mangled is restored mangled. Preservation failing at all is loud: it logs at `.error`
and writes a `warning` to the session's own log.

### A status-summary fork's clone is missing its installed dependencies, and does not know it

Summary forks exclude `vendor/bundle` and `**/node_modules` from the copy, because the summarizer
reads a conversation and never builds or boots anything. Two edges come with that:

- `.bundle/config` **is** copied, and it points `BUNDLE_PATH` at the `vendor/bundle` that is now
  absent, so any `bundle exec` or `bin/rails` inside a summary fork fails with "Could not find gem".
  The prompt tells the fork not to run tools, but that is an instruction, not a constraint.
- For a repository that *tracks* either directory in git (Zimmer's own does not), the pruned clone
  reads as dirty to `CloneArtifactService`, so `DeferredCloneCleanupJob` preserves artifacts and holds
  the clone for `TRASH_RETENTION_PERIOD` instead of deleting it immediately.

Neither affects a user-initiated fork, which copies the tree whole apart from the directories no copy
can relocate — see below.

### A copied clone drops the virtualenv, and only the virtualenv

`NonRelocatableClonePaths` keeps a clone copy — a fork, or `clones:relocate` — from carrying a Python
virtualenv whose console-script shebangs name the clone it came from
([#671](https://github.com/tadasant/zimmer/issues/671), and
[A copied clone sheds what it cannot relocate](/sessions/spawning/#a-copied-clone-sheds-what-it-cannot-relocate)
for why that failed silently). Four edges come with it:

- **It is prospective.** A clone relocated before this shipped still holds an environment pointing at
  its predecessor. Nothing sweeps for those, deliberately: deleting a directory inside a live
  session's working tree is the exact hazard the copy-never-move rule exists to avoid. `rm -rf .venv
  && uv sync` repairs one.
- **A fork of a Python repo starts without an environment**, and finds out when it runs something.
  That is the trade the fix makes — a loud failure that a warm `uv sync` clears in seconds, in place
  of a silent one that runs the wrong checkout's sources.
- **Only virtualenvs are detected.** They are matched by their `pyvenv.cfg` marker plus the `bin/` or
  `Scripts/` directory beside it, which together are definitive. Nothing else is: npm and pnpm write
  `node_modules/.bin` shims as *relative* symlinks with `#!/usr/bin/env node` shebangs, so they
  survive relocation, and blanket-dropping `node_modules` would cost every fork a reinstall to fix a
  hazard that layout does not have. A tool that wrote absolute paths into an ignored directory would
  still be carried, and would need its own detector.
- **A repository that *tracks* a whole virtualenv would have it pruned from the copy.** The script
  directory in the detection rule is what keeps a tracked bare `pyvenv.cfg` fixture out of it, but a
  committed environment is indistinguishable from an installed one. The fork's tree would then be
  missing tracked files, which `CloneArtifactService` reads as deletions — and a committed
  environment of 50+ files, deleted with nothing else changed, trips the
  [mass-deletion guard](#a-session-that-deletes-50-tracked-files-and-nothing-else-loses-those-deletions-on-archive) on a clone that
  is merely pruned. The source clone is untouched either way. No repository Zimmer runs does this.

The scan that finds them walks the source tree once before the copy, skipping `.git`,
`node_modules`, `vendor/bundle`, and whatever the caller is already excluding — ~180 ms on Zimmer's
own clone, against a copy of the same tree that costs seconds. It never follows a symlinked
directory, which both matches what the copy does with one and makes a symlink loop impossible.

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

### A log-streaming thread that will not stop is abandoned, not killed

`AgentSessionJob::LogStream#stop!` asks the log-streaming thread to finish and waits
`LOG_STREAM_STOP_TIMEOUT` (5s) for it. If the thread has not finished by then, nothing else happens:
it is left running, and the job moves on. That is deliberate — the thread writes to Postgres, and
`Thread#kill` inside Active Record's connection setup is what poisoned a pooled connection and took
out an unrelated GoodJob thread in [#706](https://github.com/tadasant/zimmer/issues/706). See
[The streaming thread is asked to stop, never killed](/sessions/spawning/#the-streaming-thread-is-asked-to-stop-never-killed).

What that leaves is bounded but real. The stop flag caps the thread at one more iteration, so it
finishes and exits on its own — but in the meantime it is a thread nobody is waiting for, and on the
recovery-restart paths a second streaming thread is already running for the replacement process. The
overrun is logged at `warn` (`"Log-streaming thread for session N did not stop within 5s"`), which is
the only signal an operator gets; nothing counts it, and no alert fires on it. The same applies to
`PeriodicCatalogRefresher#stop!` in the web container, which returns `false` and keeps its handle
rather than clearing state it cannot vouch for.

### A stopped streaming thread stops reading its stderr file, and a truncated one goes unread

Every runtime adapter derives the stderr log path deterministically from the working directory and
reopens it with mode `"w"` at spawn, so a recovery respawn truncates the file underneath a streaming
thread still holding a byte offset into the old process's output. `stream_stderr_lines` detects the
case it can — a file now *shorter* than the offset — and stops reading rather than emit a fragment of
the replacement's output.

It cannot detect the other case. If the replacement has already written *past* the old offset by the
time the old thread reads, the size check passes and a mid-line fragment is logged, and the
replacement's own thread then re-emits the same bytes from byte 0. The window is one iteration wide
(≤0.5s) and the damage is duplicated `verbose` log lines, not lost data.

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

`OrphanCloneFilesystemCleanupJob` on its six-hourly cron is patient — `AGE_THRESHOLD = 48.hours`,
`BATCH_LIMIT = 20` — so an orphaned clone normally sits on the volume for up to two days. Disk
pressure is the exception: `CloneDiskGuard` calls the same job's `reclaim_space` entry point before
each clone, which lowers the age bar to `PRESSURE_AGE_THRESHOLD = 2.hours` and stops as soon as the
volume has room. See [the second gear](/operate/background-jobs/#clone-pruning-has-a-second-urgent-gear).

That is now the *only* orphan sweep over the clones base. `StaleCloneCleanupJob` used to run a
second one on a one-hour bar, which collected orphans sooner — and also meant the pressure path
could never find a candidate, because the short bar had already taken them
([#709](https://github.com/tadasant/zimmer/issues/709)). Dropping it trades a faster reclaim for one
owner of the question, which is the trade
[#808](https://github.com/tadasant/zimmer/issues/808) made unavoidable.

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
| Archived >1h with no `trash_after`, or failed >24h, **and** the session recorded a `clone_path` | Deleted by `StaleCloneCleanupJob`. Both that job and `EmptyTrashJob` re-read the *whole* selection predicate immediately before deleting — status **and** `trash_after` — so an unarchive-then-re-archive, which restarts the four-day deadline, keeps its undo window instead of being reaped an hour later |
| Any of the above, but the session woke up before the reaper got to it | **Not** deleted — the status is re-read immediately beforehand ([#808](https://github.com/tadasant/zimmer/issues/808)) |
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

The session most likely to be waiting on a merge is exactly the one with stale user activity: it did
its work, said so, and has been sitting in `needs_input` — or asleep in `waiting` on the `open-pr`
skill's self-wake — ever since. It can therefore wait a long time to learn that the PR it was
blocked on landed. The backoff exists because polling every active session's PRs on every tick
exhausts GitHub's 5000/hr authenticated rate limit at around 50 sessions, and that is the trade
being made. Touching the session resets the curve to the 30-second
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

### A re-enabled or retimed schedule can still fire off-slot once

A `days`/`weeks` schedule fires at the first configured slot that arrives after it was created
([Triggers](/sessions/triggers/#when-a-new-recurring-schedule-first-fires)), and *created* is the
operative word: `TriggerCondition#armed_before?` derives arming from `created_at`, so creation is
the only instant that arms a schedule. Two ordinary edits slip past it. Re-enable a schedule that
was disabled when its slot passed, and it fires within a minute of the toggle rather than at its
next slot. Change the `time` on a schedule that has never fired, to an hour already past today, and
it fires on the next tick — the condition never existed with that slot at the moment the slot went
by.

Both are the same symptom as [#447](https://github.com/tadasant/zimmer/issues/447) in miniature: one
run at an arbitrary hour, and — because a fire advances `last_triggered_at` — that day's configured
run silently skipped. Bounded, though: it takes a disable/enable cycle or a `time` edit on a
schedule with no fires behind it, and it costs exactly one off-slot run. A schedule that has fired
at least once is governed by `last_triggered_at` and is unaffected.

Fixing it needs a stored arming timestamp rather than a derived one — set on create, refreshed when
the trigger is enabled and when the schedule's shape changes, and pointedly *not* refreshed by a
no-op re-save, which is the trap `updated_at` would fall into. That is a column, so it is tracked
separately in [#745](https://github.com/tadasant/zimmer/issues/745).

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

### An `ao_event`-only wake consumed by a resume is never reaped on a timer

Deliberately resuming a session consumes every pending one-time wake aimed at it — both kinds.
`SessionStateMachine#cancel_pending_one_time_wake_triggers` stamps `last_triggered_at` on a one-time
`schedule` condition and on a session-scoped `ao_event` condition alike, and either stamp is
permanent: the trigger can never fire again.

`CleanupStaleTriggersJob` collects the consumed row, but only when the trigger carries a one-time
schedule — its candidate query asks for a `schedule` condition with a `scheduled_at`. A wake built
purely from session-scoped `ao_event` conditions, which is what
`wake_me_up_when_session_changes_state` creates, is not a candidate, and it has no `scheduled_at` to
lapse either. It survives as `enabled` with 0 sessions until its target session is archived, at
which point the archived-target sweep takes it — unless it set `resuscitate_archived`, which is
exempt from that sweep too.

So in the recommended two-row wait — one `event_names` watcher plus a `wake_me_up_later` deadline
backstop — a manual resume consumes both, the backstop clears within the hour, and the watcher stays
in the list looking armed. `Trigger#dead_one_time_wake?` already answers correctly for that shape;
it is the sweep's candidate set that does not reach it, and broadening that set would also newly
collect the triggers `AoEventTriggerJob` preserves on purpose behind a dropped follow-up. Tracked in
[#793](https://github.com/tadasant/zimmer/issues/793).

Nothing is stranded by it: the rows are inert and no session waits on them. The cost is that
`/triggers` and `search_triggers` overstate what is actually armed.

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

The tick is skipped the same way when the preflight *cannot reach GitHub* — but the WARN then says so
rather than blaming the credential, and a `401` says "rotate this" rather than "provision one". The
three are distinguishable from a single log line; see [Triggers](/sessions/triggers/) for the states.
Nothing pages for any of them on the tick itself: the floor is still
`GithubTriggerHealthCheckJob`'s stale heartbeat, which is up to 15 minutes.

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

### Whether a failed GitHub search is retried is decided by reading `gh`'s error text

`GithubSearchService` re-runs a search whose request failed, so a transient GitHub blip stops paging
`#alerts` for a system that heals a second later. Whether a given failure qualifies is decided by
parsing the `gh` subprocess's stderr — the `(HTTP nnn)` suffix it appends to an API error, and the
wording of a 403 (rate limit, which clears, versus permission denial, which does not). None of that
is an API contract. If `gh` rewords its errors or stops printing the status code, a failure that
should fail fast gets retried instead: it waits ~4 seconds and then pages anyway, on that tick and
every tick after. The classification can therefore make a page *late*; it cannot make one *vanish*,
which is the direction the deny-list was chosen to be wrong in.

Three failures get no second chance, and only the first is about classification at all. A 4xx GitHub
attributes to the request (422, 404, a permission denial) and a `gh` usage error raise immediately,
as does a **rate limit** — transient, but never inside a 4-second budget, and retrying it would
spend more of the quota that caused it. So does a **hang**: a `gh` call killed at `REQUEST_TIMEOUT`
(15s) raises on the first attempt, because retrying would spend most of a one-minute tick on the
failure least likely to clear. A GitHub incident that stalls connections rather than refusing them
therefore still pages per tick, exactly as before.

### `BoundedSubprocess` can still return a nil `Process::Status`, and every caller has to remember

`BoundedSubprocess.run` returns Open3's `wait_thr.value`, which is a `Process.detach` thread whose
`#value` is **`nil`** when the child pid was reaped elsewhere before the waiter's own `waitpid` ran
(`ECHILD`) — a race that can happen in the multi-threaded worker. A caller that then calls
`status.success?` on that nil crashes with `undefined method 'success?' for nil`.

Every consumer today reads the status through `SubprocessStatus.success?` /
`SubprocessStatus.describe_failure`, which treat nil as a failure (`REAPED_DESCRIPTION`) rather than
dereferencing it: `GithubSearchService`, `GitCloneService`, both `AirPrepareService` call sites, both
`CloneDiskGuard` call sites, and `McpPackageReinstallJob`. So the race is handled everywhere it can
currently occur.

What remains is that this is a **convention, not a guarantee**. The type `BoundedSubprocess` hands
back still admits nil, so the next caller written against it is one `status.success?` away from the
same `NoMethodError`, and nothing in the signature or the test suite will stop them. The durable fix
is to make `BoundedSubprocess` never hand back a nil status — normalising it into a status object
that reports failure — so callers cannot get it wrong rather than merely not getting it wrong today.

---

## API

### A gateway timeout on a create still arrives as HTML, not as a JSON-RPC error

A request that outruns the reverse proxy's read timeout is answered by the **proxy**, not by Zimmer,
with its own `504 — Gateway Timeout` HTML page. An MCP client parsing that gets a parse failure
rather than a transport error it can classify, and there is no correlation id in it to match against
anything. Nothing in this application can change that: by the time the page is written, the app is
not in the conversation. The timeout value and the error-page format are deployment configuration —
the Caddy layer in front of the app — not application code.

What Zimmer does instead is remove the two reasons this mattered. The create is
[idempotent when you name the attempt](/extend/rest-api/#idempotency_key--making-the-create-safe-to-retry),
so a caller no longer has to *classify* the error to act on it — it retries with the same
`idempotency_key` and gets the session either way. And the create no longer does the O(lineage²)
provenance fan-out that put it near the timeout in the first place (see [Hierarchy and human
messages](/sessions/hierarchy-and-human-messages/)). A caller that passes no key is still exposed to
the original ambiguity, which is why the tool description tells it to search by title rather than
retry. Tracked in [#577](https://github.com/tadasant/zimmer/issues/577).

### Queue recovery mode is deliberately outside the health cooldown, and the web control is anonymous

`QueueRecoveryMode` (see [Queue recovery mode](/operate/background-jobs/#queue-recovery-mode)) is
Zimmer's escape hatch for a runaway job queue: it halts execution on `pollers`, `triggers`,
`inference`, `maintenance` and `default` for up to four hours. Two things about it are choices rather than oversights, and both cut
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
subqueries to every dequeue poll on all five schedulers; the table holds one row and is indexed on
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

### The work backlog's "mechanical" and "human" claims are asserted, not verified

The [work backlog](/operate/work-backlog/) draws a line between what an agent may do to the queue
(append, pull, remove an item whose issue it found dead) and what only a human may (pin, hand-place,
remove by judgement, start an item as a `priority` session). The line is enforced by *absence* —
the human operations have no MCP tool — and by *vocabulary*: a pull may only remove an item with a
reason from a fixed list of observed facts (`issue_closed`, `issue_has_open_pr`,
`session_already_working`, `trust_failed`). Nothing on the server checks the fact. A connection
that carries `work_backlog` can remove any queued item by asserting `trust_failed`; the record
says which session did it, and that is the whole audit. Likewise `POST /api/v1/work_backlog_items`
defaults `added_by` to `human` and accepts any value, because the API key it authenticates is
shared by the fleet and establishes a caller, not a person — so the model's rule that an
issueless item needs a human behind it is one string away for any REST caller. The same
agent-login primitive the gate ledger's feedback boundary is waiting on ([#371](https://github.com/tadasant/zimmer/issues/371),
[#220](https://github.com/tadasant/zimmer/issues/220)) is what would make either claim verifiable.

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

- **Live card updates ignore the status filter.** The dashboard broadcasts on one global stream and
  the server cannot know which statuses a given browser has ticked, so it only special-cases
  `archived`. With the default `needs_input`-only view, a session that transitions out of
  `needs_input` has its card replaced in place rather than removed, and a newly created `waiting`
  session is prepended into a grid that filters it out. Both correct themselves on the next reload.
  Fixing it properly means either per-filter stream names or a client that re-evaluates the filter
  on each broadcast.
- **The Ranked view inserts and removes rows live, but still never re-sorts them.** `/?view=ranked`
  sends two kinds of message. A status change replaces one element per row — the status pill — and
  nothing else, because the row also holds a precedence the user may be mid-edit on and a position
  SortableJS may be dragging. A membership change (a session created, a status moved, a scheduling
  class changed) sends an envelope instead: the session's filterable facts plus its row inside an
  inert `<template>`, which the page judges against its own filters. So a new session does appear in
  the right section at its precedence position, a promote or demote elsewhere does move the row
  between Priority and Spot, and a trashed row leaves a page filtered to live work while *staying*,
  relabelled "Trashed", on a page whose operator ticked "Archived" to look at the trash. What still
  does not happen: the queue is never re-sorted when someone else changes a precedence, and a row is
  never inserted into a page narrowed by a search, an agent-root filter or a genesis filter — the
  client cannot evaluate those three for a session it has never rendered, so it declines rather than
  guessing. Removal stays sound under all of them, because a row on screen already matched them and
  neither a status nor a class change can alter that. Three safety rules cost a little more
  freshness: deliveries are held while a row is being dragged and applied on drop, a row holding
  focus or a half-typed value is never moved or removed, and a section already at its 200-row cap
  takes no insert. All of it is corrected by a reload, and by the reopen backfill: both lists are
  `data-live-region="sync"`, so a page whose socket died is reconciled against a fresh render on
  reconnect.
- **A session card's footer still wraps onto two lines in two narrow cases.** The row seats the PR
  control on the left and the ⋮ / Trash / View group on the right, and the grid gives a card
  320–400px, so the row can be as narrow as 288px. Collapsing a multi-PR control to a single trigger
  ([#607](https://github.com/tadasant/zimmer/issues/607)) bought that row enough slack for the
  ordinary case, but not for these two. A **failed** session carries an extra Restart button, which
  puts the action group at 237px and the row's need at 333px — it fits a 400px card and wraps below
  that. And a **320px card on a viewport ≥640px**, which `auto-fill` produces at container widths of
  664 / 1008 / 1352px, has `sm:p-6` padding rather than `px-4`, so the row is 272px against a need of
  276px and misses by 4px. Both are cosmetic: nothing overflows, the card just grows a line. Closing
  either means changing what the action group renders.
- Notes autosave as you type (a 1.5s debounce) and flush again on disconnect via a keepalive
  `fetch`. The disconnect flush is best-effort, so an abrupt close can drop the last sub-debounce
  keystrokes — not the note.
- The Turbo circuit breaker stops UI updates for 60 seconds when it trips (`THRESHOLD = 5`,
  `RESET_TIME = 60`). A polled "Live updates paused" banner says so while it lasts, but the updates
  dropped during the window are gone — the page catches up on its next reload, not retroactively.
  ([#86](https://github.com/tadasant/zimmer/issues/86))
- Push notifications don't work on anything without the Push API (iOS Safari outside standalone PWA).
- Reopening the installed PWA no longer reloads the page — Zimmer backfills the regions broadcasts
  target instead of navigating (see [Lifecycle](/sessions/lifecycle/#the-reopen-backfill)) — but
  there is a case Zimmer genuinely cannot stop. iOS discards a backgrounded standalone PWA's web
  view under memory pressure, and that relaunch is a cold start: a fresh navigation before any of
  Zimmer's JavaScript exists to intervene. So a reopen after a *short* absence keeps your place,
  and a reopen after iOS has reclaimed the web view does not. What survives either way is the
  follow-up composer's text: it autosaves to `localStorage` as you type (a 300ms debounce, flushed
  immediately on `visibilitychange`/`pagehide`) and is restored on load. Scroll position and
  expanded panels survive the backfill but not the cold start.
- The backfill recovers what broadcasts target and nothing else, and three surfaces are knowingly
  outside it. A session detail loaded into the dashboard's drawer is not in a fresh render of the
  dashboard, so its regions are not backfilled — `cable-reconnect` restores live updates there, but
  content broadcast into the drawer during the gap is only recovered by reopening it. Subagent
  accordions are replace targets nested inside timeline rows, and the backfill treats a row it
  already has as already current, so subagent progress stays as it was until a real navigation. And
  the notification badge is a lazily-loaded `<turbo-frame>`: replacing it with the server's copy
  would blank it and re-fetch, so it is left alone and its count is stale until the next broadcast.
- A `sync` region that has been paged inside its own `<turbo-frame>` is skipped rather than
  reconciled, because the URL the backfill re-fetches does not carry that page. So a dashboard
  category you have paged forward in keeps the cards it had, and does not pick up sessions added or
  removed while you were away, until you page it again.
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
- A `<turbo-frame>` whose fetch comes back without the frame in it no longer shows Turbo's bare
  "Content missing" — `app/javascript/lib/frame_missing_recovery.js` cancels `turbo:frame-missing`,
  follows a redirect through as the whole-page visit it is, says what any other response actually
  was, and retries a `429`/`500`/`502`/`503`/`504` three times over about 16 seconds. What it does
  *not* do is recover the content: a `404` or a `403` is reported and not retried, and an outage
  longer than the retry budget leaves the panel showing the message until you press Retry or
  reload. The three frames this shows up in are the dashboard's `cli_badge` and
  `notification_badge` and the session drawer's `session_detail`. Two edges are knowingly left: a
  miss on a frame with no `src` (one reached by a link navigation) gets the message without a Retry
  button, because there is no URL to try again; and a miss dispatched after the frame has left the
  document is cancelled silently, because there is nothing left to paint into.

---

## Testing

### Every clone on a host shares one AIR CLI install directory per environment

🟡 `AIR_INSTALL_DIR` is keyed on the environment, not on the clone: every test suite on a host
installs into `~/.cache/air-cli-test`, and every `bin/agent-dev` into `~/.cache/air-cli`. Two agent
sessions on branches that pin different AIR versions — or the same version with different package
sets — therefore take turns reinstalling that one directory, each replacing the other's tree and
deleting its version marker.

A cross-process `flock` serialises the installs, so this costs a repeated ~60s `npm install` rather
than a corrupt tree, and since 2026-09-01 neither environment can reach the deployed app's
`/opt/air-cli`, so it can no longer take production down with it. Set `AIR_INSTALL_DIR` explicitly
to give a clone its own.

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
the session *opened* one: a successful create (`gh pr create`, or a POST to the REST
`repos/OWNER/REPO/pulls` endpoint), a failed `gh pr create` that says the branch's PR already
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
  opened through a path the hook can't see — an MCP GitHub tool's `create_pull_request`, which is a
  structured tool call rather than a shell command, or the web UI — and never mentioned in the
  agent's prose lands here. The shell shapes are enumerated, so each new one costs a session before
  it is recognised: the REST fallback agents reach for when GitHub's GraphQL API is down took
  session [5679](https://zimmer.tadasant.com/sessions/5679) to discover.

The warning log a PR-flavored goal gets when a session comes to rest (`pause`, `fail` or `archive`)
covers the second case only, and only when the goal happens to mention pull requests. There is no
check at all for the first. That warning is also written once per session and never retracted, so a
session that was warned and is then resumed or unarchived — `resume` runs from `failed`,
`unarchive_to_*` from `archived` — keeps a warning its later PR made obsolete.

A fork is read from **one past** `metadata["forked_at_message_index"]`, because everything at or
before that index — the index is inclusive — is a copy of the source session's conversation and
shows the *source* opening PRs. Two edges come with that. The fork point is a message index into the
fork's own stored transcript, which holds only as long as that transcript stays a prefix-stable
append — the same assumption `broadcast_message_count` makes, and one a runtime that reshaped its
history on resume would break silently, in the too-tight direction. Nothing in the repo breaks it
today: Claude appends to the file, `AgentSessionJob#write_transcript_to_clone` re-materializes
`session.transcript` verbatim when a clone is recreated, and `#carryover_prefix` re-attaches the
stored head across a Codex rollout rotation. And the trim only governs what is written from here on: **a fork credited before this
shipped keeps the list it was given**, because the hook adds URLs and never removes them. Such a
fork stays in all three pollers' scope for the source's PRs until it is archived or failed.

Narrowed in [#214](https://github.com/tadasant/zimmer/issues/214) and
[#556](https://github.com/tadasant/zimmer/issues/556), widened in
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

## The spot gate decides on a reading up to 15 minutes old

The gate compares each window's utilization against its target, and that utilization is the average of
the last `ClaudeAccountQuotaSnapshot` on file for every account in the pool. `ClaudeUsageSamplerJob`
refreshes the serving account every 15 minutes and a spare is read only on rotation or when somebody
opens `/quotas`, so between samples the gate is deciding on numbers that may already have moved —
and a spare's contribution to the average can be considerably staler than 15 minutes.

Two consequences worth knowing:

- **A burst can overshoot the target before the reading catches up.** Ten sessions started at once
  spend for up to fifteen minutes against a utilization figure taken before any of them existed. The
  concurrency limit is what bounds the damage — it is the reason the limit exists — but the target is
  a level the deployment crosses and then stops at, not a line it never passes.
- **A session counts against the limit only once it is `running`,** which happens after its clone and
  spawn. A burst that evaluates before any of it has started reads the same fleet size and can
  briefly exceed the limit. The next evaluation corrects it, and the jitter on a held session's
  re-check spreads the backlog out, but the limit is enforced per decision rather than held as a
  reservation.

---

## The gate decides on the pool, but a session spends against one account

The gate averages every account's utilization (`ClaudeAccountPool`), while a session that starts
spends against whichever account is serving. `AccountRotationService` moves to a spare when the
serving account is **refused** — roughly, at 100% or a rejected status — not when it reaches the 80%
target. So a pool comfortably under target can still start a session onto an account with nothing
left, which is answered by a refusal and a rotation rather than by the gate.

That is the intended trade. Deciding on the serving account alone meant one account at its cap held
the whole fleet while the rest of the pool sat idle, which is not what the pool is for. The cost is
that "under 80%" is a statement about the deployment's total headroom, not a promise about the next
session's first API call.

A second consequence: an account in `needs_reauth` is averaged in, so its headroom counts toward
running work Zimmer cannot yet route to it. That is deliberate — the window keeps draining while the
account waits for a human, and treating it as spent would make the pool figure lurch every time an
account dropped out — but a pool where most accounts need re-authentication will read roomier than
the accounts actually serving.

---

## `active_session_count` on quota snapshots has no reader

`QuotaSnapshotService` records the running-session count on every snapshot, and nothing reads it:
`ClaudeUsageRateService`, which divided utilization by session-hours, was deleted with the forecast.
The column is kept because it can only be captured at write time — a reading taken today cannot be
attributed to a fleet size tomorrow — so it remains available as history for any future metric. It is
dead weight until then.

---

## A held spot session has exactly one thread back to life

`SpotSessionHold` defers by re-enqueueing `AgentSessionJob` with a delay, and that single delayed
GoodJob row is the *only* thing that ever restarts the session. GoodJob persists it, so it survives
a worker restart or a deploy — but if it is discarded (retries exhausted on an unrelated exception,
a manual queue purge, a failed deserialization), the session sits in `waiting` indefinitely with a
banner whose "next check" time is permanently in the past. `DeploymentRecoveryJob` will not pick it
up: that only claims sessions carrying `metadata["paused_by"] == "recovery"`, which a held session
does not have.

`SpotHoldSweepJob` is what closes it — the sweep for `waiting` sessions whose `spot_hold_retry_at`
is well past that this entry used to ask for. What remains is latency, not permanence: the backoff
on consecutive holds widens the window in which a broken chain goes unnoticed, so a session pinned
at the one-hour ceiling can be up to an hour past its promised re-check before `spot_hold_retry_at`
says so, plus `SpotSessionHold::OVERDUE_GRACE` and a sweep tick on top.

---

## A stranded `waiting` session is only rescued if it never started

`StalledStartSweepJob` closes the case that stranded production session 10426 for three days: a
session created, queued, and then left in `waiting` because the one `AgentSessionJob` carrying its
first turn was lost. Its population is deliberately narrow — `waiting`, no `session_id`, a prompt to
run, nothing queued in GoodJob, none of the markers that mean "asleep on purpose" — because that is
the one shape whose repair is unambiguous: run the job creation would have run.

Three neighbours are **not** covered.

- **A session that has already run.** With a `session_id` there is a conversation and a clone, so
  re-running the start job would re-clone underneath it. Those come back through
  `metadata["paused_by"] = "recovery"` and the two recovery sweeps — and a session that reaches
  `waiting` without that marker and without a hold, a pause, a park or an armed wake is stranded
  with nothing looking for it. `Session#continue_nudge_on_refresh?` is the manual door: a human
  pressing **Refresh** sends it the continue nudge.
- **A session with no prompt.** That is not a lost job: `POST /api/v1/sessions` enqueues nothing
  when the caller sends no prompt, deliberately, and the session waits in `waiting` for a follow-up.
  Starting one would run an agent nobody asked for. (A clone-only session created in the web UI is
  a different thing again — `SessionsController` creates it `needs_input`, so it is out of the
  population by status. A clone-only setup job that is lost is not repaired by anything.)
- **The enqueue itself.** The attachment-copy failure paths in `SessionsController#quick_prompt`
  and `#chat_bubble` create the session with `skip_enqueue: true` and then raise before reaching
  `AgentSessionJob.enqueue_new_session`. The human gets a flash message and the row is now rescued
  within ~10 minutes rather than never — but the honest fix is for the create to be undone, or the
  enqueue to happen, on that path.

A turn this sweep restarts **does** carry its attachments, and that is worth stating because it does
not come for free: `AgentSessionJob` receives images and files only as job arguments, and the
replacement job is built from scratch rather than inherited. `Sessions::StartNow` — which is also
what the Ranked view's **Start** entry and a promote to priority use — re-reads them from the durable
volume, where they sit keyed by session id, and the session's log line names what the turn is
carrying. Two things are deliberately left out of that replay: an image whose media type cannot be
sniffed from its own bytes, which is dropped rather than guessed at, and any attachment a **queued
follow-up** already owns — both kinds live in the same per-session directory, so a screenshot
attached to a message somebody queued for later is not smuggled onto the turn before it.

The session page's **Restart from scratch** button is a different door, and it carries them too.
`SessionsController#restart_from_scratch`, `POST /api/v1/sessions/:id/restart` and MCP
`action_session`'s `restart` clear `session_id` and build the replacement job themselves rather than
going through `Sessions::StartNow`, so each reads the same `Sessions::FirstTurnAttachments` before it
enqueues ([#746](https://github.com/tadasant/zimmer/issues/746)). Replaying is deliberate rather than
incidental: a restart from scratch throws the conversation away and re-runs the session's *original*
prompt, so the attachments that turn was created with are exactly what the replacement turn needs.
The read never raises — this is a path taken only when something has already gone wrong, and a
storage tree that cannot be read costs the attachments, never the restart.

Two things are **failed** rather than restarted, and both are the same trade — a `failed` row is on
the dashboard with a reason on it, a `waiting` one is on nobody's list. A session past
`MAX_RESTARTS` (3) attempts, because whatever is eating its start job is not something more
attempts will fix. And a session stalled longer than `MAX_STALL_AGE` (1 day), because by then the
turn is stale rather than late: session 10426's own PR was merged seven minutes after it was
spawned, so a sweep that found it on day three and simply started it would have run a merge gate
against an already-merged PR. The cost of that second rule is that a genuinely still-wanted turn
older than a day needs a human to press Restart — which is a thing they can now see, rather than a
row nothing was looking at.

---

## A backed-off hold can sleep past the moment it could have started

`SpotSessionHold` doubles the re-check interval on consecutive holds, up to an hour for a
utilization hold and half an hour for a fleet-cap one. The gate is only ever consulted at a
re-check, so a condition that clears early is not noticed until the next one: a session pinned at
the ceiling can sit `waiting` for up to an hour after the pool came back under its target, or up to
half an hour after a slot freed.

This is the deliberate cost of the fix, not an oversight. A flat interval makes the held population
an arrival rate that cannot fall when the deployment is struggling, and on 2026-08-20 that rate —
~80 held sessions re-checking every ~11 minutes — outran the `agents` queue's ability to service it
and grew a GoodJob backlog until it paged. The ceilings are chosen against how fast each condition
can actually clear (a pool window comes down over hours; a slot frees unpredictably, hence the
shorter one), the delay is visible as `spot_hold_retry_at` on the session's detail page, and a human
who wants a specific session now can make it priority.

What would close it properly is waking held sessions on the event rather than polling for it —
publishing a signal when a session ends or a window resets — which is a larger change than the
backoff and is not built.

---

## A spot session has no starvation escape, by design

While a window's non-reserved budget is spent, spot work waits — with no deadline and no override.
The pacing curve makes most waits short (a window merely ahead of pace is back inside it as the clock
moves), but a window whose budget is genuinely gone waits for the rollover, and a week's budget spent
early holds a queue for a long time. That is the behaviour the deployment asked for: the reserve is
what protects priority work, and spending it would defeat the point.

The levers, when one piece of work genuinely cannot wait, are per-session rather than global: promote
that session to priority from its hold banner, or lower the priority reserve on `/quotas`. `/quotas`
shows the held state, the reason, and how many dollars are left the whole time, so a queue waiting on
a window is visible rather than mysterious.

---

## Quota capacity in dollars is an estimate, not a measurement

`QuotaCapacityCalibrator` divides Zimmer's own Opus-denominated spend over a window by the pool's
average utilization of it. Three approximations ride along: Zimmer's ledger is list-price spend read
from transcripts while Anthropic's counter is its own accounting of the same calls; "the last five
hours of spend" is not exactly "the spend inside each account's own five-hour window", because
accounts reset at different moments; and spend from a transcript Zimmer could not read is missing
from the numerator but present in Anthropic's counter.

The figure is smoothed rather than trusted point to point, every surface labels it an estimate, and
the gate degrades to reasoning in percentages when no usable estimate exists rather than pretending.
But "$412 of spot budget left" is a model output, not a bill, and should be read as one.

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

## The spot gate holds turns, but not queue position

`SpotSessionHold` gates every turn that would spend Claude quota — a first start, a fired wake
trigger, a follow-up, a poller message, a restart — so while a window sits at its target a
spot-designated session cannot run without being promoted to priority. What it does **not** consult
is `precedence`. The gate answers "is there headroom?", not "is this session next": once the window
falls back below its target, whichever held session's re-check fires first runs, even if it sits at
the bottom of the ranked queue and a hundred higher-ranked sessions are still asleep. Precedence
decides the order in two narrower places — the ceiling sweep's resumes (`SpotSessionPause#rank`) and
the fleet-maintenance session the `quota_available` event spawns — and nowhere else.

The practical effect is that the ranked queue is an ordering over *recovery*, not an admission
queue. A spot session already in flight (one with a wake armed, or a follow-up queued) re-enters
whenever its own timer says so.

Two things still pass the gate, both deliberately: `clone_only` (sets up a clone, spawns no agent)
and `resume_monitoring` (re-attaches to a process already running). Neither spends anything.

One narrow edge comes with returning a refused turn to `waiting`. If the job that reached the gate
had just superseded a dead job whose CLI process was somehow still alive, the session goes dormant
while that process keeps running — and both sweeps that would have noticed
(`CleanupOrphanedSessionsJob#recover_running_orphans` and `SpotSessionPause.pausable_sessions`) scan
`status: running` only, so nothing looks at it until the hold's re-check fires. The gate does not
terminate processes; `SpotSessionPause` is the half of the policy that does.

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
broadcast while the page was away is not recovered until the next navigation.

This is much smaller than it was. When the dead-socket branch ended in a full page reload, a
false *positive* was the expensive mistake and the check had to be conservative:
`connection.monitor.connectionIsStale()` reads stale on every reopen (a frozen page receives no
pings), so adding it would have reloaded every time — the bug the check was written to avoid.
Now that the branch backfills in place, a false positive costs one GET and a few DOM swaps, so
that trade is worth revisiting. It has not been, because on the case that actually matters — iOS
suspending the app — `isOpen()` already reports the socket as closed. A bfcache repro measured
exactly that: socket closed at the moment of restore, every time. The zombie socket is the
residual case, not the common one.

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

## CI cannot test the nested-Docker path, only the shape of it

CI has no sysbox runtime and no user namespace, so nothing in the suite can start the
worker the way production starts it under `ZIMMER_NESTED_DOCKER=1`. What the suite covers
is the config resolution (`test/config/nested_docker_switch_test.rb`) and the entrypoint's
privilege drop, executed against stubbed `id`/`getent`/`setpriv`
(`test/config/docker_entrypoint_privilege_drop_test.rb`). Both are real assertions, and the
second one fails against the entrypoint that took production down on 2026-08-13 — but
neither is the integrated thing.

This is the gap that let that outage ship: every automated check asserted the worker
container was *shaped* correctly (right runtime, right uid map, inner daemon answering) and
none asserted it was *working*.

The integrated coverage lives in the `Deploy staging` workflow rather than in CI, because
running it needs a sysbox host and CI has none: it preflights the droplet by starting a real
sysbox container, and after the cutover asserts the worker is user-namespaced, has no host
socket, answers `docker version` as uid 1000, and that its `HOME` is `/home/rails` and is
traversable and writable at uid 1000.
That is still a *staging* signal, not a CI one — the suite itself will keep asserting only
the shape, and a `main` that is green says nothing about whether the nested path works.
Production remains off by default and owes its own staging-proven rollout — see
[Nested Docker for agent sessions](/operate/nested-docker/).

---

## A session's memory bound needs the nested-Docker worker

Every agent session runs in its own cgroup with its own `memory.max`
([Each session gets its own memory bound](/sessions/spawning/#each-session-gets-its-own-memory-bound)),
which needs a **writable cgroup2 filesystem**. The worker has one only because sysbox gives
it its own cgroup namespace: under plain runc `/sys/fs/cgroup` is read-only, and on a dev Mac
there is no cgroupfs at all. Nested Docker is also off by default
(`ZIMMER_NESTED_DOCKER` defaults to `0` in `config/deploy.production.yml`), so a deployment
that has not turned it on gets no bound.

Where the bound is unavailable, `SessionMemoryCgroup.available?` is false and every caller
no-ops: sessions spawn exactly as they did before, unbounded, and one runaway command can
still spend the whole container budget. That is deliberate — a failed bound must never be the
thing that stops a session from running — but it means the protection is silently absent
rather than loudly missing. The entrypoint logs one line when it *does* delegate the subtree;
nothing warns when it does not.

Three further gaps in what the bound covers, all by design:

- **It is not a sandbox.** An agent runs as the same uid that owns the delegated subtree, so
  it can move itself out of its own cgroup. This is a guardrail against a runaway command, not
  a boundary against a hostile one — Zimmer has no such boundary anywhere.
- **Inner Docker containers escape it.** A container an agent starts through the nested
  `dockerd` is placed in a cgroup by that daemon, which lives outside `zimmer.sessions`. Its
  memory is charged to the worker container, not to the session that asked for it.
- **CI cannot test the enforcement**, only the plumbing — same reason as
  [CI cannot test the nested-Docker path](/limitations/#ci-cannot-test-the-nested-docker-path-only-the-shape-of-it).
  The kernel half is verified on staging.

### 🔴 A contained session kill still looks like an incident to the fleet alert

The success case of a per-session bound is a kernel `oom-kill:` line. The fleet's
`fleet_cgroup_oom_kill` alert counts those lines unfiltered, so a session whose runaway command
was killed *inside its own cgroup* — harming nothing, needing no human — pages `#alerts` at
critical exactly like the uncontained container-cap kill the alert was built for.

Measured on staging: two contained kills left the worker container's `memory.current` unchanged
(1.259 GB before, 1.259 GB after) and its `memory.events.local` `oom_kill` at 0, while its
*hierarchical* `memory.events` counted both and the kernel emitted a line for each.

The distinction is in the line itself, which is why the cgroups are named after the session:
`oom_memcg=/zimmer.sessions/session-12398` is contained, `oom_memcg=/system.slice/docker-….scope`
is not. The filter belongs to the alert rule, which lives in the `obs` stack rather than in this
repo, so it is not fixed here — tracked in a private repo. Until it is, expect a page the first
time a production session hits its bound.

---

## `kamal app exec --reuse` runs as root on a nested-Docker worker

`--reuse` is a bare `docker exec` into the running container, so it does not run the image
ENTRYPOINT and it inherits the container's configured user. Under nested Docker that user is
`0:0`, so the command runs as **root** with none of the entrypoint's privilege drop applied.

The image pins `ENV HOME=/home/rails`, so it at least gets a working `HOME` — before that,
any DB-touching command invoked this way died on `could not open certificate file
"/root/.postgresql/postgresql.crt": Permission denied`, which reads as a broken deploy rather
than as the wrong invocation. What the pin does *not* do is make the command run as uid 1000.

So anything invoked this way that writes under `~` — `~/.zimmer/clones`, `~/.claude`,
`~/.config/gh`, `~/.local`, `~/.codex` — writes **root-owned files into named volumes the app
reads at uid 1000**. Previously those writes landed in `/root` on the container layer and
evaporated at the next deploy; now they persist. That is a real trade, taken deliberately: a
working admin path with a caveat beats one that always fails.

The damage does not accumulate: the entrypoint sweeps the volume roots and hands anything not owned by uid 1000 back to it — once before the privilege drop, then every 60 seconds from a process that kept its root credentials for exactly that. What remains is a **window**: a file root writes is unreadable to the app until the next sweep. `ZIMMER_RECLAIM_INTERVAL` tunes it (`0` drops the repeat and keeps the boot sweep), but no destination passes that variable today, so changing it means adding it to `env: clear:` in the deploy config rather than setting it at deploy time.

Use plain `kamal app exec` (a `docker run`, which runs the entrypoint and drops properly), or
`docker exec -u 1000:1000` if you need the app's identity inside the existing container — see
[Nested Docker for agent sessions](/operate/nested-docker/#the-entrypoint-reclaims-what-root-leaves-behind).

---

## The dev stack writes as root, and only the worker undoes it

`.agent-containers/docker-compose.dev.yml` runs its `app` service as root — `Dockerfile.dev`
sets no `USER` — and bind-mounts `..:/app`, `${HOME}/.claude` and `${HOME}/.config/gh` into
it. Everything the stack writes through those mounts is therefore root-owned on the other
side, whoever started it.

That, not `kamal app exec --reuse`, is what actually produced the root-owned session
transcripts found in staging's `claude_home` volume, and the 4,442 root-owned
`tmp/cache/bootsnap/` files that made `ac.sh destroy`'s clone removal fail for the uid
sessions run as.

The entrypoint's reclaim sweep covers this on a nested-Docker worker, because the clone and the runtime homes are under the volume roots it sweeps. It does **not** cover a dev stack started anywhere else — on a laptop there is no root process sweeping afterwards, so a stack run there still leaves files its own user cannot delete. Fixing the source means running the `app` service as uid 1000, which is a change to the dev image (bundle path, the Claude CLI's install prefix, and the docker socket's group). Tracked in [#510](https://github.com/tadasant/zimmer/issues/510).

---

## The reclaim sweep re-resolves paths it already looked at

The sweep collects paths with `find` and then hands them to `chown` in a second step, so an intermediate directory component can be swapped between the two. `~/.zimmer/clones` is writable by uid 1000 by construction, so an agent could plant a path the sweep will match, then replace one of its parent directories with a symlink before `chown -h` resolves it — retargeting a file outside the volume to `rails:rails`. The repeat makes the race retryable rather than one-shot.

`-h` closes the same trick on the final component, and the bound on the rest is the role's existing privilege rather than anything the sweep does: on a nested-Docker worker uid 1000 already holds the inner Docker socket and is therefore already equivalent to container root, which sysbox keeps namespaced away from the host. So this grants no capability that role did not have. It would matter on a container started as root under plain `runc` with `ZIMMER_NESTED_DOCKER` unset — a combination the deploy configs cannot produce, because runtime and user are derived from the same variable, and the one case where this PR also leaves a root shell loop running for the container's lifetime where previously root `exec`'d itself away.

---

## A PR session waits for a merge message that three cases can prevent

The PR goals hold a session open until its PR merges — asleep in `waiting` on the `open-pr` skill's
bounded self-wake, then at rest in `needs_input` — and `GitHubPullRequestPollerJob` releases it by
delivering `AutomatedPrompts.pr_merged_message`. That is the whole exit condition, and it has three
ways to not fire.

**The PR URL was never recorded.** The poller iterates `Session.with_github_prs`, which needs
`custom_metadata["github_pull_request_urls"]` populated, and that is filled by
`TranscriptHooks::GithubPrUrlHook` — a deliberately tight heuristic over the transcript. A PR
opened through a GitHub MCP tool, `gh api`, a wrapper script, a subagent whose tool calls do not
reach the main transcript, or against a different repository than the session's own (the
`same_repo?` gate) records nothing. `warn_if_pr_goal_captured_no_url` notices and writes a
session-timeline warning, but nothing the agent reads. The prompt and the goal text both tell the
agent to check `get_session` and archive if no URL was recorded, which is an instruction, not a
guarantee.

**The poller never saw the PR open.** The announcement fires only on an observed open → merged
transition (`status == "merged" && current_statuses[pr_url] == "open"`). `PollBackoff` stretches
the per-session interval to 5 minutes, 30 minutes, and eventually 24 hours based on time since the
last *human* activity — which for a router-spawned session counts from `created_at`. A merge gate
that merges inside that window can land the PR before the poller ever recorded it as open, and the
session waits forever. Documented from the poller's side in
[background jobs](/operate/background-jobs/).

**The delivery threw.** A failed `deliver_follow_up!` is swallowed while the status write advances
past the transition, so the message is never retried.

Before the session archived on labeling, each of these left a stale session. Now each leaves a
permanent one. The recovery in every case is the same: the human archives it, or sends it a
follow-up.

There is a fourth, milder consequence on the other side of the merge. Archiving drops a session out
of `with_github_prs`, so comments left on the PR *after* it merges reach nobody. That is intended —
the work is done — but it means a post-merge question on the PR needs the session unarchived to be
answered.

---

## A worker wedged on jobs it already claimed pages nobody

The queue-backlog alert measures ready work — jobs due now and unclaimed — and deliberately ignores
the `claimed` population, because a claimed job is one a worker is executing rather than one that is
waiting. See [What "queue backlog" counts](/operate/background-jobs/#what-queue-backlog-counts).

That leaves one shape uncovered. A worker that wedges while *holding* claimed jobs, on a queue with
no further inflow, produces a `claimed_count` that never falls and a `ready_count` that never rises,
so nothing crosses the threshold and no page is sent. The old rule would eventually have paged on
it, by accident, because it counted claimed jobs as backlog.

In practice inflow is what makes a wedged worker visible: Zimmer's queues are fed by cron pollers
and by sessions, so a stuck worker normally accumulates ready work within a poll interval and pages
on that. The uncovered case is a wedge on a genuinely idle queue. `GoodJob::Process::EXPIRED_INTERVAL`
also bounds it — GoodJob reaps a process that stops renewing its heartbeat and releases the jobs it
held, which returns them to `ready`. An explicit `oldest_claimed_age` signal would close the gap
directly; nothing measures it today.

---

## Transcript content search is bounded, so an empty answer can mean "not yet"

`sessions.transcript` is a `json` column and no index helps a leading-wildcard `ILIKE`, so searching
it is a sequential scan that detoasts every transcript it passes — thousands of sessions and
gigabytes of TOAST on production. Run as one statement it raced kamal-proxy's 30-second timeout and
returned a 504 about as often as results ([#405](https://github.com/tadasant/zimmer/issues/405)).

`SessionContentSearch` bounds it instead: candidates newest-first, in chunks, stopping at the result
limit or a wall-clock budget (20s by default, `ZIMMER_CONTENT_SEARCH_BUDGET_SECONDS`), always
returning. The cost is that a search over a large corpus may not reach the end in one call. That is
reported rather than hidden — `complete: false` plus a `next_cursor` to resume with — but a caller
that ignores the flag will read an empty page as "no such session".

The proper fix is an index the search can use, and both candidates have a real obstacle: a `pg_trgm`
GIN index would be built over gigabytes of TOASTed text, and `to_tsvector` refuses documents over
1 MB, which most transcripts exceed. Neither can be sized or measured from this repository — the
managed Postgres is not reachable from an agent session — so the bounded scan is what ships until
someone can measure them on the real corpus.

---

## A runaway job presents as a dead droplet, not as a dead job

Staging is a 4 GB droplet with no swap, and the worker is the one role running work whose peak
allocation is a function of the data it touches. `TranscriptArchiveJob` is such a job, and on
staging it allocates around 2.8 GB every ten minutes
([#495](https://github.com/tadasant/zimmer/issues/495)): with no archive on disk it treats every
session as changed and loads all of their transcripts at once, then dies before writing the archive
that would have made the next run cheap. It cannot bootstrap, so it retries forever.

Both reasons there was never an archive on disk have since been removed. The job used to write under
`Rails.root/storage`, a container overlay layer that every deploy destroys, so even a run that *did*
finish left nothing for the next one to build on; it now writes under `~/.zimmer/transcript_archives`,
on the `zimmer_data` volume, which survives deploys
([#714](https://github.com/tadasant/zimmer/issues/714)). And the first build no longer has to fit in
memory: the job loads one session at a time rather than materializing every changed session at once,
and archives at most `MAX_SESSIONS_PER_RUN` of them per tick, writing its metadata for the slice it
finished ([#719](https://github.com/tadasant/zimmer/issues/719)). A run that does not get through the
backlog now leaves the next one less to do, which is the property the bootstrap always lacked.

The failure that follows is worth knowing by shape, because it misdirects. The allocation exhausts
the host, so the kernel declares a *global* out-of-memory condition and takes victims across every
cgroup — not just the offender's. sshd and Caddy lose their working set, and the droplet stops
answering SSH on 2222 and HTTPS on 443 at the same moment. From outside, that is indistinguishable
from a droplet that is down, rebooting, or wedged; DigitalOcean meanwhile reports it `active` with
no power events, because nothing about the virtual machine has changed. The app is fine throughout.
`/up` answers 200 in under a tenth of a second the moment the pressure lifts.

Staging's worker carries `memory: 2g` (`config/deploy.staging.yml`). That does not prevent the
runaway; it confines it. The kill lands in the worker's cgroup, the worker restarts under
`unless-stopped`, and sshd stays up — which is the property that matters, because the alternative is
an outage nobody can log in to diagnose. It does not make the queue usable, though: a worker
restarting every ten minutes is a queue that never drains.

So on staging the `transcript_archive` cron key is also disabled at runtime, in the
`good_job_settings` table (`cron_keys_disabled`), which is what actually stops the loop. That is a
live database row rather than anything in this repository, so it survives deploys and is invisible
in the config: staging builds no transcript archives until someone runs
`GoodJob::Setting.cron_key_enable("transcript_archive")`.

That row is still set. Re-enabling it is what would prove #495's fix against a real corpus, and it is
also the reason the fix could not be verified on staging before shipping — the environment kept for
reproducing this has the job switched off in a place no deploy reaches. Nothing re-enables it
automatically; someone has to, once, and watch the first few ticks.

Production's worker carries `memory: 10g` (`config/deploy.production.yml`), for the same reason and
with the same effect — but the number is derived from its own droplet rather than copied, and the
runaway it is sized against is a different one. On production the dominant consumer is not #495 but
[#449](https://github.com/tadasant/zimmer/issues/449): the `good_job` process itself climbs from
~700 MB at rest to **11.6 GB RSS in about eighteen minutes** under ten to thirteen concurrent
sessions, and then dies. Why it grows is still unknown.

Uncapped, that climb is what the 16 GB is spent on. Measured on 2026-08-14, the host reached 139 MB
available with 40% iowait and a load average of 13.57 on 8 vCPU; single-row `SELECT`s took 31
seconds, the queue backed up until it paged, and every agent session on the box slowed down — and
the process died at the end of it anyway, taking each session's child process with it. So the cap
does not decide whether the worker restarts. #449 does that either way. The cap decides whether the
restart is preceded by several minutes of host-wide thrash.

`10g` sits between two measured bounds. Below it, a healthy worker must never reach the cap: 1.6 GiB
of anon at three concurrent sessions. Staging's `2g` sits *under* that floor, which is why copying
that number here would have OOM-killed the worker on the deploy that applied it. Above it, the cap
has to trip before the host degrades: #449's thrash set in at 11.6 GB, so `10g` stops short of it
and still leaves 5.6 GiB against the 0.9 GiB everything else on the droplet actually uses.

One thing is deliberately not claimed: that `10g` sits above the worker's true peak demand. The
per-session figure behind the floor was taken at three concurrent sessions, #449 was observed at ten
to thirteen, and nothing establishes that the cost per session stays linear in between — so a heavy
enough load may reach the cap. That is accepted rather than solved. At that same load, uncapped,
#449 already ends in a dead worker about twenty minutes in; the cap does not add a failure, it
relocates one out of the host and into a cgroup, before the box has spent minutes thrashing on the
way there.

The margin was also read as comfortably above #495's 2.8 GB, and therefore as meaning that job could
not become a restart loop on production the way it does on staging. That inference was wrong, and
[#719](https://github.com/tadasant/zimmer/issues/719) is what it cost. 2.8 GB is what the allocation
costs *on staging's corpus*; the job loads every session that has a transcript, so its peak is a
function of corpus size, and production's corpus is far larger than staging's. Once fleet telemetry
reached the production droplet on 2026-08-31 it caught the same loop running there — four
`CONSTRAINT_MEMCG` kills in 46 minutes, anonymous memory climbing from a 1.5–2.5 GiB baseline to the
10 GiB cap, on a ten-minute period matching the `transcript_archive` cron exactly. Carrying a figure
measured on one environment's data across to another environment's is the mistake worth not repeating
here: for a job whose allocation is a function of the data it touches, the number does not travel.

None of this fixes #449; it bounds the blast radius. Under sustained heavy load the worker still
restarts and still interrupts the sessions it supervises. What changes is that the rest of the
droplet no longer goes down with it, and headroom stops being asked to do a bound's job — which it
cannot, since an allocation with no steady state has no ceiling any droplet size is guaranteed to
sit above.

Two diagnostic notes, since this one wastes time in a predictable way. `staging.zimmer.tadasant.com`
resolves to a **tailnet** address, and the droplet's firewall allows inbound UDP/41641 only — so a
curl from off the tailnet times out whether staging is healthy or not, and that timeout is never
evidence of anything. And a Kamal `RestartCount` climbing into the hundreds on the worker is the
signature of this loop rather than of a crash on boot. Reach for `dmesg -T | grep oom-kill` before
the application logs, which show nothing at all across the window. Grep that line rather than the
`Out of memory: Killed process` one: the victim line names the process but not the scope, and it is
the `oom-kill:` line that carries both `global_oom` — host-wide, every cgroup at risk — and
`task_memcg=/system.slice/docker-<id>.scope`, which is the container ID to blame.

---

## The worker wedge is detected and reported, not fixed

A cgroup OOM under `sysbox-runc` can leave the worker container reporting `running` with
`Restarts=0` while every `docker exec` into it fails, so it runs nothing while looking
healthy ([#502](https://github.com/tadasant/zimmer/issues/502)). `zimmer-worker-watchdog`
catches that — a real `docker exec` on a 60-second timer, on the host, outside the thing it
is watching. See [When the worker wedges](/operate/nested-docker/#when-the-worker-wedges).

What it does **not** do is make the failure survivable, and four gaps are worth stating.

**The last rung of recovery is manual.** The watchdog kills the container's shim and
retries `docker start`, which is where the wedge usually ends: `sysbox-mgr` refuses the
container id it already holds (`redundant container registration`), and only a *new* id
gets past that. Creating one needs a redeploy, and nothing on the host can run one — so the
automated path stops at a container in `exited` and keeps paging — once a wedge has been
reported, the watchdog repeats "no worker is running" on its re-alert throttle until a
healthy worker exists, because `docker ps` stops listing the container and the probe would
otherwise go silent. That is deliberate: `docker rm` cannot be undone from the host, so a misfire would
turn a wedged worker into no worker.

**The root cause inside sysbox is still unknown.** Nobody has established *why* the
namespace becomes unusable after the OOM, only that it does and that every documented
Docker recovery path fails. The watchdog treats a symptom.

**Detection has to be installed, and on production nothing in this repository installs it.**
`Deploy staging` converges the timer on every deploy. The installer now takes the two knobs a
different deploy path needs — `ZIMMER_WATCHDOG_SSH_EXTRA` for how to reach the host and
`ZIMMER_WATCHDOG_RECOVER` for whether recovery is armed — but the production deploy workflow
that would call it lives in the private companion repo, and until it does, production has no
detection at all, silently.

**Delivery depends on the web container.** The alert reaches Slack by running
`bin/rails zimmer:worker_wedge_alert` inside the *web* container, because the worker is the
broken thing and the Slack credentials live in Rails' encrypted credentials rather than
anywhere a host script can read. If web is also down — a whole-host OOM rather than a
cgroup-scoped one — the incident is still written to
`/var/lib/zimmer-worker-watchdog/incidents/` and to journald, but nobody is paged.

---

## The phantom re-pick guard is process-local

`AgentSessionJob::LIVE_EXECUTIONS` is what tells a real interruption apart from a row GoodJob
re-picked out from under a live execution — see [a live execution is not an
interruption](/sessions/lifecycle/#a-live-execution-is-not-an-interruption). It is an in-memory
set, and that is deliberate: a worker that genuinely died has to take its entries with it, or the
guard would stand down on exactly the sessions that need recovering.

The cost is that it only answers for the process it lives in. A re-pick that lands in a *second*
worker process finds an empty set, concludes nothing is running, and takes the recovery path —
delivering the nudge this guard exists to suppress. Zimmer's `worker` role is one container on one host running one
`bundle exec good_job start` (`config/deploy.production.yml`), so today every re-pick lands where
the entry is; scaling that role horizontally would see the old behaviour return in proportion to
how often the poll lands on the other process.

There is no durable version of the signal available. GoodJob writes no `locked_by_id` under the
`:advisory` strategy, so the row itself records nothing about who is executing it, and a PID check
cannot distinguish a live execution from a [reparented
orphan](/sessions/spawning/#one-live-agent-process-per-session) whose monitor really did die.

The same set is what `CleanupOrphanedSessionsJob` and `DeploymentRecoveryJob` consult before
calling a `running` session orphaned, and GoodJob's cron runs inside the worker, so today all
three actors read the same set. Scaling the `worker` role past one container splits them.

---

## Two narrow gaps in the InterruptError stand-down

`AgentSessionJob#handle_interrupt_error` stands down when a session has already come to rest — in
`needs_input` after a normal turn completion, or in `waiting` after a deliberate sleep. Two narrower
gaps remain, both deliberate:

- The status is read once, before the guard. A session that pauses in the moment *between* that read
  and the guard falls through to the old behaviour. The window is small and the failure is the
  pre-existing one, so it is left rather than papered over with a lock.
- Standing down leaves `running_job_id` pointing at the dead job where the recovery path would have
  cleared it. That is what the orphan sweep is for, and it only reaches sessions in `running` or
  carrying `paused_by: "recovery"` — a session at rest with a stale job id is inert, but it is not
  tidied either.

## The historical backfill sweeps forward only, and "complete" means one pass

`TokenUsageBackfillJob` walks transcript directories in sort order and records a cursor. A directory
created *while a run is in flight* that sorts **before** the cursor is never visited by that run.
That is deliberate rather than an oversight: a directory created mid-run holds files written
mid-run, and `TokenUsageIngestionJob`'s two-hour lookback on a 10-minute cron already has them. But
it does mean the backfill alone is not a coverage proof — the two jobs are, together.

Two consequences worth knowing:

- **`complete` means "one pass finished", not "the ledger is exhaustive".** A transcript that was
  unreadable when its chunk ran (a permission error, a file deleted mid-scan) is skipped, the chunk
  still commits, and the run still finishes. `covers_since` on the Costs page is the oldest row
  actually stored, which is the honest figure; nothing claims every call ever made is in there.
- **A transcript root that gets emptied is invisible.** If `~/.claude/projects` is wiped, a re-scan
  completes instantly against nothing and the ledger keeps whatever it already had. The rows are
  durable, so this loses no history — but a fast, clean "complete" is not evidence that the corpus
  was read.

`progress_pct` is also approximate while a run is in flight: the denominator is re-derived each
slice from the directories still ahead of the cursor, so it moves as clones are created and cleaned
up. It is a progress bar, not an accounting.

---

---

## Context-feature attribution is an estimate with a large residual

`token_usage_features` says which context-management feature a request's tokens paid for.
Nothing in the API supports that: the `usage` object is a per-request total with no
per-content-block decomposition, so every figure in that table is derived from transcript
content rather than measured.

The estimate is built not to mislead — shares are divided by `max(estimated, actual)` so the
parts cannot exceed the whole, and the shortfall is carried as an explicit unattributed line
— but the shortfall is big. On this deployment about **56% of tokens** land there. Three
things account for most of it, and none is fixable from this side (a fourth, below, is smaller):

- The harness system prompt and the tool schemas of every attached MCP server are in every
  priced prompt and in no transcript. This is the bulk of it, and it is a per-request
  *constant*, so it dominates short conversations.
- Extended thinking is written to the transcript as `thinking: ""` plus a signature. Across
  955 thinking blocks in the recent corpus, not one retained its text. The signature is
  counted; the reasoning is not.
- System reminders — including the injected CLAUDE.md — are usually not persisted either.
- A turn whose prompt cache has expired re-writes the whole prefix, so its
  `cache_creation_input_tokens` covers content the attributor is holding as already-carried.
  The estimate for that turn stays small and the re-write lands in the residual. Those are the
  expensive turns, and the content being re-written is exactly the always-appended material the
  page exists to indict, so the residual is understating the very thing it is asked about.

So the table ranks features against each other honestly and does **not** account for the
majority of the bill. Read it as "of the context I can see, here is the split", and do not
cut a feature on a thin margin.

## A feature detector can only be backfilled as far as transcripts survive

Adding a detector is one entry in `ContextFeatureRegistry` plus a re-ingest, and because
ingestion is an idempotent scanner over files on disk, the new detector is applied to
history for free. That is bounded by Claude Code's own retention of
`~/.claude/projects`, which on this deployment holds about **30 days** in bulk.

The usage rows themselves are unaffected — they are already stored, and their totals do not
change. Only the per-feature split is limited: a detector added today cannot explain spend
from three months ago, because the evidence it would read has been pruned. Nothing warns
about this; the older part of the window simply shows a larger unattributed share.

## Experimental-setting cohorts are observational, and the first one is purely temporal

The Costs page compares spend on each side of an experimental setting. Nothing about it is a
controlled experiment, and three limits are worth stating rather than discovering:

- **The settings are global.** A cohort is "every session that ran while the setting was on",
  not a random assignment. Whatever else changed over the same stretch is inside the cohort.
- **A backfilled setting's cohorts are a date, not a treatment.** For `mcp_tool_search`, "off"
  is every session before 2026-08-22 13:55 UTC and "on" is every session after it, so anything
  that landed the same afternoon — including the token-usage accounting changes in #591, two
  hours later — is perfectly confounded with the setting. This is stated on screen next to the
  number, but no amount of stating fixes it: only toggling the setting back and forth, which
  makes the cohorts interleave in time, produces a comparison the data can carry.
- **Normalization is partial.** Cost per API call divides out session length. It does not
  divide out which model ran or what the work was. The paired-by-root drilldown holds the
  agent root constant; it holds nothing else constant.

The report refuses to print a percentage when a side has fewer than 5 sessions or 50 API calls
in the window, and it excludes sessions whose start and end values disagree. Those guards stop
the most obvious wrong readings. They do not turn an observational comparison into a causal
one, and a thin report saying "not enough data to compare" is the correct output, not a bug.

## Session-scoped credentials leave the shared file behind, on purpose

The [session-scoped credentials setting](/auth/harness/#session-scoped-credentials-the-db-owns-the-chain)
removes `~/.claude/.credentials.json` as a source of truth for subscription tokens, but it does not
delete the machinery that manages it: the owner marker, `sync_tokens_from_filesystem!`, the symmetric
write guard, `credentials_blob_for_disk`, the completeness guards. All of it is dormant with the
setting on and load-bearing with it off, because the off path is the rollback.

So while the setting is being rolled out there are two credential mechanisms in the codebase and
exactly one of them runs. That is the intended state, not an oversight — but it means a reader of
`ClaudeAccount` or `AccountRotationService` sees guards defending a file that, in production with the
setting on, nothing reads. The machinery comes out when the setting is on everywhere and the rollback
is no longer wanted.

Two narrower gaps while both exist:

- **A revoked MCP credential is not removed from other sessions' stores.** `RefreshMcpOauthTokensJob`
  has no session to scope to, so it targets the host-global file. Revoking through
  `McpOauthCredentialInjector#delete_runtime_credentials` does reach the revoking session's own
  store, but a *different* session already running keeps its copy until it ends. New sessions get a
  fresh directory, so the window is one session's lifetime, not indefinite.
- **A corrupt shared file stays corrupt while the setting is on.** `ClaudeCredentialHealth.self_heal!`
  declines to repair it, because rewriting a file nothing reads on a five-minute cron is noise rather
  than a repair. If the setting is later turned off, the next `ensure_active_account!` rewrites the
  file from the DB — but until then the stale bytes sit there.

## An agent that never calls `get_session_provenance` never learns it has a hierarchy

Zimmer injects nothing about provenance into a session's turns — no `<session-hierarchy>` block, no
`<human-messages>` block. The lineage graph and the human-message record are served by the
`get_session_provenance` MCP tool, on demand, and that tool's description carries every caveat the
injected blocks used to state. See [Hierarchy and human
messages](/sessions/hierarchy-and-human-messages/#where-they-show-up).

The cost is discoverability, and it is real. An injected block is unmissable: a session that never
thought to ask about its lineage learned it had one anyway, and learned that only `here` messages
were spoken to it. A tool is not. An agent that never calls it will not find out that a human said
something to the router above it, will not know which siblings share its goal, and nothing in its
turn will prompt it to look. The failure is silent in the worst direction — the session proceeds as
if no human context existed, which is indistinguishable from there being none.

Three things bound it rather than fix it: the tool is in the `self_session` group, so every session
carries it; its description leads with the instruction to call it before relying on what a human
asked for; and a test asserts each caveat is present in that description, so it cannot be shortened
into uselessness. None of that makes an agent call it.

The trade is deliberate. The blocks were re-injected on every turn of every session and billed again
on each later turn they stayed in context, while most sessions never read an older human message.
Whether the outcome cost exceeds the token saving is not something the current instrumentation can
answer: the Costs page shows `session_hierarchy` and `human_messages` trending to zero and
`provenance_tool` picking up, which measures the bytes, not the decisions.

## A restart from scratch can still page before its re-clone finishes

`TranscriptPollerService` decides how loudly to report a missing `working_directory` from the
session's lifecycle state: `waiting` means it was never spawned and logs at INFO, and every
other state logs at ERROR because the spawn should have written the key
([#473](https://github.com/tadasant/zimmer/issues/473), and
[Observability](/operate/observability/#a-lifecycle-state-the-session-has-not-reached-yet-is-logged-at-info-not-error)).

One state disagrees with that reading. `restart_from_scratch` strips `working_directory` along
with the rest of `Session::SETUP_ARTIFACT_KEYS`, resumes the session to `running`, and only
then enqueues the job that re-clones. A poll landing in that window sees a `running` session
with no `working_directory` and pages, on a session a human just deliberately restarted.

The state cannot tell that apart, which is why the split does not try to: a session mid-restart
and a session whose spawn silently failed to record its directory are the same two fields. It
predates the INFO/ERROR split and the split neither causes it nor fixes it. Closing it means a
positive marker for "a re-clone is in flight" rather than a wider exemption — widening the
exemption to "any session without the key" would swallow the defect the ERROR exists to catch.

## Nothing prunes the transcripts the old Claude auth probe left behind

`CliStatusService` used to check Claude Code's auth with `claude whoami`. `whoami` is not a
subcommand and `claude`'s usage line is `claude [options] [command] [prompt]`, so the CLI took
the word as a *prompt* and answered it with a full agent turn — every two minutes, on cron,
for months ([#536](https://github.com/tadasant/zimmer/issues/536)). The check no longer makes
a model call, so the bleeding has stopped.

The debris has not been cleaned up. Each of those runs left a JSONL transcript under
`~/.claude/projects/-rails/`, and tens of thousands of them are still on the `claude_home`
volume. Nothing in Zimmer prunes that directory — `StaleCloneCleanupJob` sweeps clones and
per-session config dirs, not the shared projects tree — and deleting them by hand would need a
shell on the production box, which is exactly the ops shape
[the deploy is supposed to replace](/operate/deploying/). They are inert: `TokenUsageBackfill`
has already ingested them, so they cost disk rather than money or correctness.

## `claude auth status` cannot see the credential Zimmer's containers use

The obvious replacement for the probe above was `claude auth status` — a real subcommand, and
the direct analog of the `gh auth status` and `codex login status` in the same hash. It is the
wrong check here. Verified against CLI 2.1.258, it reports only credentials it finds in the
*environment*: `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`. Pointed at a
`~/.claude/.credentials.json` holding a complete `claudeAiOauth` pair — the store the `web` and
`worker` containers authenticate from — it prints `Not logged in` and exits 1. It also exits 0
for an `ANTHROPIC_API_KEY` that is pure nonsense, because presence is all it checks.

So the CLI has no invocation that answers "is Zimmer's stored Claude credential usable", and
the check reads `ClaudeCredentialHealth` in-process instead. That is the better answer anyway —
it follows the credential into the DB under
[session-scoped credentials](#session-scoped-credentials-leave-the-shared-file-behind-on-purpose),
where no file exists to inspect — but it does mean the Claude Code tile is reporting on
Zimmer's own credential store rather than on what the binary would do if you ran it. Two
consequences worth stating plainly, because the tile does not state them:

**The tile reports presence, not liveness.** `ClaudeCredentialHealth` bottoms out in
`ClaudeAccount.complete_claude_oauth?`, which asks whether an access token and a refresh token
are both there and non-empty. It does not ask Anthropic. A revoked or spent pair sitting on disk
reads as *Authenticated*. `claude whoami` did make a real call, so it was — incidentally, and at
about \$615/mo — the only liveness signal this tile ever had. What catches a dead credential now
is the account pool's own refresh sweep and the auth-outage park, both of which run against the
vendor; the tile is a configuration check, like the three beside it.

**Under session-scoped credentials it reports on one account, not on the pool.**
`ClaudeCredentialHealth#database_status` keys off `ClaudeAccount.current_account`, because that
is the row a spawning session is actually handed a token out of. So a deployment with the setting
on can show *Not Authenticated* while a perfectly healthy pool sits behind it — no row is current
yet on a fresh worker, or the current row's stored pair is incomplete and
`AccountRotationService` would rotate past it on the next spawn. The setting is off by default, and
the same narrowing is already what the `/health` Agent Authentication card reports, so the two
surfaces agree; `/quotas` is the page that shows the whole pool.

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
