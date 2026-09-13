---
title: Adding an agent harness
description: The fourteen-slot runtime bundle, every interface a new harness must implement, and the three registries that don't go through the bundle.
sidebar:
  order: 2
---

A **runtime** (agent harness) is a `RuntimeRegistry::Bundle` — a struct with fourteen slots, one for
each seam where driving a vendor CLI differs. The bundle is plain data — a struct of class references
Zimmer looks up at runtime.

```ruby
Bundle = Struct.new(
  :runtime, :air_adapter_name, :cli_adapter_class, :retry_strategy_class,
  :transcript_source_class, :transcript_normalizer_class, :mcp_status_detector_class,
  :prompt_contribution_class, :config_preparer_class, :config_post_processor_class,
  :artifact_bridge_class, :auth_provider_class, :mcp_credential_writer_class,
  :usage_ingestor_class,
  keyword_init: true
)
```

Core code never says "Claude." It asks `RuntimeRegistry.for(runtime)`.

## What ships

| Slot | `claude_code` | `codex` | `pi` |
| --- | --- | --- | --- |
| `air_adapter_name` | `"claude"` | `"codex"` | `"pi"` |
| `cli_adapter_class` | `ClaudeCliAdapter` | `CodexRuntimeAdapter` | `PiRuntimeAdapter` |
| `retry_strategy_class` | `ClaudeRetryStrategy` | `CodexRetryStrategy` | `PiRetryStrategy` |
| `transcript_source_class` | `ClaudeTranscriptSource` | `CodexTranscriptSource` | `PiTranscriptSource` |
| `transcript_normalizer_class` | `ClaudeTranscriptNormalizer` | `CodexTranscriptNormalizer` | `PiTranscriptNormalizer` |
| `mcp_status_detector_class` | `McpLogPollerService` | `CodexMcpStatusDetector` | `PiMcpStatusDetector` |
| `config_post_processor_class` | `ClaudeMcpConfigPostProcessor` | `CodexConfigTomlPostProcessor` | `PiMcpConfigPostProcessor` |
| `mcp_credential_writer_class` | `ClaudeMcpCredentialWriter` | `CodexMcpCredentialWriter` | `PiMcpCredentialWriter` |
| `artifact_bridge_class` | `NullRuntimeArtifactBridge` | `NullRuntimeArtifactBridge` | `PiAirBridge` |
| `usage_ingestor_class` | `TokenUsageIngestionService` | `CodexTokenUsageIngestionService` | `PiTokenUsageIngestionService` |
| `prompt_contribution_class` | `ClaudeRuntimePromptContribution` | `nil` | `PiRuntimePromptContribution` |
| `auth_provider_class` | `nil` | `nil` | `nil` |
| `config_preparer_class` | `nil` | `nil` | `nil` |

Claude and Codex share a shape: their AIR adapter writes the config, and the
runtime supplies MCP, hooks and plugins itself. Pi does neither, which is what
makes it the interesting third column — see
[Pi is the runtime that supplies nothing](#pi-is-the-runtime-that-supplies-nothing).

:::note[Three slots are dead weight]
`auth_provider_class` is `nil` for all three runtimes even though all three classes exist — auth
resolves through `RuntimeAuthProvider.for` instead. `prompt_contribution_class` is `nil` for Codex even though
`CodexRuntimePromptContribution` exists; it resolves through `RuntimePromptContribution.for`.
`config_preparer_class` is `nil` everywhere and nothing reads it. Pi fills its
`prompt_contribution_class` slot anyway — leaving it `nil` while the class exists
is exactly the inconsistency being tracked — but it still resolves through
`RuntimePromptContribution.for` like the others.
Tracked in [#97](https://github.com/tadasant/zimmer/issues/97).
:::

`artifact_bridge_class` is the one slot where Pi holds a real class and the other
two hold a null object: it writes the AIR hooks and plugins config Pi's extensions
read, which Claude's and Codex's AIR adapters already handle for them. See
[Pi is the runtime that supplies nothing](#pi-is-the-runtime-that-supplies-nothing).

`usage_ingestor_class` sweeps the runtime's transcripts into the token-spend ledger
([costs](/operate/costs/#how-usage-gets-in)). The contract is
`.new(modified_since:)` and `#call`, returning something that responds to `#session_rows`
and `#to_s`; `TokenUsageIngestionJob` runs every non-`nil` one on
its cron and isolates a failure to the ingestor that raised it. It is a slot rather than a
conditional because *where a runtime records what it spent* has no common answer, and all three
runtimes answer it differently: Claude Code writes a host-global `~/.claude/projects` tree keyed
on the API's own `requestId`; Pi writes into the clone, and is therefore read back out of
`sessions.transcript` because the clone is reaped; Codex writes a date-partitioned rollout tree
that Zstandard-compresses itself when a session finishes, and reports tokens with no per-call
identifier and no model, so both the key and the model attribution are constructed as the rollout
is streamed. `nil` remains legal in this slot and means "this runtime's spend is not ingested yet";
no registered runtime is `nil` today.

Two `pi` slots are worth reading in full — one because it is emphatically *not*
`nil`, the other because it is `nil` for a reason of its own rather than by that
convention:

- **`mcp_status_detector_class`** — Pi writes no per-server MCP log files, so
  Claude's log poller has nothing to read. It held `NullMcpStatusDetector` on the
  further argument that `pi-mcp-adapter` "routes every server through one `mcp`
  proxy tool, so a transcript shows `mcp` being called and never names the server
  behind it". **That was true of an older adapter and is not true of the pinned
  one.** 2.32.1 registers a namespace-proxy tool *per server*, `mcp__<server>`
  (`namespaceProxyName`), and the bare `mcp` proxy takes the server verbatim in
  its `connect` argument. `PiMcpStatusDetector` mines both. Until it did, every
  Pi session's servers read `pending` forever while they were connected and
  answering — which is how a working Pi session got reported as one whose MCP was
  dead. **Re-derive a claim like this against the pinned version rather than
  inheriting it**; the slot must still never be `nil`, for the reason below.
  `TranscriptPollerService#initialize` calls `.new` on this slot with no nil
  check, so a `nil` here raises `NoMethodError` on every poll of every session on
  the runtime, before any MCP-specific guard can run. That is the general rule:
  **a slot some caller dereferences must never be `nil`** — a runtime with
  nothing real to put there supplies a null object.
  `test/contracts/runtime_bundle_slot_contract_test.rb` enforces this for every
  registered runtime and every unconditionally-dereferenced slot.

  **Filling the slot is necessary and not sufficient.** A detector also has to
  *work*, and the null object's whole job is the inherited half of the interface:
  `TranscriptPollerService#poll_mcp_logs` calls `update_session_mcp_status` after
  every `poll`, and for Pi that call is the only thing that seeds the `pending`
  placeholders keeping a configured server visible in `mcp_servers_status`
  instead of reading as "not configured". `NullMcpStatusDetector` shipped
  including `McpStatusPersisting` but not `DatabaseRetry`, so that inherited call
  raised `NoMethodError` on every poll of the first Pi session to run in
  production — a filled slot, a successful construction, and a broken runtime.
  `McpStatusPersisting` now includes `DatabaseRetry` itself, so no includer can
  repeat it, and the contract test polls *and* persists for every runtime rather
  than only constructing.
- **`mcp_credential_writer_class`** — Pi keeps MCP OAuth tokens inside the
  `pi-mcp-adapter` extension's own state, and Zimmer held this slot `nil` on the
  reading that it therefore could not deliver one. It can: the adapter documents
  a plaintext entry it imports from `<oauth dir>/sha256-<server>/tokens.json`, and
  `PiMcpCredentialWriter` stages exactly that, so **no registered runtime has a
  `nil` writer today**. The `nil` case remains part of the seam, and the slot
  *may* be `nil` because every caller is guarded:
  `RuntimeRegistry.mcp_credential_writer_classes` compacts the list (its callers
  instantiate every class it returns — the credential-retire path, i.e. while a
  credential is already failing, and `RefreshMcpOauthTokensJob`, which has no
  session and so reads *every* runtime's store before it refreshes), and
  `McpOauthCredentialInjector` asks `#credential_store?` first. That second guard is load-bearing rather than
  defensive: `McpOauthController#reinject_and_resume` calls injection and the
  resume service inside one `rescue`, so a raise from injection would skip the
  resume and leave a session parked on an OAuth gate permanently un-resumable.

  **"Every caller" is a wider set than the write paths**, and reading it as
  narrowly as "the one that writes the file" is what broke the first Pi session
  with an OAuth-credentialed MCP server attached. The writer also owns the
  credential *key* (`#credential_key_for`), so resolution needs it too: the key
  on each `ResolvedMcpCredential`, and the key `McpOauthRuntimeReconciler` reads
  the on-disk store under. `#check_credentials_status` — the pre-spawn OAuth
  gate, which never writes anything — went through that second one and
  dereferenced the `nil`, so the session died at the gate with `NoMethodError:
  undefined method 'credential_key_for' for nil` before producing a line of
  output. Every path that needs a runtime credential key now short-circuits on
  `#credential_store?`, and the injector's contract tests assert both the gate
  and injection for *every* registered runtime rather than for Claude alone.

## The three registries that bypass the bundle

This is the thing that will catch you. Besides the `Bundle`, there are three separate `.for` case
statements you must also register in:

```ruby
RuntimeAuthProvider.for(runtime)        # + add to RUNTIMES
RuntimePromptContribution.for(runtime)
RuntimeLoginDriver.for(runtime)
```

And a fourth registry that isn't a `.for` at all: `ModelCatalog::MODELS[runtime]`, which resolves its
own keys so a model catalog can exist before a bundle does.

:::caution[`docs/ADDING_AN_AGENT_HARNESS.md` mentioned only two of the three]
It called out `RuntimeAuthProvider.for` and `RuntimePromptContribution.for` and missed
`RuntimeLoginDriver.for`. Miss that one and the UI login flow `NoMethodError`s.
:::

## The interfaces

### `RuntimeCliAdapter` (mixin)

```ruby
execute(prompt:, session_id:, working_dir:, mcp_config_path:, images:,
        append_system_prompt:, model:, auto_compact_window:)  # → {pid:, stderr_log_path:}
resume(session_id:, working_dir:, prompt:, images:, mcp_config_path:,
       append_system_prompt:, model:, auto_compact_window:)   # → same shape
binary_name                                                    # → String
command_summary(session_id:, prompt:, mcp_config_path: nil, resume: false)  # must start with binary_name
retry_strategy(session:, file_system:, process_manager:, rate_limit_tracker:, logger:)
disallowed_tools    # default []
runtime_env_vars    # default {}
```

Plus a class-level half, because callers that never spawn still need it:

```ruby
self.stderr_log_filename   # → "<runtime>_stderr.log". REQUIRED — the default raises NotImplementedError
self.spawn_error_class     # → your error class; defaults to RuntimeCliAdapter::SpawnError
self.cli_label             # → "Codex CLI", for operator-facing errors; defaults to the class name
self.stderr_log_path(dir)  # provided: dir + stderr_log_filename, nil for a blank dir
self.spawn_artifact_paths(dir)   # provided: [stderr_log_path(dir)]. Override to add more
self.validate_working_dir!(dir)  # provided: refuses nil/blank, raising spawn_error_class
```

`stderr_log_filename` is what `Session#stderr_log_path` reads, so skipping it doesn't fail
quietly — it raises `NotImplementedError` the first time a session on your runtime is resumed,
interrupted, or terminated. Build your spawn-time path from it too (`self.class.stderr_log_path`),
so the name your process writes and the name every caller reads cannot drift.

`spawn_artifact_paths` is every file your spawned process writes **into the working directory**.
`ForkSessionService` deletes them from the copied clone, because they describe the run that
produced it and not the one about to start. The default covers the stderr log; override and append
to `super` if your runtime writes more. `CodexRuntimeAdapter` does, for its `--json` event log —
that file names the source session's Codex thread, and a fork that kept it would resume someone
else's conversation. The contract test asserts this for every adapter, so a runtime that returns a
relative path or forgets its own stderr log fails the suite rather than leaking state into forks.

`validate_working_dir!` must run at the top of `execute` and `resume`, before anything joins onto
`working_dir`. A nil working directory does reach adapters — that was #183 — and without the guard
it dies inside `Process.spawn` with a message that names no argument.

Enforced by `test/contracts/runtime_cli_adapter_contract_test.rb`, which asserts keyword-set
equality via `instance_method(:execute).parameters`, the stderr-filename shape, and the
working-dir guard's accept/reject behavior. Add your adapter (and a mock) to
`RuntimeCliAdapterContractTest::ADAPTERS`. An adapter provided by an extension lives outside that
list, so call `assert_runtime_cli_adapter_contract` from the extension's own test instead.

Also `include CliSpawnEnv` — don't reimplement env scrubbing — and call its
`apply_extension_env(env_vars, runtime:)` after your own baseline, so enabled Zimmer Extensions'
env contributions reach your runtime the way they reach the other three.

Two optional class hooks default to Claude's answer: `compacts_on_resume?` (false — your runtime
needs a command to compact; answer true if resuming after a context-window failure compacts by
itself) and `cli_label`.

### Retry strategy: the five predicates

```ruby
normal_completion_exit?(status)
context_length_error?(stderr_log_path:)
failed_resume_recovery_needed?(stderr_log_path:)
api_error_for_retry?(working_dir:)
auth_recovery_needed?(working_dir:)
```

All five are declared in `runtime_cli_adapter.rb`'s contract docstring and asserted by
`test/support/runtime_cli_adapter_contract.rb`
(`RuntimeCliAdapterContractAssertions::RETRY_STRATEGY_PREDICATES`). Implement fewer than five and
the contract test fails by name — which is the point: the auth-recovery path is reached only on a
session that is already failing, so a missing predicate used to surface as a production
`NoMethodError` at the worst possible moment (#56).

`auth_recovery_needed?` is the one to notice. It is what routes an exit into
`AuthRecoveryCoordinator` (adopt → rotate → park) rather than into a plain failure, so a runtime
that returns a flat `false` is not "safely defaulting" — it is opting out of credential recovery
entirely. See how Codex answers it under [Codex classifies by the code it records](#codex-classifies-by-the-code-it-records).

### `TranscriptSource`

```ruby
transcript_directory(working_directory:)
per_working_directory_transcript_root                  # default nil = "not sweepable"
resume_transcript_path(session:, working_directory:)   # default nil = "no single-file restore"
locate(session:, working_directory:)
read(path)
parse_events(serialized)
discover_subagent_files(working_directory:, session_id:)
mcp_log_paths(working_directory:)
find_main_transcript(transcript_directory:, session:)
records_turn_errors?                                   # default false
terminal_turn_error(session:, working_directory:)      # default nil
```

`find_main_transcript` is declared on the abstract base class and raises `NotImplementedError`
there, like the rest of the required surface. `TranscriptPollerService` calls it on every poll, so a
source that skipped it used to `NoMethodError` on its first poll instead of failing at the seam
(#56).

`per_working_directory_transcript_root` is the other default-`nil` method, and `nil` there is a
**refusal to be swept**, not a gap. It answers "is there a root under which every child is a
transcript directory attributable to the one working directory that produced it" — which is what
lets `OrphanTranscriptDirectoryCleanupJob` enumerate that root and delete the children whose cwd is
gone. Only Claude Code answers non-`nil` (`~/.claude/projects`). Codex writes every session into one
date-partitioned tree that ignores the cwd, so deleting a child would take other sessions' rollouts
with it; Pi writes inside the clone, so its transcripts already go when the clone does. Override it
only if your runtime's layout genuinely has that one-directory-per-cwd shape — and derive the name
through `transcript_directory`, never by re-implementing the slug. See [The transcript directory
outlives the
clone](/operate/background-jobs/#the-transcript-directory-outlives-the-clone).

`resume_transcript_path` is the one with a meaningful default. It answers "where do I write the
stored transcript so `--resume` reads the whole conversation", and the base class returns `nil` —
"this runtime cannot be restored from a single deterministic path". Every caller that restores a
transcript to disk (`AgentSessionJob`, `UnarchiveSessionService`, `ForkSessionService`) skips the
write on `nil` and treats that as success, so a runtime that does not override it is left alone
rather than handed a file it will never read. See
[Writing a transcript back to disk](/sessions/transcripts/#writing-a-transcript-back-to-disk).

For Claude Code it delegates to `TranscriptFileLocator`, which prefers
`<session_id>.jsonl`. Before the runtime has minted that id there is no id to match on, so it falls
back to the most recently modified non-`agent-*.jsonl` file **that was written after the session
started** — the mtime floor is what stops a working directory still holding an earlier session's
transcript from handing this session someone else's conversation (#57). If your runtime needs a
fallback of its own, scope it the same way; returning `nil` means "not written yet", which callers
already treat as a waiting state.

### `TranscriptNormalizer`

```ruby
normalize(raw_event, session:, transcript_index:)   # → [OpenTranscripts events]
extract_session_id(raw_event)
mints_own_session_id?                               # Codex: true. Claude: false.
extract_subagent_links(raw_event)
extract_subagent_spawns(raw_event)
conversation_record?(raw_event)                     # conversation, or bookkeeping?
```

`mints_own_session_id?` is a correctness landmine. If you return `true` for a runtime whose
session id Zimmer generates, forked sessions collide on the unique `session_id` index.
Tracked in [#96](https://github.com/tadasant/zimmer/issues/96).

`conversation_record?` is the second one. Every recovery path asks
`RuntimeConversationPresence` whether the runtime has written a conversation before it abandons
one, and this method is what that question resolves to. Answer it with a **deny-list** of the
bookkeeping your runtime writes into the same file — Claude Code's `ai-title`, Codex's
`session_meta` — so a record type you have not met counts as conversation. Get the polarity
backwards and a session's real history is thrown away; leave it unimplemented and it raises
`NotImplementedError` out of a recovery path. See
[A transcript with no conversation in it](/sessions/spawning/#a-transcript-with-no-conversation-in-it-wedges-a-session-id).

### The rest

- **`RuntimePromptContribution`** — `guidelines_bullets`, `clarifying_questions_suffix`,
  `project_instructions_filename` (`CLAUDE.md` vs `AGENTS.md`), `delivered_via_file?`,
  `system_prompt_filename`.
- **`RuntimeConfigPostProcessor`** — a template-method base. Implement `config_path`, `parse_config`,
  `empty_config`, `servers_map`, `build_server_entry`, `resolve_secrets!`, `serialize_config`.
- **`RuntimeMcpCredentialWriter`** — `write!(working_directory:, credentials:)`,
  `credential_key_for(server_name, server_config)`.
- **`RuntimeAuthProvider`** — `accounts`, `current_account`, `select_account_for`, `refresh!`,
  `inject_for_session!`, `activate!`, `rotation_interval`, and
  `rotate_for_quota!(triggered_by:, reason:)`. The last one is the pool's only move-off-this-account
  seam: both the quota path and `AuthRecoveryCoordinator` go through it, and `reason` is what
  distinguishes their `AccountRotationEvent` rows. A runtime that doesn't pool accounts inherits the
  base class's no-op, which parks its sessions instead of rotating them. `pools_accounts?` (default
  `true`) says which park: a runtime answering `false` has its quota walls parked on
  `ProviderQuotaWallPark`'s timed re-check ladder rather than an auth-outage park that waits on the
  pool.
- **`RuntimeLoginDriver`** — `command`, `env(config_dir)`, `parse_verification(buffer)`,
  `completion_mode` (`:poll` | `:paste`), `capture!(config_dir, account)`, `credentials_ready?`.

## The checklist

1. `RuntimeRegistry` — new `Bundle`, add to `BUNDLES` and `LABELS`.
2. `ModelCatalog::MODELS["<runtime>"]` — exactly one entry with `default: true`.
3. CLI adapter — `include RuntimeCliAdapter` + `CliSpawnEnv`. Identical kwargs.
   Declare `self.stderr_log_filename` (`<runtime>_stderr.log`) and guard `execute`/`resume`
   with `validate_working_dir!`. `pgroup: true`, NULL stdin. If the runtime writes anything
   else into the working directory, add it to `self.spawn_artifact_paths` so forks shed it —
   and if it prints a structured event stream on stdout, capture that rather than sending it
   to NULL (see `CodexEventStream`).
4. Retry strategy — all five predicates.
5. Transcript source + normalizer — including `find_main_transcript`, `mints_own_session_id?`
   and `conversation_record?`.
6. Prompt contribution → register in `RuntimePromptContribution.for`.
7. Config post-processor.
8. MCP credential writer — the whole contract, not just `#write!`. If the runtime refreshes
   MCP OAuth tokens itself (Claude Code and Pi both do), `#read_runtime_credentials` is what
   keeps a rotating provider's credential alive, and `#enumerable_store?` /
   `#runtime_key_for` say how it is addressed. See
   [MCP OAuth](/auth/mcp-oauth/#capturing-the-token-the-runtime-rotates-write-back).
9. MCP status detector.
10. Usage ingestor — how the runtime's spend reaches `session_token_usages`. Leaving it `nil`
    is allowed and means the runtime's cost is not tracked; say so in
    [limitations](/limitations/) rather than leaving it to be discovered from a zero.
11. Auth provider → `RuntimeAuthProvider.for` and `RUNTIMES`. Login driver →
    `RuntimeLoginDriver.for`.
12. `Dockerfile.base` — pin the CLI and the matching `@pulsemcp/air-adapter-<runtime>`. Add to
    `CliStatusService::CLI_TOOLS` — and note the contract on `check_auth`: it is either a Ruby
    callable, or a shell command whose argv names a **real subcommand** of the binary. An agent
    CLI typically takes a bare positional prompt, so an argv that matches no subcommand is billed
    as inference on a two-minute cron
    ([#536](https://github.com/tadasant/zimmer/issues/536)). If the runtime needs vendor extensions to reach MCP/hooks
    (Pi does), pin those too and declare them in a registry the Dockerfile is asserted against —
    see `PiExtensions`.
13. Add the adapter to `RuntimeCliAdapterContractTest::ADAPTERS` and write a mock in `test/support/`.

## Pi is the runtime that supplies nothing

Claude Code and Codex both arrive with an MCP client built in (Claude Code with
hooks and plugins too), so Zimmer's job for them is to write config files into a
shape the runtime already understands. Pi ships a skills mechanism and nothing else. Three consequences are
worth knowing before you read `PiRuntimeAdapter`.

**`air prepare pi` writes no MCP config.** `@pulsemcp/air-adapter-pi` is
deliberately skills-only — it injects `.pi/skills/` and records `mcpServers: []`
and `hooks: []` in its manifest. So `PiMcpConfigPostProcessor` is the only
config post-processor that *writes* the server table rather than adjusting one:
it seeds `.mcp.json` from `ServersConfig` before the shared injection/retarget
pipeline runs. Without that seeding a Pi session would start with none of the
servers it was configured with, and the failure would surface only at the first
tool call.

**MCP, hooks and plugins arrive as Pi extensions.** `PiExtensions` is the
registry, and `PiRuntimeAdapter` passes each entrypoint with `pi -e <path>` from
`/opt/pi-extensions`. `pi-mcp-adapter` reads the same `.mcp.json` Claude Code
does — that file is a cross-vendor convention, not a Claude private format, which
is why the JSON format hooks live in the shared `McpJsonConfigFormat` module.
`@tadasant/pi-hooks` runs AIR hooks and `@tadasant/pi-plugins` resolves AIR
plugins; both are configured by the files `PiAirBridge` generates, described next.
The adapter is also where Pi's MCP startup budget lives — it has no env-var
equivalent of Claude's `MCP_TIMEOUT`, so `PiMcpConfigPostProcessor` writes
`requestTimeoutMs` onto each stdio entry instead. Being per-entry, it can carry a
longer per-server budget a catalog entry declares, which Claude's one
process-wide variable cannot — but not a shorter one, since that key bounds every
request on the connection rather than the startup alone. See [Timeouts and
caching](/air/mcp-servers/#timeouts-and-caching).

**Pi supplies no identity either, and the key is OpenRouter's.** Claude Code and
Codex both pool subscription accounts that Zimmer rotates; Pi resolves a provider
credential per request from the session environment, so `PiAuthProvider` pools
nothing and every one of its methods is a documented no-op. The credential Zimmer
supplies is `OPENROUTER_API_KEY`: every Pi model in `ModelCatalog` is an
`openrouter/*` id, so one key covers the whole list rather than one per vendor.
`openrouter` is a first-class provider in the catalog bundled with the pinned Pi
— no `models.json` custom-provider entry is needed — and the ids carry the vendor
after it (`openrouter/anthropic/claude-opus-4.6`). The direct `anthropic/*` and
`openai/*` ids are kept in the catalog and still work wherever
`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` is set; they are simply not what this
deployment feeds. The key is set on the [Inference page's Pi
tab](/operate/secrets-parameter-store/#a-writer-identity-for-the-pi-tab), and
reaches the process through `PiRuntimeAdapter#apply_provider_key`, which resolves
it from the `${VAR}` chain into the spawn environment — see [How the key reaches
a Pi session](/operate/secrets-parameter-store/#how-the-key-reaches-a-pi-session)
for why that step is Pi's own rather than the session `.env` writer's.

Note when refreshing that list: `pi --list-models` only prints providers whose
credential currently resolves, so run it with `OPENROUTER_API_KEY` set or the
`openrouter` rows are silently absent and the catalog looks much smaller than it
is.

**Loading an extension is not the same as configuring it**, and for hooks and
plugins Zimmer has to do both. `air prepare pi` ignores hook entries outright and
honors a plugin only as composition sugar for its skills, so after prepare there
is nothing on disk carrying the session's hooks. `PiAirBridge` — the `pi` bundle's
`artifact_bridge_class`, a no-op for every other runtime — writes a generated
mini-catalog into `<clone>/.pi/zimmer-air/` and `PiRuntimeAdapter` names it
through `PI_HOOKS_AIR` and `PI_PLUGINS_CONFIG`.

Three decisions in that generation are worth knowing:

- **The generated index *is* the selection.** `@tadasant/pi-hooks` activates every
  hook in an index it loads — it has no roots concept to filter on — so pointing
  it at Zimmer's whole `hooks/hooks.json` would run every catalog hook in every Pi
  session. The same trick selects plugins without a `PI_PLUGINS` env var: the
  generated `plugins.json` carries `default_in_roots: ["*"]` on exactly the
  plugins the session chose.
- **Naming the files shadows discovery.** Both extensions otherwise look for
  `./air.json` in the working directory — which is a clone of whatever repository
  the session works on, and a repo root is a normal place for an `air.json` to
  live (this one has one). Without the explicit variables, cloning a repository
  would be enough to adopt whatever hooks it declares.
- **A plugin's skills and MCP servers are left to their real owners.** The
  generated plugin entries carry `skills: []` and `mcp_servers: []`, because
  `air prepare pi` already installs plugin skills into `.pi/skills/` and
  `PiMcpConfigPostProcessor` already writes plugin-bundled servers into
  `.mcp.json` with secret resolution and retargeting. `pi-mcp-adapter` merges both
  its config files by name, so letting the extension write its own copy would
  start a second copy of every plugin server.

Only the hooks the session named directly go in the pi-hooks index; anything a
selected plugin bundles is subtracted, because `pi-plugins` dispatches those
through its own runner and a hook reachable both ways would be spawned twice per
event.

**An AIR hook body may speak either runtime's dialect — from
`@tadasant/pi-hooks@0.2.0`.** Claude Code sends `{tool_name, tool_input}` on stdin
and takes context back through `hookSpecificOutput.additionalContext`;
`@tadasant/pi-hooks` sends `{event, toolName, input, content}` and takes
`{"content": ...}`, which *replaces* the tool result rather than appending to it.
From 0.2.0 the extension sends both namings and honors both replies, so a body
written for either runtime runs on Pi unmodified — which is why
`PiExtensions::REGISTRY` pins 0.2.0 as a floor, not just as the current version.
Below it, a body speaking only Claude's dialect loaded cleanly on Pi, ran, and did
nothing, with `[pi-hooks] loaded N hook(s)` printed either way. `PI_HOOK=1` is
still set on every hook process, and the catalog's `git-push-ci-reminder` still
branches on it, because Pi's replacing `content` is the one difference no
translation can paper over.

**An extension's entrypoint is a TypeScript source file, and it comes from the
package.** Pi loads `.ts` extensions directly, so a Pi package's entrypoint is a
file inside the published tarball — `pi-mcp-adapter/index.ts`, not a compiled
`dist/index.js`. The authoritative value is the package's own `pi.extensions`
manifest field (`npm view <pkg> pi.extensions`); read it from there when adding
an entry to the registry rather than assuming a build layout.

Getting that path wrong is silent, which is why two checks guard it.
`PiExtensions#resolved_paths` only passes `-e` for entrypoints that exist —
necessary, because `pi -e <missing path>` makes Pi refuse to start altogether —
so a path that can never exist yields a working Pi session with the extension
simply absent. `Dockerfile.base` therefore follows each `npm install` with a
`test -f` on the entrypoint (`npm install` reports success as soon as the tarball
unpacks, and says nothing about layout), and `pi_extensions_test.rb` asserts that
the path the Dockerfile checks is the path the registry resolves.

**Transcript hooks need a per-runtime parser.** `TranscriptHooks::ToolCallParser.for`
dispatches on the runtime, and Pi's shape (`toolCall` content blocks whose
`arguments` are a real Hash, plus a `toolResult` message stating `isError`
inline) matches neither Claude's nor Codex's. Falling through to the Claude
parser would find nothing and make every hook a silent no-op, so
`TranscriptHooks::PiToolCallParser` exists and the dispatcher now warns on an
unrecognized runtime instead of quietly defaulting.

**Pi's MCP tools are not individually callable.** `pi-mcp-adapter` exposes one
`mcp` proxy tool that the agent searches and calls through, so a dozen servers
cost ~200 tokens instead of thousands. `PiRuntimePromptContribution` tells the
agent this, because one that expects `mcp__server__tool` to exist will otherwise
conclude its servers are missing.

### Where Pi is easier than Codex

Pi accepts `--session-id`, so **Zimmer's session id is Pi's session id**. Two
things follow that Codex cannot have:

- `mints_own_session_id?` is `false` — there is no runtime-generated id to
  capture, and no window before the capture during which the transcript cannot be
  identified.
- `resume_transcript_path` is a real path. Pi resolves `--session-id` against the
  id *inside* a session file rather than its filename, so Zimmer restores a
  stored transcript to one deterministic path and Pi continues appending to its
  leaf. Codex, whose rollouts are date-partitioned, UUID-named and possibly
  Zstandard-compressed, returns `nil` here.

`PiRuntimeAdapter` also passes `--session-dir` pointing inside the clone, so each
session's transcripts live in its own working directory. That removes by
construction the collision `CodexTranscriptSource#fallback_transcript` exists to
defend against, where two concurrent sessions sharing one rollout tree can read
each other's conversations.

## What the existing runtimes get wrong

### Codex classifies by the code it records

A failed Codex turn ends on a rollout `task_complete` record that carries a machine-readable
`codex_error_info` code beside its message, and every failure exits 1. `CodexTurnError` reads that
record — the LAST turn-lifecycle event in the rollout, so an earlier turn's error never stands in for
a later turn that has not ended — and `CodexRetryStrategy` answers the recovery questions from its
code:

| `codex_error_info` (codex-cli 0.146.0) | Predicate | Recovery |
| --- | --- | --- |
| `context_window_exceeded`, or a raw 400 body naming `context_length_exceeded` | `context_length_error?` | resume; Codex compacts the thread itself |
| `internal_server_error`, `server_overloaded`, any 429 or 5xx status, a transport code, or "stream disconnected before completion" | `api_error_for_retry?` | `ApiErrorRetryService` backoff |
| `usage_limit_exceeded` | `api_error_for_retry?` | `ApiErrorRetryService` → `:quota_exceeded` → rotation |
| `unauthorized`, or a 401 status | `auth_recovery_needed?` | `AuthRecoveryCoordinator` |
| anything else | none | fail, and page with Codex's message |

The codes and messages were produced by the real binary against a local fake of the ChatGPT
backend; `CodexTurnError`'s docstring carries the full table and the rollouts live in
`test/fixtures/files/codex_rollouts/`. Two seams carry Codex through services that used to be
Claude-shaped, and a new runtime can answer them too:

- **`TranscriptSource#records_turn_errors?` / `#terminal_turn_error`.** A source that answers them
  is asked which recovery path a dead turn belongs to; the three recovery services stop scanning its
  transcript for Claude's `isApiErrorMessage` envelope. `RecordedTurnError` is the one reader the
  strategy and the services share, and it keeps a handled-turn marker so a recovery whose
  replacement dies before writing anything cannot act on the same dead turn twice.
- **`RuntimeCliAdapter.compacts_on_resume?`.** Codex, after a context-window failure, compacts the
  thread before answering whatever the resume says. `ContextLengthRetryService` therefore resumes
  it with the recovery nudge and owes no second "Continue with the previous task" turn — where
  Claude gets `/compact` and the continuation after it.

Pi answers the first seam and deliberately declines the second, which is what the next section is
about: answering `records_turn_errors?` is how a runtime gets retry, but a runtime that cannot
compact must not claim `compacts_on_resume?` to reach the compaction path — the resume would simply
make the prompt longer.

Quota and auth need no new plumbing: `CodexAuthProvider#rotate_for_quota!` and the runtime-agnostic
`AuthRecoveryCoordinator` do the work once a classifier routes to them. The coordinator gains one
Codex-specific branch, behind `RuntimeAuthProvider#refresh_proves_serviceable?`: Codex's
`unauthorized` is only ever about the credential (quota has its own code), so when refreshing an
OAuth account succeeds the session is re-seeded with it once, instead of rotating away from an
account that works; an API-key account, whose refresh is a no-op, rotates. A usage-limit refusal
also leaves the account's rate-limit windows behind, which `ApiErrorRetryService` keeps as a quota
snapshot so `QuotaResetCheckerJob` can restore the account once they reset. What is still open is in
[Known limitations](/limitations/#codex-failure-classification-rests-on-one-cli-versions-record).

Extension env contributions reach every runtime: `CliSpawnEnv#apply_extension_env` is called
by all three adapters, with the runtime's own id in the context. `SubagentTranscript` resolves its
normalizer through `TranscriptRuntime` like every other transcript read.

### Pi retries what it can and names what it cannot

`PiRetryStrategy` answers from the error Pi recorded, through the same
`RecordedTurnError` seam Codex uses — and for two of its failure classes the
truthful answer is that no recovery path owns them.

**A failed model call does not fail the Pi process.** Driven against a local
provider stub returning 401, 403, 429, 500, 502, 503, a 400
`context_length_exceeded`, a dropped stream and a refused connection, a pinned
`pi 0.84.4` exited 0 every time and wrote the failure into its transcript
instead, as an assistant message with `stopReason: "error"` and an `errorMessage`
carrying the provider's own words. Nothing reached stderr. So `pi -p` exits
non-zero for *Pi's* failures, and 0 for the provider's — which means Pi's whole
recovery ladder is walked on the door marked "the turn completed"
(`ProcessLifecycleManager#diagnose_completed_turn`).

`PiTurnError` parses that record and classifies it; `PiTranscriptSource` answers
`records_turn_errors? => true`, so `ApiErrorRetryService` asks for it instead of
scanning for Claude's `isApiErrorMessage` envelope. A 5xx, a 429 (OpenAI's rate limit or
a gateway's own rate-limit wording), a 408, a `terminated` stream and a `Connection error.` are
`:retryable` and get the six-attempt backoff, bounded by the same `RetryBudget`
the Claude path uses. The handled-turn marker means a respawn that dies before
writing anything cannot spend a second retry on the same dead turn.

**It classifies on the HTTP status, not the error body, and that generalizes.**
The characterization drove an OpenAI-dialect stub, but production Pi talks to
OpenRouter, which words its bodies differently — so a body-keyed classifier would
misroute the provider Zimmer actually ships. A status is the runtime's own
framing and is provider-independent; a 4xx Zimmer cannot name more precisely is
`:request_rejected`, which is *recognized* and terminal rather than unclassified.
That distinction is the one worth copying into a new runtime: `recognized?` means
"failing on this is not news", and reserving `false` for shapes you genuinely
cannot read is what keeps `classifies_exits?` from converting every unfamiliar
provider dialect into a standing page.

**Two kinds route nowhere, and say so.** `PiTurnError` gives a 401/403 the kind
`:auth_terminal` and a 400 `context_length_exceeded` the kind
`:context_length_terminal` — names no recovery service looks for, so neither can
be reached however the ladder is rearranged later:

- `PiAuthProvider` pools no accounts, so `AuthRecoveryService` has no credential
  to rewrite and nothing to rotate to. Answering `auth_recovery_needed?` would
  park a human in front of a pool that does not exist.
- Pi has no `/compact`, and unlike Codex it does not compact on a plain resume:
  `PiRuntimeAdapter.compacts_on_resume?` is `false` because resuming a session
  that died on a context-length 400 wrote no compaction record and re-sent the
  same conversation one message longer. Answering `context_length_error?` would
  spend the budget making the prompt bigger.

Both kinds are `recognized?`, so they fail the session with the provider's own
wording and **no page** — they are known failures with a deliberate disposition,
not unknown ones. Only a wording nothing recognizes reaches
`UnclassifiedFailureReporter`, and `classifies_exits?` is now `true` so it gets
there. What is still open is in [Known
limitations](/limitations/#pi-retries-a-transient-provider-failure-and-parks-a-quota-wall-auth-and-context-length-are-terminal).

**A quota wall parks on a timer.** A 402, and a 429 whose wording matches
`PiTurnError::PROVIDER_LIMIT_WORDING` — pi-ai's own list of limits it will not
retry, copied verbatim — is `:quota`. `PiRetryStrategy#api_error_for_retry?`
takes it, so `ApiErrorRetryService` answers `:quota_exceeded` without spending
the budget, exactly as it does for Codex's `usage_limit_exceeded`. What differs is
the step after: `ProcessLifecycleManager` asks
`RuntimeAuthProvider#pools_accounts?`, and for a runtime that answers `false` it
skips rotation and `AuthOutageParkService` — whose wake waits on an account in a
pool — and parks on `ProviderQuotaWallPark` instead, a one-time wake on a ladder
of 15 minutes doubling to 8 hours, ended by the next completed turn and bounded at
seven days. A new runtime that authenticates from an unpooled key gets this by
answering `pools_accounts? => false`.

There is also no failed-resume pattern to match, and unlike the above that one is
correct rather than deferred: Pi's `--session-id` *creates* a missing session
rather than failing, so the condition cannot arise. Pi is deliberately absent from
`RuntimeAuthProvider::RUNTIMES` and from `RuntimeLoginDriver.for`: it has no
tokens to refresh and no interactive login flow.
