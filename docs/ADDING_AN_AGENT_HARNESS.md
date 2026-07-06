# Adding an Agent Harness (Runtime)

This is the **exhaustive checklist** for adding a new coding-agent runtime to Agent
Orchestrator — a "harness" like Claude Code or Codex, and next perhaps Pi, OpenCode,
Gemini CLI, Aider, etc.

AO already supports two runtimes (`claude_code` and `codex`). Codex was added
incrementally, and almost every integration point below was discovered the hard way —
a feature would look done, ship, and then break in production on some seam nobody
remembered existed. This document exists so the **next** runtime can be added with
**eyes wide open to every integration point**, instead of rediscovering them one
outage at a time.

> **How to use this doc:** Treat the checklist as a punch-list. Each section names the
> file(s) to touch, the contract/methods to implement, and a **"Ways Codex bit us"**
> callout capturing the specific bug we already paid for. If you skip a section, you
> are very likely re-introducing a bug we already fixed.

## Mental model: the pluggable runtime architecture

A "runtime" is not a single class — it is a **bundle of pluggable role classes**, one
per seam where driving a CLI differs between vendors. The seams are:

| Seam | What differs between runtimes |
| --- | --- |
| CLI adapter | command line, flags, resume semantics, env vars |
| Retry strategy | how to classify an exit (success / transient / quota / fatal) |
| Transcript source + normalizer | where the agent writes its transcript, and its format |
| MCP status detector | how to tell which MCP servers connected |
| Prompt contribution | how the system prompt is delivered; project-instructions filename |
| Config post-processor | MCP config file format (`.mcp.json` JSON vs `.codex/config.toml` TOML) |
| MCP credential writer | where vendor MCP credentials live on disk |
| Auth provider + login driver | token endpoints, credential file layout, refresh cadence |
| Model catalog | which models the runtime offers |
| AIR adapter | which `air prepare <adapter>` adapter prepares the clone |

The two central registries are:

- **`app/services/runtime_registry.rb`** — maps an `agent_runtime` string to a
  `Bundle` of role classes. `DEFAULT_RUNTIME = "claude_code"`.
- **`app/services/model_catalog.rb`** — maps an `agent_runtime` to its list of
  selectable models.

Almost everything else resolves through `RuntimeRegistry.for(runtime)` or
`ModelCatalog.*_for(runtime)`. **A new runtime is "registered" the moment it has a
`Bundle` in `RuntimeRegistry::BUNDLES` and a `MODELS` entry in `ModelCatalog`** — but
registering it only makes it *selectable*. Each role class below must actually be
implemented or the runtime will fail at that seam.

> **Golden rule:** Never reference a concrete runtime's classes/constants from shared
> code. Always resolve through the registry. The reason most of the bugs below were
> one-line fixes is that the seam already existed; the reason they happened at all is
> that some shared code branched on `claude` directly or hardcoded a Claude string.

> **Runtime vs extension — don't confuse the two.** A *runtime* is a vendor harness
> (Claude Code, Codex). An **AO Extension** (`app/extensions/<id>/`, see
> [AO_EXTENSIONS.md](AO_EXTENSIONS.md)) is an orthogonal, *removable* layer that
> substitutes a role class (e.g. the `pty_transport` extension swaps
> `PtyClaudeCliAdapter` in for the claude_code default) or contributes spawn env,
> resolved through `Ao::ExtensionRegistry` so it can be deleted for the OSS build.
> If the behavior you're adding is a whole new vendor, use this checklist; if it's an
> optional, deletable variation on an existing runtime, it's an extension.

---

## 0. Before you start: read these

- `docs/SESSION_STATE_MACHINE.md` — session statuses and transitions.
- `docs/OPEN_TRANSCRIPTS.md` — the canonical transcript schema every runtime normalizes to.
- `docs/TRANSCRIPT_HOOKS.md` — transcript polling/broadcast pipeline.
- `docs/CODEX_AUTH.md` — the Codex auth implementation, the single richest source of
  "things that are different per runtime."
- `docs/OAUTH_ARCHITECTURE.md` — OAuth/account-pool architecture.
- `docs/MCP_CONFIGURATION.md` — how MCP servers are configured and written.

Grep the whole app for the existing runtime keys before you start — `"codex"` and
`"claude_code"` — to see every site that branches on runtime. That grep **is** the
real checklist; this doc is its annotated form.

```bash
grep -rn '"codex"\|"claude_code"\|:codex\|:claude_code' app/ config/ | grep -v test
```

---

## 1. Runtime registration & the Bundle

**Files:** `app/services/runtime_registry.rb`

- [ ] Add a `<RUNTIME>_BUNDLE` constant with every slot filled (or explicitly `nil`
  with a comment for slots that legitimately don't apply yet).
- [ ] Add it to `BUNDLES` keyed by the runtime identifier string.
- [ ] Add a human-readable entry to `LABELS` (falls back to the raw key if missing,
  but always add one).

The `Bundle` struct slots (all must be considered):

```
runtime, air_adapter_name, cli_adapter_class, retry_strategy_class,
transcript_source_class, transcript_normalizer_class, mcp_status_detector_class,
prompt_contribution_class, config_preparer_class, config_post_processor_class,
auth_provider_class, mcp_credential_writer_class
```

> **Note:** `auth_provider_class` and `prompt_contribution_class` slots exist on the
> struct but the actual resolution for those two currently goes through
> `RuntimeAuthProvider.for(runtime)` and `RuntimePromptContribution.for(runtime)`
> (case statements), **not** the Bundle slot. When you add a runtime you must update
> **both** the Bundle and those `.for` case statements. This dual-registration is a
> footgun — see §9 and §6.

**Ways Codex bit us:** registering the Bundle made Codex appear in the new-session
dropdown before several role classes existed, so early sessions selected Codex and
immediately failed at the first unimplemented seam. Land the role classes first (or
behind the registration) so a selectable runtime is always a working runtime.

---

## 2. Model catalog

**Files:** `app/services/model_catalog.rb`

- [ ] Add a `MODELS["<runtime>"]` array of `{ id:, label:, default:, requires_oauth: }`.
- [ ] Flag exactly one model `default: true`.
- [ ] Flag any model that **cannot** run on an API key (only via interactive OAuth)
  with `requires_oauth: true`.

`ModelCatalog` is consulted by the new-session form, the detail-page model editor, and
the REST API to populate options and validate selections. It resolves its own keys, so
a runtime's catalog is reachable even before `RuntimeRegistry` registers the bundle.

**Ways Codex bit us:**
- `gpt-5.5` is **OAuth-only** (ChatGPT login). Selecting it on an API-key-only account
  silently failed. The `requires_oauth` flag + UI warning exist because of this.
- An explicit `config.model` passed at spawn time was being overridden by the root
  default; fixed so explicit model selection always wins (#3967). When you add a
  runtime, verify the resolution precedence (§14) end-to-end with a non-default model.
- Don't hard-delete retired models — mark them `(deprecated)` in the label so sessions
  pinned to them keep validating.

---

## 3. CLI adapter — command building, resume, spawn

**Files:** `app/services/runtime_cli_adapter.rb` (the contract / mixin),
`app/services/<runtime>_runtime_adapter.rb` (your impl). Reference:
`claude_cli_adapter.rb`, `codex_runtime_adapter.rb`.

Implement the `RuntimeCliAdapter` contract:

- [ ] `execute(prompt:, session_id:, working_dir:, mcp_config_path:, images:, append_system_prompt:, model:, auto_compact_window:)` → `{ pid:, stderr_log_path: }`
- [ ] `resume(session_id:, working_dir:, prompt:, images:, mcp_config_path:, append_system_prompt:, model:, auto_compact_window:)` → `{ pid:, stderr_log_path: }`
- [ ] `binary_name` → the CLI binary string.
- [ ] `command_summary(...)` → human-readable, operator-facing summary for session logs.
- [ ] `retry_strategy(...)` → returns this runtime's exit classifier (see §4).

**Keep the kwarg signatures identical across runtimes.** `ProcessLifecycleManager` and
the retry services pass the *same* kwargs to whichever adapter is selected. If your
runtime has no analog for a kwarg (e.g. `auto_compact_window`), **accept it and ignore
it** — do not drop it from the signature.

**Spawn discipline (copy from the existing adapters):**
- [ ] Redirect stderr to a `<runtime>_stderr.log` in the working dir for the monitoring
  loop to tail. **Do not hardcode `claude_stderr.log`** anywhere shared (see §16).
- [ ] `pgroup: true` so the whole process tree can be terminated.
- [ ] Detach stdin/stdout (`in: NULL`, `out: NULL`) — the transcript pipeline reads the
  agent's own transcript file, not stdout.
- [ ] Clear inherited env vars and load the session's `.env`.

**Ways Codex bit us (this is the biggest pit):**
- **Sandbox incompatibility (#3884):** Codex's `--full-auto` selects a `workspace-write`
  sandbox enforced via **bubblewrap (bwrap)**. AO runs every session inside an
  already-isolated container where unprivileged user namespaces are disallowed, so
  bwrap aborts ("No permissions to create a new namespace") and **every** model-issued
  shell command fails before executing. We must use
  `--dangerously-bypass-approvals-and-sandbox` (the "externally sandboxed" mode), not
  `--full-auto`. **Any new runtime with its own sandbox needs the same treatment** —
  find the flag that says "trust the outer sandbox."
- **`--cd` rejected on resume (#3979/#3884):** `codex exec` accepts `--cd <dir>` but
  `codex exec resume` **rejects it** ("unexpected argument '--cd' found") and aborts the
  turn. Resume instead relies on the spawned process's `chdir`. Test resume separately
  from execute — they are different code paths with different accepted flags.
- **No `--session-id`:** Codex generates its **own** session UUID (the rollout filename
  UUID). There is no flag to set it. The UUID is captured *downstream* from the
  transcript and fed back into `resume`. If your runtime owns its session id, build the
  same capture path; don't assume you can pass AO's session id.
- **Resume backend can change underneath you (LIVE bug, session 7278):** Codex moved
  from rollout JSONL files to a **SQLite thread store** (`state_*.sqlite`); `codex exec
  resume <uuid>` started failing with "no rollout found." Resume that depends on a
  vendor's on-disk session store is fragile — pin the CLI version (§12) and re-validate
  resume on every CLI bump.
- **System prompt has no flag:** Codex has no `--append-system-prompt`. It reads
  `AGENTS.md` from the working dir, so the adapter writes that file before spawn (§6).

---

## 4. Exit / error classification & retry

**Files:** `app/services/<runtime>_retry_strategy.rb`. Reference:
`claude_retry_strategy.rb`, `codex_retry_strategy.rb`. Consumed by
`ProcessLifecycleManager`.

The retry strategy classifies a finished process into: **succeeded**, **transient
(retry)**, **quota/rate-limited (rotate account — see §10)**, or **fatal**.

- [ ] Map the runtime's exit codes + stderr signatures to those categories.
- [ ] Distinguish quota/rate-limit exits so quota rotation fires (§10). The
  usage-limit vs transient-rate-limit split hinges on a runtime-specific
  **error string** that the vendor changes without notice — a too-narrow match
  silently sends capped accounts down the retry path instead of rotating. For
  Claude the canonical pattern, known message formats, and the moving-target
  history live in `docs/CLAUDE_CODE_OAUTH_ASSUMPTIONS.md` → "Usage-limit
  messages"; mirror that tracking for your runtime.
- [ ] Distinguish transient (network/5xx) exits so they retry with backoff rather than
  surfacing as a hard failure (see the repo's Logging Philosophy: retry transient
  errors, only `.warn`/`.error` after retries are exhausted).

**Ways Codex bit us (LIVE bug, session 7278 — read carefully):**
Codex can finish with **exit code 0** while having actually **errored** — it writes an
error to stderr (e.g. `Error: ... code -32600`) but exits 0. AO classified that as
"completed turn successfully," so the session silently landed in `needs_input` with an
**empty transcript** and no indication anything went wrong. **Exit code is not a
reliable success signal.** Your classifier must also inspect stderr and/or the
transcript for error markers, and a "successful" turn that produced **no assistant
output** should be treated as suspicious, not success. This is the single most
important classification gotcha — budget time to get it right and test the
errored-but-exit-0 case explicitly.

---

## 5. Transcript source + normalizer → OpenTranscripts

**Files:** `app/services/transcript_source.rb` (contract),
`app/services/<runtime>_transcript_source.rb`, `app/services/transcript_normalizer.rb`
(contract), `app/services/<runtime>_transcript_normalizer.rb`,
`app/services/transcript_runtime.rb` (resolver). Read `docs/OPEN_TRANSCRIPTS.md` first.

- [ ] **Source:** locate and read the runtime's transcript file(s) from disk. Return
  raw events. Handle the file possibly not existing yet (in-progress sessions).
- [ ] **Normalizer:** convert raw events into the canonical **OpenTranscripts v0.1**
  schema so the single shared renderer can display any runtime identically.
- [ ] Capture the runtime's own session id here if it owns one (§3).
- [ ] **Implement `mints_own_session_id?` on the normalizer** (abstract on
  `TranscriptNormalizer`; forgetting it raises `NotImplementedError` on the first
  poll). Return `true` **only** if the runtime generates its own session/thread id
  that AO must learn from the transcript (Codex). Return `false` if the runtime
  honors the AO-supplied id (Claude). This trait gates `capture_runtime_session_id!`:
  returning `true` for a runtime that actually honors AO's id will **corrupt forked
  sessions** — a fork's transcript is copied from its source, so its early lines
  carry the source's id, which capture would write over the fork's own id, colliding
  with the unique `session_id` index (`RecordNotUnique`) and failing every poll until
  the session is wrongly marked `transcript_unavailable`.

**Ways Codex bit us:**
- **Compression:** Codex rollouts can be `.zst`-compressed (`rollout-*-<uuid>.jsonl.zst`).
  The source must transparently decompress. A new runtime may gzip/compress too — don't
  assume plaintext.
- **Empty / short-transcript regressions:** several bugs where a just-started or
  one-line transcript broke parsing or rendered blank. Test the empty and single-event
  cases.
- **The transcript file location/format is a moving target (LIVE bug, session 7278):**
  Codex migrated from per-day `rollout-*.jsonl` files to a SQLite thread store. A
  transcript source coupled to a specific on-disk layout breaks on CLI upgrades. Re-run
  a transcript-rendering E2E on every CLI bump (§12), and keep the source isolated so
  the format change is a one-file fix.

---

## 6. System-prompt contribution & project-instructions file

**Files:** `app/services/runtime_prompt_contribution.rb` (base + `.for` resolver),
`app/services/<runtime>_runtime_prompt_contribution.rb`,
`app/services/orchestrator_system_prompt_builder.rb`,
`app/services/agents_md_writer.rb` (Codex's file writer). Reference:
`claude_runtime_prompt_contribution.rb`, `codex_runtime_prompt_contribution.rb`.

The orchestrator system prompt is mostly runtime-agnostic, but a few slices differ.
Override on your contribution:

- [ ] `delivered_via_file?` — `false` if the CLI takes a prompt flag (Claude:
  `--append-system-prompt`); `true` if AO must write it to a file (Codex: `AGENTS.md`).
- [ ] `system_prompt_filename` — the file written when `delivered_via_file?` is true.
- [ ] `project_instructions_filename` — `CLAUDE.md` vs `AGENTS.md`; interpolated into
  shared prompt sections that reference "follow any CLAUDE.md instructions."
- [ ] `guidelines_bullets` / `clarifying_questions_suffix` — runtime-specific tool
  guidance. **Only include guidance for tools the runtime actually has.**
- [ ] `dynamic_resources_section_override` — runtime-specific skill/MCP injection paths
  (`.claude/skills/` + `.mcp.json` vs `.agents/skills/` + `.codex/config.toml`).
- [ ] **Register in `RuntimePromptContribution.for`** (the case statement), not just the
  Bundle slot.

**Ways Codex bit us:**
- Claude's prompt told agents "never use `EnterPlanMode` / `AskUserQuestion` / `/schedule`."
  Codex has none of those tools, so repeating that guidance was noise/confusing. Tool
  guidance must be gated per-runtime — that is the entire reason this seam exists.
- The project-instructions filename is referenced in *shared* prompt text. If you don't
  set `project_instructions_filename`, a Codex agent gets told to read `CLAUDE.md` which
  it doesn't load (it reads `AGENTS.md`).

---

## 7. MCP config post-processing (file format)

**Files:** `app/services/runtime_config_post_processor.rb` (contract),
`app/services/<runtime>_*_post_processor.rb`. Reference:
`claude_mcp_config_post_processor.rb`, `codex_config_toml_post_processor.rb`.

AIR (§13) writes a base MCP config; AO post-processes it (server injection, env
retargeting, secret/npx rewrites) in the runtime's **native format**.

- [ ] Implement the post-processor for the runtime's config format:
  - Claude: `.mcp.json` (JSON).
  - Codex: `.codex/config.toml` (TOML).
- [ ] Wire it into the Bundle `config_post_processor_class` slot.

**Ways Codex bit us:** the format difference (JSON vs TOML) means the post-processor is
not shareable. A runtime with yet another format (YAML? CLI flags?) needs its own
processor. Don't try to reuse another runtime's.

---

## 8. MCP credential writing

**Files:** `app/services/runtime_mcp_credential_writer.rb` (contract),
`app/services/<runtime>_mcp_credential_writer.rb`. Reference:
`claude_mcp_credential_writer.rb`, `codex_mcp_credential_writer.rb`.

Where vendor MCP credentials must be written so the CLI can read them.

- [ ] Implement the writer for the runtime's credential location.
- [ ] Wire it into the Bundle `mcp_credential_writer_class` slot.

**Ways Codex bit us:** Codex stores credentials in `~/.codex/.credentials.json` (and on
macOS also touches the Keychain). The location and format are runtime-specific. Confirm
the CLI actually reads from where you write.

---

## 9. MCP status detection

**Files:** `app/services/mcp_status_persisting.rb` (shared persistence),
`app/services/mcp_log_poller_service.rb` (Claude — reads per-server log files),
`app/services/<runtime>_mcp_status_detector.rb` (yours). Reference:
`codex_mcp_status_detector.rb`.

This is what turns the per-server MCP status pills green/gray in the UI.

- [ ] Implement a detector that determines which MCP servers successfully connected.
- [ ] Wire it into the Bundle `mcp_status_detector_class` slot.

**Ways Codex bit us:**
- Claude writes **per-server MCP log files**; Codex writes **none**. The Codex detector
  derives status from rollout `mcp__<server>__<tool>` function-call events instead
  (#3994/#4037). **Don't assume per-server logs exist.**
- A server that **connected but was never called** left no evidence in the rollout, so
  its pill stayed gray forever (#3991). Fix: enable rmcp client logging
  (`RUST_LOG=warn,rmcp=info`) so Codex emits a "Service initialized as client" line per
  connected server on stderr, which the detector counts. A new runtime needs *some*
  signal for "connected but idle" — find it before shipping or every quiet server looks
  broken.

---

## 10. Auth provider, account pool, quota & rotation

**Files:** `app/services/runtime_auth_provider.rb` (contract + `.for`/`.registered`),
`app/services/<runtime>_auth_provider.rb`, `app/services/<runtime>_login_driver.rb`,
`app/jobs/runtime_login_job.rb`, `app/jobs/refresh_runtime_auth_tokens_job.rb`,
`app/jobs/quota_reset_checker_job.rb`, `app/services/process_lifecycle_manager.rb`
(quota rotation). Models: `app/models/claude_account.rb` (shared, `runtime`
discriminator column), `account_rotation_event.rb`, `claude_account_quota_snapshot.rb`,
`runtime_login_attempt.rb`. **Read `docs/CODEX_AUTH.md` and `docs/OAUTH_ARCHITECTURE.md`.**

If the runtime authenticates without an API key (interactive login + token refresh),
implement the full `RuntimeAuthProvider` contract:

- [ ] `runtime`, `accounts`, `current_account`, `select_account_for(session)`
- [ ] `refresh!(account)` → `Result` with `:needs_reauth` (permanent) vs `:transient`
- [ ] `inject_for_session!(session, working_directory)` — write the active account's
  credentials to the runtime's canonical filesystem location **before each spawn**.
- [ ] `activate!(account)` — write credentials + mark current (manual switch / safe-delete).
- [ ] `rotation_interval` — token-refresh sweep cadence.
- [ ] `rotate_for_quota!(triggered_by:)` — rotate to the next account on quota hit.
- [ ] Dispatcher hooks as needed: `reconcile_filesystem_identity!`,
  `sync_current_account_tokens!`, `needs_reauth_recovery_candidates`,
  `recover_needs_reauth`.
- [ ] **Register in `RuntimeAuthProvider.for` and add the key to `RUNTIMES`** so
  `RefreshRuntimeAuthTokensJob` fans out to it.
- [ ] Add the runtime to the **shared `ClaudeAccount` model's `RUNTIMES`** and handle
  its `oauth_config` shape.
- [ ] Implement the **login driver** (device-auth / OAuth poll) and wire the
  Quotas-page login flow (§15).

**Ways Codex bit us (this was the largest source of pain by far):**
- **One-time-use refresh tokens:** Codex's ChatGPT OAuth refresh tokens are
  **single-use** — each refresh returns a new refresh token and invalidates the old one.
  Concurrent or duplicated refreshes invalidate each other and brick the account. The
  refresh path must be serialized and must persist the rotated token atomically.
- **Staging/prod cron parity (caused a multi-hour outage):** the token-refresh cron
  must run identically on staging and prod. A drift where staging didn't refresh Codex
  (and bigquery) tokens led to 401s and an outage. When you add a runtime, verify the
  refresh cron is wired in **both** environments.
- **Auth header shape:** Bearer-token vs `x-api-key` differs per vendor; using the wrong
  one fails auth silently. Confirm the exact header the CLI/endpoint expects.
- **PTY login UI:** the interactive login is a device-auth/PTY flow surfaced through the
  Quotas page; getting the poll/code-submit lifecycle right took several passes (#4036).
- **Credential location is per-runtime:** `CODEX_HOME=/home/rails/.codex`, `auth.json`,
  etc. `inject_for_session!` must target exactly where the CLI reads.

If the runtime uses a **plain API key** instead, this whole section collapses to setting
an env var — but be explicit about which model, since some models are OAuth-only (§2).

---

## 11. Session model, validation & resolution

**Files:** `app/models/session.rb`, `app/services/agent_roots_config.rb`,
`app/models/app_setting.rb`.

- [ ] `agent_runtime` is validated against `RuntimeRegistry.registered_runtimes`
  (already dynamic — registering the Bundle makes the value valid).
- [ ] `Session#runtime` resolves the Bundle via `RuntimeRegistry.for(agent_runtime)`.
- [ ] `create_from_agent_root!` resolves the runtime via
  `RuntimeRegistry.resolve_key(agent_runtime.presence || agent_root.default_runtime)`.
- [ ] `AgentRootsConfig.available_runtimes` returns `RuntimeRegistry.registered_runtimes`
  so **any** root can launch under **any** registered runtime.
- [ ] Confirm `Session#available_models` uses `ModelCatalog.model_ids_for(agent_runtime)`.

**Resolution precedence (verify end-to-end — §14):**
form/API param → `roots.json` explicit value → `AppSetting` global base → hardcoded default.

---

## 12. CLI install & version pinning

**Files:** `agents/agent-orchestrator/Dockerfile.base`,
`app/services/cli_status_service.rb` (`CLI_TOOLS` hash), and the upgrade skill
(`ao-upgrade-codex` is the model to copy).

- [ ] Install the CLI in `Dockerfile.base`, **version-pinned** (e.g.
  `npm install -g @openai/codex@0.135.0`), with install retries.
- [ ] Pre-create any home/config dir the CLI needs with correct ownership (Codex:
  `~/.codex`, `ENV CODEX_HOME="/home/rails/.codex"`).
- [ ] Add the tool to `CLI_TOOLS` in `cli_status_service.rb` with `check_installed`,
  `check_auth`, `check_version`, and login instructions, so the CLIs status page and
  REST endpoint report it.
- [ ] Create an `ao-upgrade-<runtime>` skill (copy `ao-upgrade-codex`) so version bumps
  follow a documented procedure.

**Ways Codex bit us:** unpinned CLIs upgrade silently and break resume / transcript
parsing / sandbox flags (see §3, §5). **Always pin**, and treat a version bump as a
change requiring a full E2E re-validation (execute + resume + transcript render + MCP
status), not a no-op dependency bump.

---

## 13. AIR adapter

**Files:** `app/services/air_prepare_service.rb`, `Dockerfile.base` (AIR adapter
package install). Reference: `docs` and the `ao-upgrade-air` skill.

AO prepares each clone with `air prepare <adapter>`. The adapter id comes from the
Bundle's `air_adapter_name`.

- [ ] Set `air_adapter_name` on the Bundle (Claude → `"claude"`, Codex → `"codex"`).
- [ ] Ensure the matching `@pulsemcp/air-adapter-<runtime>@<AIR_CLI_VERSION>` package is
  installed in `Dockerfile.base` and pinned to `AirPrepareService::AIR_CLI_VERSION`.
- [ ] If AIR has no adapter for your runtime yet, that adapter must be built upstream
  first — AO can't prepare a clone for a runtime AIR doesn't understand.

**Ways Codex bit us:** AIR adapter version must match `AIR_CLI_VERSION`; a broken npm
publish of the pinned version fails prepare for the whole session. Bump the adapter and
the CLI version together (`ao-upgrade-air`).

---

## 14. Runtime/model selection UI

**Files:** `app/controllers/sessions_controller.rb`,
`app/controllers/api/v1/sessions_controller.rb`,
`app/javascript/controllers/runtime_select_controller.js`,
`app/javascript/controllers/model_select_controller.js`,
`app/javascript/controllers/agent_root_select_controller.js`, plus the new-session and
detail-page views.

- [ ] Runtime dropdown is populated from `AgentRootsConfig.available_runtimes` (dynamic —
  your runtime appears automatically once registered).
- [ ] Model dropdown updates per selected runtime from `ModelCatalog` (Stimulus).
- [ ] OAuth-only model warning fires when an API-key-only account picks a
  `requires_oauth` model.
- [ ] Verify the **resolution precedence** with a real session: explicit form/API value
  wins over `roots.json`, which wins over `AppSetting` global base, which wins over the
  hardcoded default. Confirm an invalid runtime/model pairing is rejected.

**Ways Codex bit us:** explicit model selection was being clobbered by the root default
(#3967). The precedence is subtle; test every level, not just the happy path.

---

## 15. Quotas page & login flow

**Files:** `app/controllers/quotas_controller.rb`, `config/routes.rb` (the
`quotas/...login...` routes), the Quotas views, `app/jobs/runtime_login_job.rb`.

- [ ] The Quotas page is per-runtime (`?runtime=<runtime>`). Confirm your runtime's
  account pool, quota snapshots, add/delete/switch, and the **Authenticate** (login)
  button all work for the new runtime.
- [ ] Wire the device-auth/OAuth login lifecycle (start → poll status → submit code →
  cancel) through the login driver (§10).

---

## 16. Logging & observability

**Files:** anywhere shared code emits runtime-flavored strings. Grep for hardcoded
`"Claude"` / `claude_stderr.log` / `"Claude CLI"`.

- [ ] No hardcoded "Claude" strings in shared/monitoring code paths — derive labels from
  `RuntimeRegistry.label_for(runtime)` and the adapter's `binary_name`/stderr path.
- [ ] Follow the repo Logging Philosophy: transient errors retry and log `.info` on
  intermediate attempts; only `.warn`/`.error` on final failure.

**Ways Codex bit us:** shared monitoring logged "Claude CLI ..." for Codex sessions,
making logs misleading during incident triage (#3990). Operators reading logs during an
outage need the right runtime name.

---

## 17. REST API & MCP tool discoverability

**Files:** `app/controllers/api/v1/configs_controller.rb` and the sessions API; **both**
doc surfaces `docs/REST_API.md` and `app/views/api_docs/show.html.erb`.

- [ ] The configs/runtimes/models surfaced via REST include the new runtime.
- [ ] **Update both REST API doc surfaces in the same PR** (see the agent-orchestrator
  `CLAUDE.md` rule — there is no automated check enforcing parity).
- [ ] If AO MCP tools expose runtime/model choices, confirm the new runtime is
  selectable there too.

---

## 18. Database migrations

- [ ] If the runtime needs new columns (e.g. an account-pool field, a runtime-specific
  config), create the migration **and update `db/schema.rb`** (CI builds the test DB
  from `schema.rb`, not by running migrations — schema drift fails CI). See the root
  `CLAUDE.md` "Database Schema and Migrations" section.
- [ ] Prefer reusing the shared `ClaudeAccount` model (with its `runtime` discriminator)
  over a new accounts table.

---

## 19. Tests

- [ ] Unit tests for each new role class (adapter, retry strategy, transcript
  source/normalizer, status detector, auth provider, post-processors, credential writer).
- [ ] **Contract / production-parity tests** (`test/contracts/`) — never reference
  test-only mocks from production code; use `ENV["VAR"] == "true"` for booleans.
- [ ] **SupervisorCoverageTest:** any **new model** needs an Administrate dashboard, a
  `Supervisor::` controller, and a `supervisor` route, or this contract test fails.
- [ ] Explicitly test the **gotcha cases** that bit us: errored-but-exit-0 (§4), resume
  flag differences (§3), empty/compressed transcript (§5), connected-but-idle MCP server
  (§9), OAuth-only model on API-key account (§2/§14).
- [ ] Run targeted tests locally; delegate the full suite to CI.

---

## Final pre-ship checklist

Before calling a new runtime done, run a real session end-to-end and confirm **each**:

- [ ] New session under the new runtime reaches `running` and produces a transcript.
- [ ] Transcript renders in the shared renderer (OpenTranscripts).
- [ ] Follow-up / **resume** works (separate code path from execute!).
- [ ] MCP servers connect and their status pills go green (including a connected-but-idle one).
- [ ] Auth: account selected, credentials injected, token refresh works on **staging and
  prod** crons; quota rotation fires when a quota is hit.
- [ ] An **errored** turn is reported as failed, not as a silent empty success.
- [ ] CLI version is pinned in `Dockerfile.base`; AIR adapter version matches.
- [ ] REST API docs (both surfaces) updated; CLIs status page shows the new tool.
- [ ] No hardcoded "Claude" strings leaked into the new runtime's logs.

If every box above is checked, you have hit every integration point that Codex taught us
about. If you discover a **new** seam the next runtime trips over, add it to this doc —
that's the whole point.
