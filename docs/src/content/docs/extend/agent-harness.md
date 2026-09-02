---
title: Adding an agent harness
description: The twelve-slot runtime bundle, every interface a new harness must implement, and the three registries that don't go through the bundle.
sidebar:
  order: 2
---

A **runtime** (agent harness) is a `RuntimeRegistry::Bundle` — a struct with twelve slots, one for each
seam where driving a vendor CLI differs. The bundle is plain data — a struct of class references
Zimmer looks up at runtime.

```ruby
Bundle = Struct.new(
  :runtime, :air_adapter_name, :cli_adapter_class, :retry_strategy_class,
  :transcript_source_class, :transcript_normalizer_class, :mcp_status_detector_class,
  :prompt_contribution_class, :config_preparer_class, :config_post_processor_class,
  :auth_provider_class, :mcp_credential_writer_class,
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
| `mcp_status_detector_class` | `McpLogPollerService` | `CodexMcpStatusDetector` | `nil` |
| `config_post_processor_class` | `ClaudeMcpConfigPostProcessor` | `CodexConfigTomlPostProcessor` | `PiMcpConfigPostProcessor` |
| `mcp_credential_writer_class` | `ClaudeMcpCredentialWriter` | `CodexMcpCredentialWriter` | `nil` |
| `prompt_contribution_class` | `ClaudeRuntimePromptContribution` | `nil` | `PiRuntimePromptContribution` |
| `auth_provider_class` | `nil` | `nil` | `nil` |
| `config_preparer_class` | `nil` | `nil` | `nil` |

Claude and Codex share a shape: their AIR adapter writes the config, and the
runtime supplies MCP, hooks and plugins itself. Pi does neither, which is what
makes it the interesting third column — see
[Pi is the runtime that supplies nothing](#pi-is-the-runtime-that-supplies-nothing).

:::note[Three slots are dead weight]
`auth_provider_class` is `nil` for both runtimes even though both classes exist — auth resolves
through `RuntimeAuthProvider.for` instead. `prompt_contribution_class` is `nil` for Codex even though
`CodexRuntimePromptContribution` exists; it resolves through `RuntimePromptContribution.for`.
`config_preparer_class` is `nil` everywhere and nothing reads it. Pi fills its
`prompt_contribution_class` slot anyway — leaving it `nil` while the class exists
is exactly the inconsistency being tracked — but it still resolves through
`RuntimePromptContribution.for` like the others.
Tracked in [#97](https://github.com/tadasant/zimmer/issues/97).
:::

Two `pi` slots are `nil` for reasons of their own rather than by that convention:

- **`mcp_status_detector_class`** — Pi writes no per-server MCP log files, so
  Claude's log poller has nothing to read, and unlike Codex it records no
  `mcp__<server>__<tool>` calls to mine either: the `pi-mcp-adapter` extension
  routes every server through one `mcp` proxy tool, so a transcript shows `mcp`
  being called and never names the server behind it. There is no per-server
  signal to detect — but the slot holds `NullMcpStatusDetector`, **not `nil`**.
  `TranscriptPollerService#initialize` calls `.new` on this slot with no nil
  check, so a `nil` here raises `NoMethodError` on every poll of every session on
  the runtime, before any MCP-specific guard can run. That is the general rule:
  **a slot some caller dereferences must never be `nil`** — a runtime with
  nothing real to put there supplies a null object.
  `test/contracts/runtime_bundle_slot_contract_test.rb` enforces this for every
  registered runtime and every unconditionally-dereferenced slot.
- **`mcp_credential_writer_class`** — Pi keeps MCP OAuth tokens inside the
  `pi-mcp-adapter` extension's own state, which Zimmer does not write. This slot
  *may* be `nil` because both its callers are guarded:
  `RuntimeRegistry.mcp_credential_writer_classes` compacts the list (the caller
  instantiates every class it returns, on the credential-retire path — i.e. while
  a credential is already failing), and `McpOauthCredentialInjector` asks
  `#credential_store?` first. That second guard is load-bearing rather than
  defensive: `McpOauthController#reinject_and_resume` calls injection and the
  resume service inside one `rescue`, so a raise from injection would skip the
  resume and leave a session parked on an OAuth gate permanently un-resumable.

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
self.validate_working_dir!(dir)  # provided: refuses nil/blank, raising spawn_error_class
```

`stderr_log_filename` is what `Session#stderr_log_path` reads, so skipping it doesn't fail
quietly — it raises `NotImplementedError` the first time a session on your runtime is resumed,
interrupted, or terminated. Build your spawn-time path from it too (`self.class.stderr_log_path`),
so the name your process writes and the name every caller reads cannot drift.

`validate_working_dir!` must run at the top of `execute` and `resume`, before anything joins onto
`working_dir`. A nil working directory does reach adapters — that was #183 — and without the guard
it dies inside `Process.spawn` with a message that names no argument.

Enforced by `test/contracts/runtime_cli_adapter_contract_test.rb`, which asserts keyword-set
equality via `instance_method(:execute).parameters`, the stderr-filename shape, and the
working-dir guard's accept/reject behavior. Add your adapter (and a mock) to
`RuntimeCliAdapterContractTest::ADAPTERS`. An adapter provided by an extension lives outside that
list, so call `assert_runtime_cli_adapter_contract` from the extension's own test instead.

Also `include CliSpawnEnv` — don't reimplement env scrubbing.

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
entirely. See the Codex note under [What the existing runtimes get wrong](#what-the-existing-runtimes-get-wrong).

### `TranscriptSource`

```ruby
transcript_directory(working_directory:)
resume_transcript_path(session:, working_directory:)   # default nil = "no single-file restore"
locate(session:, working_directory:)
read(path)
parse_events(serialized)
discover_subagent_files(working_directory:, session_id:)
mcp_log_paths(working_directory:)
find_main_transcript(transcript_directory:, session:)
```

`find_main_transcript` is declared on the abstract base class and raises `NotImplementedError`
there, like the rest of the required surface. `TranscriptPollerService` calls it on every poll, so a
source that skipped it used to `NoMethodError` on its first poll instead of failing at the seam
(#56).

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
  base class's no-op, which parks its sessions instead of rotating them.
- **`RuntimeLoginDriver`** — `command`, `env(config_dir)`, `parse_verification(buffer)`,
  `completion_mode` (`:poll` | `:paste`), `capture!(config_dir, account)`, `credentials_ready?`.

## The checklist

1. `RuntimeRegistry` — new `Bundle`, add to `BUNDLES` and `LABELS`.
2. `ModelCatalog::MODELS["<runtime>"]` — exactly one entry with `default: true`.
3. CLI adapter — `include RuntimeCliAdapter` + `CliSpawnEnv`. Identical kwargs.
   Declare `self.stderr_log_filename` (`<runtime>_stderr.log`) and guard `execute`/`resume`
   with `validate_working_dir!`. `pgroup: true`, NULL stdin/stdout.
4. Retry strategy — all five predicates.
5. Transcript source + normalizer — including `find_main_transcript`, `mints_own_session_id?`
   and `conversation_record?`.
6. Prompt contribution → register in `RuntimePromptContribution.for`.
7. Config post-processor.
8. MCP credential writer.
9. MCP status detector.
10. Auth provider → `RuntimeAuthProvider.for` and `RUNTIMES`. Login driver →
    `RuntimeLoginDriver.for`.
11. `Dockerfile.base` — pin the CLI and the matching `@pulsemcp/air-adapter-<runtime>`. Add to
    `CliStatusService::CLI_TOOLS`. If the runtime needs vendor extensions to reach MCP/hooks
    (Pi does), pin those too and declare them in a registry the Dockerfile is asserted against —
    see `PiExtensions`.
12. Add the adapter to `RuntimeCliAdapterContractTest::ADAPTERS` and write a mock in `test/support/`.

## Pi is the runtime that supplies nothing

Claude Code and Codex both arrive with MCP, hooks and plugins built in, so
Zimmer's job for them is to write config files into a shape the runtime already
understands. Pi ships a skills mechanism and nothing else. Three consequences are
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

Codex is the honest reference implementation, and it is *incomplete*:

:::danger[`CodexRetryStrategy` classifies almost nothing]
It returns `false` from `context_length_error?`, `api_error_for_retry?`, and
`auth_recovery_needed?`, and only matches `/no rollout found/i`. Exit code 0 is still treated as
success.

Which means, for a Codex session: no context-length compaction retry, no API-error retry, no quota
rotation, and no auth recovery. Everything the Claude path does to keep a session alive, Codex
sessions do without.

`AuthRecoveryCoordinator` is runtime-agnostic — it reads the pool and rotates through
`RuntimeAuthProvider`, and `CodexAuthProvider` implements both — so the coordinated
adopt/rotate/park behaviour is available to Codex the moment
`CodexRetryStrategy#auth_recovery_needed?` learns to recognize the signature. Until then it is
unreachable for Codex, because nothing routes a Codex exit into the auth branch. The blocker is the
classifier, not the recovery.
:::

Other known gaps:

- `ELICITATION_SESSION_ID` is Claude-only — elicitations
  [silently no-op on Codex](/sessions/elicitation/#known-problems).
- `Zimmer::ExtensionRegistry.spawn_env_contributions` is Claude-only — extension env contributions are
  unreachable from Codex, despite the hook receiving a `runtime` context.
- `SubagentTranscript#open_transcript_events` hardcodes `ClaudeTranscriptNormalizer`.

`PiRetryStrategy` classifies even less than Codex's does — `context_length_error?`,
`api_error_for_retry?` and `auth_recovery_needed?` all return `false`, and unlike
Codex there is no failed-resume pattern to match either (Pi's `--session-id`
*creates* a missing session rather than failing, so the condition cannot arise).
Every one of those surfaces as an ordinary non-zero exit that is reported rather
than hidden, and `classifies_exits?` is `false` so the expected shape of a Pi
failure does not become a standing page. It is still a gap, not a neutral
default. `PiAuthProvider` pools no accounts — Pi resolves a provider API key from
the session environment per request — so there is nothing for the auth-recovery
path to rotate *to*, which is why the missing classifier costs Pi less than it
costs Codex. Pi is deliberately absent from `RuntimeAuthProvider::RUNTIMES` and
from `RuntimeLoginDriver.for`: it has no tokens to refresh and no interactive
login flow.
