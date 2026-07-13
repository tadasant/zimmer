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
and no data. A deployment can sit in that state indefinitely, and nothing anywhere says so.

The no-op is the right default (it keeps dev, test, and CI off the network), so the mitigation is
visibility rather than a hard failure: `deploy-staging.yml` prints an observability preflight on every
run, and `bin/rails obs:status` / `bin/rails obs:smoke` answer the question from inside the container.
Absence of data is still never, by itself, evidence of absence of errors.

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

### `claude update` runs in the background at boot

`bin/docker-entrypoint` backgrounds `claude update` and the Playwright browser install. Sessions
started in the first ~30 seconds after a container boot use the old CLI and Chromium.

Tracked in [#122](https://github.com/tadasant/zimmer/issues/122).

### The tailnet reaper no-ops without credentials, and says nothing

`scripts/tailnet-reap-node.sh` does nothing when `TS_API_CLIENT_*` are unset, so the MagicDNS name
drifts to `zimmer-staging-1`, `-2`, … The health check compensates by trying every online peer with
that name — so it works, and you accumulate dead nodes with no error.

Tracked in [#123](https://github.com/tadasant/zimmer/issues/123).

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

---

## Security

### The web UI has no login, by design (and the sharp edge that follows)

🔴 No login screen is deliberate. For a [single circle of trust](/intro/philosophy/), the network
perimeter is the authentication boundary (see [Auth overview](/auth/overview/)), so `ApplicationController`
has no `before_action` for auth and there are no login routes or `User` model. Zimmer's own Terraform
puts the app on a Tailscale tailnet with port 80 closed at the DigitalOcean firewall.

The sharp edge is real and load-bearing. Expose port 80 and there is no second wall. Worse, the
`/supervisor` Administrate panel is served with the auth stubbed out —
`app/controllers/supervisor/application_controller.rb:12`:

```ruby
def authenticate_supervisor
  # TODO Add authentication logic here.
end
```

It renders `claude_accounts` (whose `oauth_config` JSONB holds plaintext Anthropic and OpenAI access and
refresh tokens), `mcp_oauth_credentials`, `x_oauth_credentials`, and `runtime_login_attempts` as editable
resources. On a public perimeter, that hands an anonymous visitor your refresh tokens. There are also six
`# TODO: Add proper authorization checks` comments in `sessions_controller.rb` (`:63`, `:687`, `:724`,
`:751`, `:790`, and `:1475`, the last on transcripts, which "contain sensitive conversation data").

Tracked in [#42](https://github.com/tadasant/zimmer/issues/42) and [#44](https://github.com/tadasant/zimmer/issues/44).

### Nothing is encrypted at rest

🔴 Uniform trust means Zimmer leans on the perimeter rather than field-level encryption. No model declares
`encrypts`, no `active_record.encryption` config exists, and every OAuth token, client secret, and PKCE
verifier is a plaintext column. `XOauthCredential`'s own header says the quiet part: *"Security relies on
database access controls."* The sharp edge is the same one as above — the unauthenticated admin panel
bypasses those controls, so a broken perimeter exposes the tokens in the clear.

Tracked in [#43](https://github.com/tadasant/zimmer/issues/43).

### The elicitation endpoints are unauthenticated

`POST /api/v1/elicitations` and `GET /api/v1/elicitations/:id` skip the API key (required by the MCP
fallback protocol — the child process has no key). Anyone who can reach the host can create an
elicitation for any session id, or enumerate and poll any elicitation by `request_id`.

Tracked in [#45](https://github.com/tadasant/zimmer/issues/45).

### `GET /api/secrets/keys` is unauthenticated

`Api::SecretsController` inherits `ApplicationController`, not `Api::BaseController`. It leaks secret
*names and descriptions* (not values).

Tracked in [#45](https://github.com/tadasant/zimmer/issues/45).

### API keys have no scope, identity, or audit trail

Opaque strings from `ENV["API_KEYS"]`, memoized per request. Any valid key can do anything to anything.
Rotation requires a restart. No record of which key did what.

Tracked in [#46](https://github.com/tadasant/zimmer/issues/46).

### The MCP OAuth loopback check is a substring match

```ruby
redirect_uri.include?("localhost") || redirect_uri.include?("127.0.0.1")
```

`https://localhost.evil.com` matches.

Tracked in [#47](https://github.com/tadasant/zimmer/issues/47).

### No timeout on the OAuth token exchange

`McpOauthService#exchange_code_for_tokens` uses `Net::HTTP.post_form` with no timeout, unlike its
siblings which set 30 seconds.

Tracked in [#48](https://github.com/tadasant/zimmer/issues/48).

### Agents run unsandboxed on the app host

`lib/execution/providers/remote_sandbox.rb:6` — the remote sandbox provider is a stub. Every method
returns `Result.failure("not yet implemented")`. Local filesystem is the only real provider. Agents run
as the app user, on the app host, with the app's git and `gh` credentials, spawned with
`--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox`.

Tracked in [#49](https://github.com/tadasant/zimmer/issues/49).

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

### Triggers make the agent a trusted courier for untrusted input

[Issue #18](https://github.com/tadasant/zimmer/issues/18): there is nothing between "Slack event
arrived" and "agent running" except a `gsub` on a `prompt_template`. Untrusted Slack text is
interpolated into the prompt, and the agent is then trusted to act on identifiers it read out of that
text. No validation, no trusted identifiers.

Tracked in [#50](https://github.com/tadasant/zimmer/issues/50).

---

## Agent harness

### Failure classification is regex against CLI prose

🔴 Everything Zimmer knows about *why* a session died comes from string-matching English:

| What | Pattern | File |
| --- | --- | --- |
| Quota exhausted → rotate accounts | `/hit your\b.*\blimit\b.*\bresets\b/i` | `api_error_retry_service.rb:116` |
| Auth lost → re-inject and respawn | `/not logged in\|please run\s*\/login/i` | `auth_recovery_service.rb:79` |
| Context overflow → compact and retry | a pattern list | `context_length_retry_service.rb:44` |
| Corrupted npx cache → delete it | `ENOTEMPTY`, `ERR_UNSUPPORTED_DIR_IMPORT` | `npx_cache_heal_service.rb:75` |

This has already caused an outage. When Claude Code's wording changed, account rotation stopped firing:
the session fell through to the transient-rate-limit path, retried six times against an already-capped
account, and failed, with no log line saying rotation should have happened. The failure mode is silent
by construction.

Tracked in [#53](https://github.com/tadasant/zimmer/issues/53).

### `CodexRetryStrategy` classifies almost nothing

🔴 It returns `false` from `context_length_error?`, `api_error_for_retry?`, and
`auth_recovery_needed?`, and only matches `/no rollout found/i`. Exit 0 is treated as success.

For a Codex session that means: no context-length compaction retry, no API-error retry, no quota
rotation, and no auth recovery. Everything the Claude path does to keep a session alive, Codex does
without.

Tracked in [#54](https://github.com/tadasant/zimmer/issues/54).

### The retry-strategy interface is under-declared

`ProcessLifecycleManager` calls five predicates. The base class docstring lists four. The
contract test checks three. A new runtime that implements exactly what's documented will
`NoMethodError` on the auth-recovery path — at runtime, in production, on an already-failing session.

Tracked in [#56](https://github.com/tadasant/zimmer/issues/56).

### `find_main_transcript` is required but not on the base class

`TranscriptPollerService` calls it on every poll; both concrete sources implement it; it's absent from
the abstract `TranscriptSource`. A new source implementing only the declared interface `NoMethodError`s
on its first poll.

Tracked in [#56](https://github.com/tadasant/zimmer/issues/56).

### Elicitations silently do nothing on Codex

`ELICITATION_SESSION_ID` is injected only by `ClaudeSpawnEnv`. `CodexRuntimeAdapter` never sets it, so
Codex sessions' MCP servers have no session id to send. The controller logs a warning; the user sees
nothing; the agent hangs until its MCP call times out.

Tracked in [#55](https://github.com/tadasant/zimmer/issues/55).

### Extension env contributions are unreachable from Codex

`Zimmer::ExtensionRegistry.spawn_env_contributions` is called only from `ClaudeSpawnEnv` — despite the hook
receiving a `runtime` context that implies it's generic.

Tracked in [#54](https://github.com/tadasant/zimmer/issues/54).

### Shared code still says "Claude"

`TranscriptPollerService` logs *"Waiting for Claude CLI to create transcript directory…"* for every
runtime. `SubagentTranscript#open_transcript_events` hardcodes `ClaudeTranscriptNormalizer`.

Tracked in [#54](https://github.com/tadasant/zimmer/issues/54).

### Transcript file selection falls back to mtime

`transcript_file_locator.rb:26-38` — if `session_id` isn't set yet, the main transcript is chosen as the
most recently modified non-`agent-*.jsonl` file. The code's own comment says it's "avoiding the pitfall
of selecting by mtime" while doing exactly that as a fallback.

Tracked in [#57](https://github.com/tadasant/zimmer/issues/57).

### The login flow screen-scrapes a TUI

Hardcoded: the command (`claude auth login --claudeai`), the authorize-URL host regex, the literal
prompt `/Paste code here/i`, and the binary path `/home/rails/.local/bin/claude`. Codex likewise, with a
device-code regex tuned to an *observed* 4–5 character split.

Tracked in [#58](https://github.com/tadasant/zimmer/issues/58).

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

### The owner-marker "legacy fallback" doesn't exist

`docs/AUTH_ROTATION_ARCHITECTURE.html` (invariant I2) and the docstring on
`ClaudeAccount#sync_tokens_from_filesystem!` both describe a *"legacy `~/.claude.json` fallback while no
marker exists yet."*

`filesystem_credentials_owned_by_self?` has no fallback (no marker means refuse to sync), and its
own comment says so, contradicting the docstring 100 lines above it.

Tracked in [#59](https://github.com/tadasant/zimmer/issues/59).

### One credential file, two writers

`ClaudeAccount#write_credentials_to_filesystem!` whole-file overwrites `.credentials.json`;
`ClaudeMcpCredentialWriter` read-merges `mcpOAuth` into the same file. An account rotation drops any
`mcpOAuth` entries written after the incoming account's blob was captured. It self-heals on the next
spawn, but it's an undeclared coupling.

Tracked in [#60](https://github.com/tadasant/zimmer/issues/60).

### `extract_oauth_email` exists four times

`ClaudeAccount.filesystem_oauth_email` (class), `ClaudeAccount#extract_oauth_email` (dead code —
nothing calls it, yet `CLAUDE_CODE_OAUTH_ASSUMPTIONS.md` pointed readers at it),
`AccountRotationService#extract_oauth_email`, `ClaudeLoginDriver#extract_email`.

Tracked in [#59](https://github.com/tadasant/zimmer/issues/59).

### The rotation safety check fails open

`account_rotation_service.rb:437` — `return true if stored_config.blank? # Can't verify, assume ok`.

Tracked in [#61](https://github.com/tadasant/zimmer/issues/61).

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

Tracked in [#62](https://github.com/tadasant/zimmer/issues/62).

### Codex MCP status reimplements a Rust function in Ruby

`CodexMcpStatusDetector` mirrors `codex-rs`'s `MCP_TOOL_NAME_DELIMITER = "__"` and its
`sanitize_responses_api_tool_name` character rules.

Tracked in [#63](https://github.com/tadasant/zimmer/issues/63).

### Servers without `offline_access` become one-shot credentials

Scope acquisition just joins the server's advertised `scopes_supported`. No `offline_access` ⇒ no refresh
token ⇒ the credential becomes single-use and dies with no way to refresh.

Tracked in [#64](https://github.com/tadasant/zimmer/issues/64).

### "Assume OAuth might be required"

`mcp_oauth_credential_injector.rb:137` — *"If we don't know if OAuth is required, assume it might be"* for
remote servers.

Tracked in [#103](https://github.com/tadasant/zimmer/issues/103).

### The fallback `client_id` is the literal string `"agent-orchestrator"`

Used when a server advertises no DCR endpoint.
**Unclear / needs confirmation:** whether any real server accepts this.

Tracked in [#64](https://github.com/tadasant/zimmer/issues/64).

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

### The only hook in the catalog has no body

🔴 `hooks/hooks.json` declares `git-push-ci-reminder` with `"path": "git-push-ci-reminder"`. The `hooks/`
directory contains only `hooks.json` — there is no such directory.

And `plugins/ci-workflow/.plugin/plugin.json` bundles that hook, and `ci-workflow` is
`default_in_roots: ["agent-orchestrator"]`. Every session on that root activates a hook whose body
doesn't exist. A missing *body* isn't a dangling *reference*, so it slips past the stderr check and
surfaces at `air prepare`.

Tracked in [#65](https://github.com/tadasant/zimmer/issues/65).

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

### The AIR CLI version is pinned in two places

`Dockerfile.base` bakes `@pulsemcp/air-cli@0.13.0`; `AirPrepareService::AIR_CLI_VERSION` must match.
Nothing enforces it.

Tracked in [#68](https://github.com/tadasant/zimmer/issues/68).

### Two catalog configs, kept mirrored by hand

`air.json` and `air.production.json` declare the same six sources and must be kept that way manually.
They differ only in their `description` and their formatting, and nothing checks that the sources still
agree.

Tracked in [#68](https://github.com/tadasant/zimmer/issues/68).

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

### Session `metadata` is a lost-update hazard, by design

`agent_session_job.rb:1073-1078` says it out loud: *"This uses a read-modify-write pattern which is not
atomic… consider using PostgreSQL's jsonb ops."* Correctness-adjacent flags live in it anyway
(`interrupt_terminate_pid`, `pending_follow_up_prompt`), described as *"best-effort FAST PATH, not the
correctness guarantee."*

Tracked in [#70](https://github.com/tadasant/zimmer/issues/70).

### A 2-minute magic number guards against prompt loss

`STALE_UNLOCKED_JOB_AGE` — a job whose lock is older than 2 minutes is superseded, because otherwise
"follow-up jobs silently skip execution because they see a stale 'running' job."

Tracked in [#71](https://github.com/tadasant/zimmer/issues/71).

### The trash retention comment contradicts the constant

The `archive` event's comment says artifacts are "preserved for 14 days." The
`TRASH_RETENTION_PERIOD` constant that governs it is `4.days`.

Tracked in [#72](https://github.com/tadasant/zimmer/issues/72).

### State-machine side effects fail without surfacing

Nearly every callback is wrapped in a bare `rescue` that logs and swallows, so cleanup can be skipped
while the state advances anyway.

Tracked in [#73](https://github.com/tadasant/zimmer/issues/73).

### Prompt attachments live on container-local `/tmp`

`ImageStorageService` (`/tmp/agent-orchestrator-images`) and `FileStorageService`
(`/tmp/agent-orchestrator-files`). In the two-container topology the code's own docs describe, the web
container writes the file and the worker container reads it, and `/tmp` is not shared. Ephemeral, no
S3, despite a "pluggable" comment.

Tracked in [#74](https://github.com/tadasant/zimmer/issues/74).

### The session page auto-refreshes with a `<meta>` tag

`session.rb:573` — a 5-second meta-refresh window, in a Hotwire app.

Tracked in [#102](https://github.com/tadasant/zimmer/issues/102).

### Elicitations expire in 10 minutes

Step away for a coffee and the agent's approval request dies. Not configurable.

Tracked in [#75](https://github.com/tadasant/zimmer/issues/75).

### Orphaned clones linger for up to 48 hours

`OrphanCloneFilesystemCleanupJob` — `AGE_THRESHOLD = 48.hours`, `BATCH_LIMIT = 20`.

Tracked in [#90](https://github.com/tadasant/zimmer/issues/90).

---

## Triggers

### A failed one-time wake is gone forever

`ScheduleTriggerJob` advances `last_triggered_at` on error (to avoid an infinite retry loop) and
destroys one-time triggers even when the fire failed. Nothing tells you.

Tracked in [#76](https://github.com/tadasant/zimmer/issues/76).

### A Slack rate-limit episode stalls all Slack polling

`SlackService` retries 10× with a fixed 1-second blocking `sleep` in a job thread.
`SlackTriggerPollerJob` is confined to a `pollers` queue with `total_limit: 1` to stop it saturating the
pool — so throttling means *no* Slack polling, and ticks are dropped.

Tracked in [#77](https://github.com/tadasant/zimmer/issues/77).

### `thread_ts` is not supported for bot mentions

You can watch a thread for new messages, but not for bot mentions.

Tracked in [#78](https://github.com/tadasant/zimmer/issues/78).

### Everything is polled; there are no webhooks

GitHub PR status and comments are polled every 30 seconds per open PR. A 30-second latency floor and
a steady API burn.

Tracked in [#79](https://github.com/tadasant/zimmer/issues/79).

---

## API

### `refresh_all` always reports `refreshed: 0`

`refreshed_count` is initialized to 0 and never incremented. The old docs' example showed
`"refreshed": 5`.

Tracked in [#80](https://github.com/tadasant/zimmer/issues/80).

### The Settings-page default runtime is ignored without an `agent_root`

`Api::V1::SessionsController#create` only reads `AppSetting.default_runtime` *through* `AgentRootsConfig`.
With no `agent_root`, it returns early and you get the DB column default, `claude_code`. Same for the
model.

Tracked in [#81](https://github.com/tadasant/zimmer/issues/81).

### Three different error shapes

`{error, message: String}`, `{error, messages: Array}`, and `{error, message: Array}` (singular key,
array value, from the `RecordInvalid` rescue). Parse defensively.

Tracked in [#82](https://github.com/tadasant/zimmer/issues/82).

### The only rate limit is global

`Api::V1::HealthController`'s `CLEANUP_COOLDOWN = 30.seconds` is keyed in `Rails.cache` as
`health_api_rate_limit:<action>` — not scoped to an API key. One client's cleanup locks out
everyone for 30s. It no-ops with no error under a null cache store.

Tracked in [#99](https://github.com/tadasant/zimmer/issues/99).

### The in-app API docs page is still stale

`app/views/api_docs/show.html.erb` omits triggers, notifications, health, clis, and transcript_archive —
even though `app/controllers/api/AGENTS.md` requires both doc surfaces to be updated with every endpoint
change.

Tracked in [#34](https://github.com/tadasant/zimmer/issues/34) (removing the page) and
[#95](https://github.com/tadasant/zimmer/issues/95) (nothing tests that the two surfaces agree).

### `agent_root` is read outside strong params

On session create, from raw `params`.

Tracked in [#81](https://github.com/tadasant/zimmer/issues/81).

---

## Hardcoded values that shouldn't be

### `QuotaCheckService` pins a concrete model version

`PROBE_MODEL = "claude-haiku-4-5-20251001"` — in a codebase that ships `ClaudeModelConfigurationAudit`,
a service whose only job is to warn you not to pin concrete model versions.

Tracked in [#85](https://github.com/tadasant/zimmer/issues/85).

### Model IDs are a hardcoded Ruby array

`ModelCatalog::MODELS`. A new model requires a code change and a deploy.

Tracked in [#85](https://github.com/tadasant/zimmer/issues/85).

### `X_OAUTH` bootstrap requires a localhost callback

`DEFAULT_REDIRECT_URI = "http://localhost:8080/callback"` — you must pre-register that on your X app.

Tracked in [#104](https://github.com/tadasant/zimmer/issues/104).

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
  `RESET_TIME = 60`), with no banner telling you.
  ([#86](https://github.com/tadasant/zimmer/issues/86))
- Push notifications don't work on anything without the Push API (iOS Safari outside standalone PWA).
- The OAuth login poller gives up after N consecutive failed polls — a transient blip abandons the
  flow. ([#101](https://github.com/tadasant/zimmer/issues/101))
- Alerts inside a 1-hour dedup window are swallowed, even genuinely new ones.
  ([#86](https://github.com/tadasant/zimmer/issues/86))

---

## Testing

### System tests do not run in CI

🔴 The `test` job runs "unit + integration; system tests excluded." Four of the ten open issues are UI
regressions — exactly the class a system test would catch.

Tracked in [#87](https://github.com/tadasant/zimmer/issues/87).

### Four open flaky-test issues

[#10](https://github.com/tadasant/zimmer/issues/10) (a global `File.stub` racing background threads —
noted as having turned `main` red), [#5](https://github.com/tadasant/zimmer/issues/5),
[#3](https://github.com/tadasant/zimmer/issues/3), [#2](https://github.com/tadasant/zimmer/issues/2).

### Tests that skip themselves in CI

`preregistered_oauth_config_test.rb`, `secrets_loader_test.rb`, `references_config_test.rb`, and
`air_catalog_ref_rewriter_test.rb` (×2). Catalog pinning has zero CI coverage.

Tracked in [#69](https://github.com/tadasant/zimmer/issues/69).

### The contract test doesn't cover the whole contract

It checks 3 of the retry strategy's 5 predicates.

Tracked in [#56](https://github.com/tadasant/zimmer/issues/56).

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

### `GithubPrUrlHook` scans tool results only

Not assistant messages, not user messages. An agent that opens a PR any other way leaves
`custom_metadata["github_pull_request_url"]` empty — and then none of Zimmer's GitHub integration
engages for that session. No warning.

Tracked in [#89](https://github.com/tadasant/zimmer/issues/89).

---

## Open questions

Things the code doesn't answer, flagged here rather than guessed at:

- Does the double-suffixed Redis URL (`redis://redis:6379/0/0`) actually work? The client may tolerate
  it or may fall back to db 0. ([#20](https://github.com/tadasant/zimmer/issues/20))
- Does any real MCP server accept `client_id: "agent-orchestrator"`? It looks like it would only work
  against a server that ignores `client_id` entirely. ([#64](https://github.com/tadasant/zimmer/issues/64))
- What is `tadasant/zimmer-catalog`, and are the five roots pointing at it still live? It's a separate
  repo this documentation can't see. ([#67](https://github.com/tadasant/zimmer/issues/67))
- Is `config_preparer_class` (a `RuntimeRegistry::Bundle` slot) meant to do something? It's `nil` for
  every runtime and nothing reads it. ([#97](https://github.com/tadasant/zimmer/issues/97))
- Which of the two contradictory GoodJob-cron comments is right about sub-minute cron support? The
  config contains both six-field (`*/30 * * * * *`) entries *and* a comment saying seconds aren't
  supported. ([#106](https://github.com/tadasant/zimmer/issues/106))
- Does the macOS Keychain path in `CodexMcpCredentialWriter` work? It has never been runtime-verified
  — every worker is Linux. ([#63](https://github.com/tadasant/zimmer/issues/63))
