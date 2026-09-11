---
title: Runtimes
description: The three agent harnesses a session can run on — Claude Code, Codex and Pi — what each needs, which models each offers, and where they behave differently.
---

A session runs one headless coding-agent CLI, and there are three to pick from. Which one a
session gets is the `sessions.agent_runtime` column, and the choice is per session.

| | `claude_code` | `codex` | `pi` |
| --- | --- | --- | --- |
| CLI | `claude` | `codex exec` | `pi -p` |
| Vendor | Anthropic | OpenAI | Pi coding agent (`@earendil-works/pi-coding-agent`, pinned to 0.84.4 in `Dockerfile.base`) |
| Credential | pooled OAuth subscription account | pooled OAuth subscription account | `OPENROUTER_API_KEY`, put in Pi's process environment at spawn |
| Default model | `opus` | `gpt-5.6-terra` | `openrouter/anthropic/claude-opus-4.6` |
| MCP, hooks, plugins | all three native | MCP native; no hook lifecycle for AIR to translate into | none native — all three come from [pinned Pi extensions](#pi-brings-no-mcp-hooks-or-plugins-of-its-own) |

`RuntimeRegistry::BUNDLES` is the list, and `RuntimeRegistry::LABELS` is what the UI renders
("Claude Code", "Codex", "Pi"). Registering a runtime there is what makes it selectable —
`AgentRootsConfig.available_runtimes` returns the whole registry, so any agent root can be
launched under any of the three regardless of what it declares as its own default.

For how a fourth would be added, see [Adding an agent harness](/extend/agent-harness/). This page
is about the three that ship.

## Picking one

Three places set it, most specific first:

1. The session's own `agent_runtime`, passed at creation (the new-session form's runtime selector,
   or the `agent_runtime` param on `POST /api/v1/sessions` and `start_session`).
2. The agent root's `default_runtime` in `roots.json`.
3. Settings → **Default runtime**, which is `AppSetting#default_runtime`.

Below all three is the database column default, `claude_code`.

:::caution[`start_session` skips the global default when you name no agent root]
The REST API honors the chain in full: `Api::V1::SessionsController#resolve_agent_root_defaults!`
runs whether or not `agent_root` was given, so a rootless `POST /api/v1/sessions` still picks up
Settings → Default runtime. The MCP `start_session` tool does not — it reaches
`apply_agent_root_defaults!` only `if agent_root_name`, so a rootless MCP spawn falls through to the
column default. Set the global default to `pi`, start a session over MCP with no `agent_root`, and
you get Claude Code.
:::

## Models

`ModelCatalog::MODELS` is the authoritative per-runtime list, and it is what the new-session form,
the detail-page model editor and the REST API all validate against.

| Runtime | Model ids |
| --- | --- |
| `claude_code` | `opus` (default), `sonnet`, `haiku`, `fable` |
| `codex` | `gpt-5.6-terra` (default), `gpt-5.6-sol`, `gpt-5.6-luna`, `gpt-5.5`, `gpt-5.4`, `gpt-5.4-mini`, and two deprecated `*-codex` ids |
| `pi` | `openrouter/anthropic/claude-opus-4.6` (default), `…/claude-sonnet-4.6`, `…/claude-haiku-4.5`, `openrouter/openai/gpt-5.4`, `…/gpt-5.4-mini`, `openrouter/google/gemini-3.5-flash`, plus direct `anthropic/*` and `openai/*` ids |

**Pi's ids are provider-qualified, and the other two runtimes' are not.** `pi --model` takes a
bare id or a `provider/id` pattern, so the catalog stores the qualified form and
`PiRuntimeAdapter` passes it through verbatim — no separate `--provider` flag. OpenRouter is
itself a provider, so its ids carry the vendor after it as well:
`openrouter/anthropic/claude-opus-4.6` is three segments, not two.

The `anthropic/*` and `openai/*` entries at the end of Pi's list go direct to the vendor and need
`ANTHROPIC_API_KEY` or `OPENAI_API_KEY`. They are kept in the catalog so a session pinned to one
still validates; this deployment feeds neither key, so the `openrouter/*` ids are the ones that
run.

Two of the three runtimes have a refresh discipline written into `ModelCatalog`, and Pi's has a
trap in it: `pi --list-models` only prints providers whose credential currently resolves, so
running it without `OPENROUTER_API_KEY` set silently omits every `openrouter` row and makes the
catalog look far smaller than it is.

`requires_oauth` marks the Codex models that only work with a ChatGPT login. No Claude Code or Pi
model sets it true.

`messages_api_id` is the model's id on Anthropic's `POST /v1/messages`, and only `haiku` sets it
(`claude-haiku-4-5`). The quota probe is the one caller that hits that endpoint directly
(`QuotaCheckService::PROBE_MODEL`, via `ModelCatalog.messages_api_id_for`; see
[Agent harness credentials](/auth/harness/)). The endpoint answers the bare CLI alias `haiku` with a
400, so the CLI id cannot double as the API id. The field holds the endpoint's floating alias, never a
dated snapshot.

In the app's Ruby, the catalog is the only place a versioned Claude model id is written.
`ModelCatalogTest` fails on a dated snapshot anywhere in the catalog, on a `claude_code` id that
`ClaudeModelConfigurationAudit` would call a version pin, and on a Claude model version inside any
string, symbol or backtick literal under `app/`, `config/` or `lib/` outside `model_catalog.rb`,
including one embedded in a tool description or a command line. So a model id added somewhere else
fails CI until it moves here or is looked up from here. Comments, ERB, YAML and JavaScript are not
scanned.

## Credentials

Claude Code and Codex share a shape: `ClaudeAccount` rows, one marked current per runtime, tokens
written to a host-global file, and rotation when one hits a quota wall. That is
[Agent harness credentials](/auth/harness/).

**Pi is not in that pool, and nothing about it rotates.** Pi resolves a provider credential per
request from its own process environment, so `PiAuthProvider` pools nothing and every one of its
pooling methods is a documented no-op — `#accounts` returns an always-empty relation rather than `nil`
precisely because callers chain `.available.exists?` onto it. There is no Pi identity to mark
current, nothing to refresh, and no Pi entry in `RuntimeAuthProvider::RUNTIMES` (the constant that
drives the token-refresh sweep and the auth warm-up fan-out).

The key is `OPENROUTER_API_KEY`, set on the Inference page's Pi tab, which writes it to the
Parameter Store — see [How the key reaches a Pi
session](/operate/secrets-parameter-store/#how-the-key-reaches-a-pi-session). It reaches the
process through `PiRuntimeAdapter#apply_provider_key` rather than through the session `.env`
writer, because that writer reads Rails-encrypted `mcp_secrets` only and never consults
`SecretProviders`. A value already in the clone's `.env` wins, and a store Zimmer cannot reach is
logged rather than fatal: the session spawns and Pi reports its own `not_ready`.

`CliStatusService` is the observable answer to "can a Pi session run" — it shells
`pi auth check --provider openrouter`, which prints `ready` and exits 0 when the key resolves.
It is served by `GET /api/v1/clis/status` and `get_system_health(include_cli_status: true)`, so a session
can learn whether the key is set without any surface being able to tell it what the key is.

## What differs at spawn

| | Claude Code | Codex | Pi |
| --- | --- | --- | --- |
| Session id | Zimmer generates it, `--session-id` | Codex mints its own; Zimmer reads it off `codex exec --json` | Zimmer's id **is** Pi's id, `--session-id` (it creates the session when missing) |
| MCP config | `--mcp-config <path>` | `~/.codex/config.toml` (no flag) | `.mcp.json` in the working directory, read by the `pi-mcp-adapter` extension (no flag) |
| System prompt | `--append-system-prompt` | written into `AGENTS.md` below a marker | `--append-system-prompt <file>` |
| Resume | `--resume UUID` | `codex exec resume UUID` | re-run with the same `--session-id` — no resume subcommand |
| Transcript | `~/.claude/projects/…/*.jsonl` | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl{,.zst}` | `<clone>/.pi/sessions/*.jsonl` |
| Config dir | `~/.claude` | `CODEX_HOME` (`~/.codex`) | `PI_CODING_AGENT_DIR` (`~/.pi/agent`) |
| Stderr log | `claude_stderr.log` | `codex_stderr.log` | `pi_stderr.log` |

Pi's system prompt goes through a file because the orchestrator prompt runs to many kilobytes and
Linux caps a single argv entry at 128 KiB; passing it inline would fail the spawn with `E2BIG`
instead of running. It is rewritten on every spawn so a resumed turn never appends a stale prompt.

Pi also reads `AGENTS.md` and `CLAUDE.md` from the working directory on its own, which is why
`PiRuntimePromptContribution#delivered_via_file?` is `false`: writing the orchestrator prompt into
a project file *as well* would put it in the model's context twice.

Two flags on the Pi command line have no analogue on the other two. `--approve` trusts
project-local files for the run — without it Pi treats the `.pi/skills/` and `.mcp.json` Zimmer
just wrote as untrusted third-party content and, having no TTY in `-p` mode to ask about them,
silently ignores everything. `-e <path>` loads each Pi extension, once per extension.

## Pi brings no MCP, hooks or plugins of its own

Pi ships a skills mechanism and stops there. Everything else arrives as a Pi extension, installed
into `/opt/pi-extensions` at image-build time and passed explicitly with `pi -e`:

| Extension | Version | What it supplies |
| --- | --- | --- |
| `pi-mcp-adapter` | 2.32.1 | MCP servers, read from the `.mcp.json` in the clone |
| `@tadasant/pi-hooks` | 0.2.0 | AIR lifecycle hooks |
| `@tadasant/pi-plugins` | 0.2.0 | AIR plugins — a manifest's skills, hooks and MCP servers |

`PiExtensions` is the registry, and both `@tadasant` packages live in
[`tadasant/pi-extensions`](https://github.com/tadasant/pi-extensions). The `0.2.0` floor is not
cosmetic: below it a portable AIR hook loads, matches, spawns, and has everything it wrote thrown
away, with logs indistinguishable from a hook that worked.

Two consequences follow for the reader rather than the implementer.

**MCP tools are not individually callable on Pi.** `pi-mcp-adapter` exposes one `mcp` proxy tool
that the agent searches and calls through, so a dozen servers do not consume the context window
before the session starts. `PiRuntimePromptContribution` tells the agent so, because one that expects
`mcp__server__tool` to exist will otherwise conclude its servers are missing. It also means a Pi
transcript names MCP tools differently from a Claude Code one — see [Transcript
hooks](/extend/transcript-hooks/).

**A Pi session's MCP servers connect lazily.** At spawn every server reports disconnected, and
that is the healthy resting state. `pending` on a Pi session means "not connected yet", not
"broken". The full evidence table is [What actually works on the Pi
runtime](/limitations/#what-actually-works-on-the-pi-runtime--the-harness-matrix).

The implementation — why `PiMcpConfigPostProcessor` *writes* the server table rather than
adjusting one, and what `PiAirBridge` generates so the hook and plugin extensions run the
session's selection and not the cloned repo's — is in [Pi is the runtime that supplies
nothing](/extend/agent-harness/#pi-is-the-runtime-that-supplies-nothing).

## Where Pi is partial today

Some of these follow from the runtime itself; others are Zimmer wiring that has not been done.
Either way each is worth knowing before you route real work to Pi.

- **No subagents.** Claude Code has `Task`/`Agent` and Codex has `spawn_agent`. Pi has neither, so
  the orchestrator prompt points a Pi session's self-review at the `/code-review` skill instead.
  `PiTranscriptNormalizer`'s subagent extractors always return `[]`.
- **A failed model call is reported, not retried.** `pi -p` exits 0 even when the model call
  returned 401, 429, 500 or a context-length 400 — it records `stopReason: "error"` in the
  transcript and writes nothing to stderr. `PiRetryStrategy#terminal_api_error` is what stops that
  turn being reported as a successful pause, but `context_length_error?`, `api_error_for_retry?`
  and `auth_recovery_needed?` all answer `false`. So a Pi provider failure is failed and named
  rather than retried. The recovery services now take a runtime's own record of a failed turn
  (Codex answers `TranscriptSource#records_turn_errors?`); teaching Pi to answer it is its own piece
  of work ([#856](https://github.com/tadasant/zimmer/issues/856)).
- **Status summaries always take the cheap path.** `SessionStatusSummaryGenerator#pool_exhausted?`
  reads `accounts.available.none?`, which is true for Pi by construction, so a Pi session's
  summary is generated by a headless completion rather than by forking the session. See [The
  Status summary](/sessions/status-summary/).
- **Cost is priced on the Anthropic models only.** Token counts are ingested for every Pi model;
  `Rate` carries no entry for the OpenAI and Google ids, so a Pi session on one of those lands
  with correct tokens and a zero cost. See [Token spend](/operate/costs/#pis-token-usage).
- **A transcript hook cannot see a Pi session's MCP tool calls.** `pi-mcp-adapter` routes every
  call through one proxy tool rather than naming the server, so a Pi transcript carries no
  `mcp__<server>__<tool>` for a hook to key on — a PR opened through an MCP `create_pull_request`
  goes unrecorded. See [Transcript hooks](/extend/transcript-hooks/).
- **A Pi session's MCP status pills go green or stay grey, never red.** `PiMcpStatusDetector` mines
  the transcript for proxy-tool signals, and an absent signal is indistinguishable from a server
  nothing called. See [Known
  limitations](/limitations/#a-pi-sessions-mcp-status-pills-go-green-or-stay-grey--never-red).
- **A refreshed MCP OAuth token does not reach a Pi session that is already running.** Pi ships its
  own MCP OAuth client and refreshes mid-session, and Zimmer adopts that rotation back — but at the
  next spawn or the next cron run, not into the live process, which memoizes the entry until its own
  provider rejects it. See [MCP server OAuth](/auth/mcp-oauth/#capturing-the-token-the-runtime-rotates-write-back)
  and [Known limitations](/limitations/#a-refreshed-mcp-oauth-token-does-not-reach-a-session-that-is-already-running).
- **The spot concurrency ceiling does not count Pi, and never pauses it.** That ceiling, and every
  pause and preemption path, filter on `agent_runtime = 'claude_code'`, because they price a running
  fleet against an Anthropic quota window — a Pi session spends against an OpenRouter key instead.
  The *top-up* ceiling is the exception and counts every runtime, Pi included. See [Spot and
  priority](/sessions/spot-and-priority/#what-the-ceiling-counts-and-what-it-does-not).

## Where Pi is easier

Pi accepts `--session-id`, so Zimmer's session id is Pi's session id. `mints_own_session_id?` is
`false` and there is no window before a capture during which the transcript cannot be identified.

`PiRuntimeAdapter` also points `--session-dir` inside the clone, so each session's transcripts
live in its own working directory. Two concurrent Codex sessions share one rollout tree and can
latch onto each other's files, which is what `CodexTranscriptSource#fallback_transcript` exists to
defend against; two Pi sessions cannot collide, because a clone path is unique per session.

That same choice makes Pi restorable from a single deterministic file — Pi resolves `--session-id`
against the id *inside* a session file rather than its filename, so Zimmer writes the stored bytes
to one path and Pi continues appending to its leaf. Codex returns `nil` there and cannot.

The cost of putting the transcript in the clone is that it is reaped with the clone, which is why
`PiTokenUsageIngestionService` is the one usage ingestor that reads no file at all: it reads the
durable copy in `sessions.transcript`. See [Token spend](/operate/costs/).
