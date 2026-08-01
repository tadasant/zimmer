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

| Slot | `claude_code` | `codex` |
| --- | --- | --- |
| `air_adapter_name` | `"claude"` | `"codex"` |
| `cli_adapter_class` | `ClaudeCliAdapter` | `CodexRuntimeAdapter` |
| `retry_strategy_class` | `ClaudeRetryStrategy` | `CodexRetryStrategy` |
| `transcript_source_class` | `ClaudeTranscriptSource` | `CodexTranscriptSource` |
| `transcript_normalizer_class` | `ClaudeTranscriptNormalizer` | `CodexTranscriptNormalizer` |
| `mcp_status_detector_class` | `McpLogPollerService` | `CodexMcpStatusDetector` |
| `config_post_processor_class` | `ClaudeMcpConfigPostProcessor` | `CodexConfigTomlPostProcessor` |
| `mcp_credential_writer_class` | `ClaudeMcpCredentialWriter` | `CodexMcpCredentialWriter` |
| `prompt_contribution_class` | `ClaudeRuntimePromptContribution` | `nil` |
| `auth_provider_class` | `nil` | `nil` |
| `config_preparer_class` | `nil` | `nil` |

:::note[Three slots are dead weight]
`auth_provider_class` is `nil` for both runtimes even though both classes exist — auth resolves
through `RuntimeAuthProvider.for` instead. `prompt_contribution_class` is `nil` for Codex even though
`CodexRuntimePromptContribution` exists; it resolves through `RuntimePromptContribution.for`.
`config_preparer_class` is `nil` everywhere and nothing reads it.
Tracked in [#97](https://github.com/tadasant/zimmer/issues/97).
:::

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
```

`mints_own_session_id?` is a correctness landmine. If you return `true` for a runtime whose
session id Zimmer generates, forked sessions collide on the unique `session_id` index.
Tracked in [#96](https://github.com/tadasant/zimmer/issues/96).

### The rest

- **`RuntimePromptContribution`** — `guidelines_bullets`, `clarifying_questions_suffix`,
  `project_instructions_filename` (`CLAUDE.md` vs `AGENTS.md`), `delivered_via_file?`,
  `system_prompt_filename`.
- **`RuntimeConfigPostProcessor`** — a template-method base. Implement `config_path`, `parse_config`,
  `empty_config`, `servers_map`, `build_server_entry`, `resolve_and_rewrite!`, `serialize_config`.
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
5. Transcript source + normalizer — including `find_main_transcript` and `mints_own_session_id?`.
6. Prompt contribution → register in `RuntimePromptContribution.for`.
7. Config post-processor.
8. MCP credential writer.
9. MCP status detector.
10. Auth provider → `RuntimeAuthProvider.for` and `RUNTIMES`. Login driver →
    `RuntimeLoginDriver.for`.
11. `Dockerfile.base` — pin the CLI and the matching `@pulsemcp/air-adapter-<runtime>`. Add to
    `CliStatusService::CLI_TOOLS`.
12. Add the adapter to `RuntimeCliAdapterContractTest::ADAPTERS` and write a mock in `test/support/`.

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

- Shared code still says "Claude." `TranscriptPollerService` logs *"Waiting for Claude CLI to
  create transcript directory…"* for every runtime.
- `ELICITATION_SESSION_ID` is Claude-only — elicitations
  [silently no-op on Codex](/sessions/elicitation/#known-problems).
- `Zimmer::ExtensionRegistry.spawn_env_contributions` is Claude-only — extension env contributions are
  unreachable from Codex, despite the hook receiving a `runtime` context.
- `SubagentTranscript#open_transcript_events` hardcodes `ClaudeTranscriptNormalizer`.
