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

---

## Deployment

### The shipped Terraform provisions no job worker

🔴 `config/environments/production.rb:59` sets `good_job.execution_mode = :external`, which requires a
separate `bundle exec good_job start` process.

`infra/terraform/cloud-init.yaml.tftpl` renders a compose file with exactly three services: `app`,
`redis`, and (staging only) `db`. There is no worker service, and no `good_job start` anywhere in
`infra/`, the `Dockerfile`, or the workflows.

**Consequence:** on the documented turnkey DigitalOcean path, *no background job ever executes*.
Sessions enqueue and sit forever. No cron fires — no orphan cleanup, no token refresh, no pollers, no
catalog refresh. The staging health check only curls `/up`, so the deploy reports success.

Production presumably runs a different compose file from a private repo. The IaC here is incomplete.

### Production is still on the old compose stack, and shares the Terraform module

🔴 **The most important thing to know right now.** `infra/terraform/main.tf` and
`cloud-init.yaml.tftpl` are mirrored **byte-identical** into the private production repo, enforced by
an `iac-sync` guard. Staging has been cut over to Kamal; **production has not**. It still runs the old
docker-compose stack, driven by its own workflows.

That means the mirrored module is now *ahead of* production:

- `main.tf` declares `backend "s3" {}`, so production's `terraform init` fails until it also supplies a
  `-backend-config`. Its state is ephemeral today, so it additionally needs a one-time
  `terraform import` of the live droplet/firewall/project — otherwise a first apply would try to
  **create** a second one and 409 on the account-unique firewall name.
- The mirrored `cloud-init.yaml.tftpl` no longer contains the app stack at all. `ignore_changes =
  [user_data]` protects the running production box, but if it is ever replaced it would boot with
  Docker + Tailscale + Caddy and **no app**.

Production's `iac-sync` PR must therefore **not** be merged on its own. Its cutover has to land
atomically: backend config + `terraform import` + a Kamal production config + its workflow rewrite,
together. Until then, production keeps running and upgrading in place exactly as before.

### The first deploy onto the new model needs a one-time reap

Remote state starts empty, so the very first `terraform apply` does not know about a pre-existing
`zimmer-staging` droplet/firewall/project — and DO firewall and project names are **account-unique**,
so it would 409. The old droplet also can't simply be imported: it was booted by the old cloud-init and
has no Kamal deploy key authorized, so Kamal could never reach it.

The cutover is therefore: destroy the old droplet + firewall + project once, then `apply`. This is a
one-time cost, and it is the last time staging gets recreated.

### `user_data` is frozen, so the deploy key and the Caddyfile can't be updated in place

The droplet carries `lifecycle { ignore_changes = [user_data] }` — that is what stops app changes from
force-replacing it. The cost: the Kamal deploy public key and the Caddyfile are delivered **only**
through `user_data`, so rotating `KAMAL_SSH_KEY` or changing `var.domain` produces **no plan diff** and
never reaches the box. Both require an explicit `terraform taint digitalocean_droplet.zimmer` — i.e.
deliberately re-creating the droplet, which is exactly the churn this model exists to avoid.

Rotating the deploy key is rare; changing the domain is rarer. But neither is a no-op.

### RAILS_MASTER_KEY is unset on staging

`RAILS_MASTER_KEY` is deliberately absent from staging's Kamal config: there is no committed
`config/credentials/production.yml.enc` to decrypt, `secrets_loader.rb` rescues a missing key, and there
is no `require_master_key` — so the app boots without it. Anything reading Rails encrypted credentials
(i.e. `mcp_secrets`) is therefore inert on staging. `API_KEYS` and `APP_HOST` *are* set (in
`config/deploy.staging.yml`); they used to be missing entirely.

### SSH is open to `0.0.0.0/0`

The firewall comment says "lock down to your admin CIDRs in tfvars if desired." There is no variable
to do that with.

### Double-suffixed Redis URL (fixed, but the sharp edge remains)

`production.rb` builds the cache store as `"#{ENV["REDIS_URL"]}/0"`, so a `REDIS_URL` that already ends
in a database index becomes `redis://…:6379/0/0`. The old compose stack set `redis://redis:6379/0` and
hit exactly that.

`config/deploy.yml` now sets `REDIS_URL: redis://zimmer-redis:6379` — **no trailing `/0`** — so the
app's own suffixing produces a single, correct index. The trap is still there for anyone who "helpfully"
adds the `/0` back.

### `claude update` runs in the background at boot

`bin/docker-entrypoint` backgrounds `claude update` and the Playwright browser install. Sessions started
in the first ~30 seconds after a container boot use the old CLI and Chromium.

### The tailnet reaper silently no-ops without credentials

`scripts/tailnet-reap-node.sh` does nothing when `TS_API_CLIENT_*` are unset, so the MagicDNS name
drifts to `zimmer-staging-1`, `-2`, … The health check compensates by trying every online peer with
that name — so it works, and you accumulate dead nodes with no error.

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

### Nothing is encrypted at rest

🔴 Uniform trust means Zimmer leans on the perimeter rather than field-level encryption. No model declares
`encrypts`, no `active_record.encryption` config exists, and every OAuth token, client secret, and PKCE
verifier is a plaintext column. `XOauthCredential`'s own header says the quiet part: *"Security relies on
database access controls."* The sharp edge is the same one as above — the unauthenticated admin panel
bypasses those controls, so a broken perimeter exposes the tokens in the clear.

### The elicitation endpoints are unauthenticated

`POST /api/v1/elicitations` and `GET /api/v1/elicitations/:id` skip the API key (required by the MCP
fallback protocol — the child process has no key). Anyone who can reach the host can create an
elicitation for any session id, or enumerate and poll any elicitation by `request_id`.

### `GET /api/secrets/keys` is unauthenticated

`Api::SecretsController` inherits `ApplicationController`, not `Api::BaseController`. It leaks secret
*names and descriptions* (not values).

### API keys have no scope, identity, or audit trail

Opaque strings from `ENV["API_KEYS"]`, memoized per request. Any valid key can do anything to anything.
Rotation requires a restart. No record of which key did what.

### The MCP OAuth loopback check is a substring match

```ruby
redirect_uri.include?("localhost") || redirect_uri.include?("127.0.0.1")
```

`https://localhost.evil.com` matches.

### No timeout on the OAuth token exchange

`McpOauthService#exchange_code_for_tokens` uses `Net::HTTP.post_form` with no timeout, unlike its
siblings which set 30 seconds.

### Agents run unsandboxed on the app host

`lib/execution/providers/remote_sandbox.rb:6` — the remote sandbox provider is a stub. Every method
returns `Result.failure("not yet implemented")`. Local filesystem is the only real provider. Agents run
as the app user, on the app host, with the app's git and `gh` credentials, spawned with
`--dangerously-skip-permissions` / `--dangerously-bypass-approvals-and-sandbox`.

### Two hardcoded Slack user IDs, by name, in source

`app/models/trigger.rb:13`:

```ruby
ALLOWED_BOT_MENTION_USER_IDS = %w[U08AENQUFBR U08AX7WMX1S] # Mike, Tadas
```

The default allowlist for who may trigger an agent via Slack bot-mention.

### Triggers make the agent a trusted courier for untrusted input

[Issue #18](https://github.com/tadasant/zimmer/issues/18): there is nothing between "Slack event
arrived" and "agent running" except a `gsub` on a `prompt_template`. Untrusted Slack text is
interpolated into the prompt, and the agent is then trusted to act on identifiers it read out of that
text. No validation, no trusted identifiers.

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

### `CodexRetryStrategy` classifies almost nothing

🔴 It returns `false` from `context_length_error?`, `api_error_for_retry?`, and
`auth_recovery_needed?`, and only matches `/no rollout found/i`. Exit 0 is treated as success.

For a Codex session that means: no context-length compaction retry, no API-error retry, no quota
rotation, and no auth recovery. Everything the Claude path does to keep a session alive, Codex does
without.

### The retry-strategy interface is under-declared

`ProcessLifecycleManager` calls five predicates. The base class docstring lists four. The
contract test checks three. A new runtime that implements exactly what's documented will
`NoMethodError` on the auth-recovery path — at runtime, in production, on an already-failing session.

### `find_main_transcript` is required but not on the base class

`TranscriptPollerService` calls it on every poll; both concrete sources implement it; it's absent from
the abstract `TranscriptSource`. A new source implementing only the declared interface `NoMethodError`s
on its first poll.

### Elicitations silently do nothing on Codex

`ELICITATION_SESSION_ID` is injected only by `ClaudeSpawnEnv`. `CodexRuntimeAdapter` never sets it, so
Codex sessions' MCP servers have no session id to send. The controller logs a warning; the user sees
nothing; the agent hangs until its MCP call times out.

### Extension env contributions are unreachable from Codex

`Ao::ExtensionRegistry.spawn_env_contributions` is called only from `ClaudeSpawnEnv` — despite the hook
receiving a `runtime` context that implies it's generic.

### Shared code still says "Claude"

`TranscriptPollerService` logs *"Waiting for Claude CLI to create transcript directory…"* for every
runtime. `SubagentTranscript#open_transcript_events` hardcodes `ClaudeTranscriptNormalizer`.

### Transcript file selection falls back to mtime

`transcript_file_locator.rb:26-38` — if `session_id` isn't set yet, the main transcript is chosen as the
most recently modified non-`agent-*.jsonl` file. The code's own comment says it's "avoiding the pitfall
of selecting by mtime" while doing exactly that as a fallback.

### The login flow screen-scrapes a TUI

Hardcoded: the command (`claude auth login --claudeai`), the authorize-URL host regex, the literal
prompt `/Paste code here/i`, and the binary path `/home/rails/.local/bin/claude`. Codex likewise, with a
device-code regex tuned to an *observed* 4–5 character split.

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

### The owner-marker "legacy fallback" doesn't exist

`docs/AUTH_ROTATION_ARCHITECTURE.html` (invariant I2) and the docstring on
`ClaudeAccount#sync_tokens_from_filesystem!` both describe a *"legacy `~/.claude.json` fallback while no
marker exists yet."*

`filesystem_credentials_owned_by_self?` has no fallback (no marker means refuse to sync), and its
own comment says so, contradicting the docstring 100 lines above it.

### One credential file, two writers

`ClaudeAccount#write_credentials_to_filesystem!` whole-file overwrites `.credentials.json`;
`ClaudeMcpCredentialWriter` read-merges `mcpOAuth` into the same file. An account rotation drops any
`mcpOAuth` entries written after the incoming account's blob was captured. It self-heals on the next
spawn, but it's an undeclared coupling.

### `extract_oauth_email` exists four times

`ClaudeAccount.filesystem_oauth_email` (class), `ClaudeAccount#extract_oauth_email` (dead code —
nothing calls it, yet `CLAUDE_CODE_OAUTH_ASSUMPTIONS.md` pointed readers at it),
`AccountRotationService#extract_oauth_email`, `ClaudeLoginDriver#extract_email`.

### The rotation safety check fails open

`account_rotation_service.rb:437` — `return true if stored_config.blank? # Can't verify, assume ok`.

---

## MCP

### Codex MCP credentials are a reverse-engineered format, written on every spawn

`CodexMcpCredentialWriter` exists entirely to work around two open upstream Codex bugs
([#15122](https://github.com/openai/codex/issues/15122),
[#17265](https://github.com/openai/codex/issues/17265)). Its format was read out of
`codex-rs/rmcp-client/src/oauth.rs @ rust-v0.133.0`, and it writes two mutually incompatible schemas
(file vs macOS Keychain). The Keychain path has never been runtime-verified — all workers are Linux.

### The Claude credential-key algorithm is a string copy of a private internal

`McpOauthCredential.compute_credential_key` replicates Claude Code's `server|SHA256(compact_json)[0,16]`
key format, including string-munging `": "` → `":"` to fake compact JSON. If Claude Code changes it,
every stored credential becomes unfindable — and the symptom is "the agent says it needs authorization,"
not an error.

### Codex MCP status reimplements a Rust function in Ruby

`CodexMcpStatusDetector` mirrors `codex-rs`'s `MCP_TOOL_NAME_DELIMITER = "__"` and its
`sanitize_responses_api_tool_name` character rules.

### Servers without `offline_access` become one-shot credentials

Scope acquisition just joins the server's advertised `scopes_supported`. No `offline_access` ⇒ no refresh
token ⇒ the credential becomes single-use and dies with no way to refresh.

### "Assume OAuth might be required"

`mcp_oauth_credential_injector.rb:137` — *"If we don't know if OAuth is required, assume it might be"* for
remote servers.

### The fallback `client_id` is the literal string `"agent-orchestrator"`

Used when a server advertises no DCR endpoint.
**Unclear / needs confirmation:** whether any real server accepts this.

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

### The only hook in the catalog has no body

🔴 `hooks/hooks.json` declares `git-push-ci-reminder` with `"path": "git-push-ci-reminder"`. The `hooks/`
directory contains only `hooks.json` — there is no such directory.

And `plugins/ci-workflow/.plugin/plugin.json` bundles that hook, and `ci-workflow` is
`default_in_roots: ["agent-orchestrator"]`. Every session on that root activates a hook whose body
doesn't exist. A missing *body* isn't a dangling *reference*, so it slips past the stderr check and
surfaces at `air prepare`.

### The environment configs describe a catalog that no longer exists

`production.rb` and `staging.rb` comments say `air.production.json` *"uses `github://` URIs to pull from
tadasant/zimmer-catalog."* It doesn't — it's entirely local paths. All of `AirCatalogService`'s
github-cache machinery (catalog pins, `resolved_sha_for`, `pinnable_catalogs`) is dormant
infrastructure, and its tests skip themselves.

### A background thread inside Puma, to fix a container mismatch

`~/.air/cache` is per-container, and the `*/15` refresh cron runs only in the worker — so the web
container's catalog would drift stale for a full deploy cycle. `PeriodicCatalogRefresher` runs a bespoke
background thread *inside Puma* every 300s to compensate.

### The AIR CLI version is pinned in two places

`Dockerfile.base` bakes `@pulsemcp/air-cli@0.13.0`; `AirPrepareService::AIR_CLI_VERSION` must match.
Nothing enforces it.

### Two catalog configs, kept mirrored by hand

`air.json` and `air.production.json` are content-identical today and must be kept that way manually.

### Five roots point at a different repository

`agent-orchestrator`, `agents`, `catalog-management`, and the four `catalog-mgmt-*` phases all have
`"url": "https://github.com/tadasant/zimmer-catalog.git"` — a separate repo not part of this project.
`agent-orchestrator` also has `display_name: "Zimmer"`, the same as the `zimmer` root, making them
indistinguishable in a picker. That looks like a bug.

---

## Sessions

### Session `metadata` is a lost-update hazard, by design

`agent_session_job.rb:1073-1078` says it out loud: *"This uses a read-modify-write pattern which is not
atomic… consider using PostgreSQL's jsonb ops."* Correctness-adjacent flags live in it anyway
(`interrupt_terminate_pid`, `pending_follow_up_prompt`), described as *"best-effort FAST PATH, not the
correctness guarantee."*

### A 2-minute magic number guards against prompt loss

`STALE_UNLOCKED_JOB_AGE` — a job whose lock is older than 2 minutes is superseded, because otherwise
"follow-up jobs silently skip execution because they see a stale 'running' job."

### The trash retention comment contradicts the constant

The `archive` event's comment says artifacts are "preserved for 14 days." The
`TRASH_RETENTION_PERIOD` constant that governs it is `4.days`.

### State-machine side effects fail silently

Nearly every callback is wrapped in a bare `rescue` that logs and swallows, so cleanup can be skipped
while the state advances anyway.

### Prompt attachments live on container-local `/tmp`

`ImageStorageService` (`/tmp/agent-orchestrator-images`) and `FileStorageService`
(`/tmp/agent-orchestrator-files`). In the two-container topology the code's own docs describe, the web
container writes the file and the worker container reads it, and `/tmp` is not shared. Ephemeral, no
S3, despite a "pluggable" comment.

### The session page auto-refreshes with a `<meta>` tag

`session.rb:573` — a 5-second meta-refresh window, in a Hotwire app.

### Elicitations expire in 10 minutes

Step away for a coffee and the agent's approval request dies. Not configurable.

### Orphaned clones linger for up to 48 hours

`OrphanCloneFilesystemCleanupJob` — `AGE_THRESHOLD = 48.hours`, `BATCH_LIMIT = 20`.

---

## Triggers

### A failed one-time wake is gone forever

`ScheduleTriggerJob` advances `last_triggered_at` on error (to avoid an infinite retry loop) and
destroys one-time triggers even when the fire failed. Nothing tells you.

### A Slack rate-limit episode stalls all Slack polling

`SlackService` retries 10× with a fixed 1-second blocking `sleep` in a job thread.
`SlackTriggerPollerJob` is confined to a `pollers` queue with `total_limit: 1` to stop it saturating the
pool — so throttling means *no* Slack polling, and ticks are dropped.

### `thread_ts` is not supported for bot mentions

You can watch a thread for new messages, but not for bot mentions.

### Everything is polled; there are no webhooks

GitHub PR status and comments are polled every 30 seconds per open PR. A 30-second latency floor and
a steady API burn.

---

## API

### `refresh_all` always reports `refreshed: 0`

`refreshed_count` is initialized to 0 and never incremented. The old docs' example showed
`"refreshed": 5`.

### The Settings-page default runtime is ignored without an `agent_root`

`Api::V1::SessionsController#create` only reads `AppSetting.default_runtime` *through* `AgentRootsConfig`.
With no `agent_root`, it returns early and you get the DB column default, `claude_code`. Same for the
model.

### Three different error shapes

`{error, message: String}`, `{error, messages: Array}`, and `{error, message: Array}` (singular key,
array value, from the `RecordInvalid` rescue). Parse defensively.

### The only rate limit is global, not per-key

`Api::V1::HealthController`'s `CLEANUP_COOLDOWN = 30.seconds` is keyed in `Rails.cache` as
`health_api_rate_limit:<action>` — not scoped to an API key. One client's cleanup locks out
everyone for 30s. It silently no-ops with a null cache store.

### The in-app API docs page is still stale

`app/views/api_docs/show.html.erb` omits triggers, notifications, health, clis, and transcript_archive —
even though `app/controllers/api/AGENTS.md` requires both doc surfaces to be updated with every endpoint
change.

### `agent_root` is read outside strong params

On session create, from raw `params`.

---

## Hardcoded values that shouldn't be

### `OrchestratorSystemPromptBuilder` hardcodes `zimmer.example.com`

🔴 `orchestrator_system_prompt_builder.rb:94-102` — a `case Rails.env` with literal
`https://zimmer.example.com` (production) and `https://staging.zimmer.example.com`, with no ENV
override.

Every session URL Zimmer hands to its own agents in production points at a placeholder domain.
(`SelfSessionInjector` has the same placeholders as *defaults*, but at least accepts
`AGENT_ORCHESTRATOR_PROD_BASE_URL`.)

### `QuotaCheckService` pins a concrete model version

`PROBE_MODEL = "claude-haiku-4-5-20251001"` — in a codebase that ships `ClaudeModelConfigurationAudit`,
a service whose only job is to warn you not to pin concrete model versions.

### Model IDs are a hardcoded Ruby array

`ModelCatalog::MODELS`. A new model requires a code change and a deploy.

### `X_OAUTH` bootstrap requires a localhost callback

`DEFAULT_REDIRECT_URI = "http://localhost:8080/callback"` — you must pre-register that on your X app.

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

- Closing the tab can lose your notes. Session and dashboard notes are saved on disconnect via
  `sendBeacon` — "best-effort… nothing to do if it fails."
- The Turbo circuit breaker stops UI updates for 60 seconds when it trips (`THRESHOLD = 5`,
  `RESET_TIME = 60`), with no banner telling you.
- Push notifications don't work on anything without the Push API (iOS Safari outside standalone PWA).
- The OAuth login poller gives up after N consecutive failed polls — a transient blip abandons the
  flow.
- Alerts inside a 1-hour dedup window are swallowed, even genuinely new ones.

---

## Testing

### System tests do not run in CI

🔴 The `test` job runs "unit + integration; system tests excluded." Four of the ten open issues are UI
regressions — exactly the class a system test would catch.

### Four open flaky-test issues

[#10](https://github.com/tadasant/zimmer/issues/10) (a global `File.stub` racing background threads —
noted as having turned `main` red), [#5](https://github.com/tadasant/zimmer/issues/5),
[#3](https://github.com/tadasant/zimmer/issues/3), [#2](https://github.com/tadasant/zimmer/issues/2).

### Tests that skip themselves in CI

`preregistered_oauth_config_test.rb`, `secrets_loader_test.rb`, `references_config_test.rb`, and
`air_catalog_ref_rewriter_test.rb` (×2). Catalog pinning has zero CI coverage.

### The contract test doesn't cover the whole contract

It checks 3 of the retry strategy's 5 predicates.

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

### `GithubPrUrlHook` scans tool results only

Not assistant messages, not user messages. An agent that opens a PR any other way leaves
`custom_metadata["github_pull_request_url"]` empty — and then none of Zimmer's GitHub integration
engages for that session. No warning.

---

## Open questions

Things the code doesn't answer, flagged here rather than guessed at:

- Does the double-suffixed Redis URL (`redis://redis:6379/0/0`) actually work? The client may tolerate
  it or may fall back to db 0.
- Does any real MCP server accept `client_id: "agent-orchestrator"`? It looks like it would only work
  against a server that ignores `client_id` entirely.
- What is `tadasant/zimmer-catalog`, and are the five roots pointing at it still live? It's a separate
  repo this documentation can't see.
- Is `config_preparer_class` (a `RuntimeRegistry::Bundle` slot) meant to do something? It's `nil` for
  every runtime and nothing reads it.
- Which of the two contradictory GoodJob-cron comments is right about sub-minute cron support? The
  config contains both six-field (`*/30 * * * * *`) entries *and* a comment saying seconds aren't
  supported.
- Does the macOS Keychain path in `CodexMcpCredentialWriter` work? It has never been runtime-verified
  — every worker is Linux.
