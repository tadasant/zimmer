---
title: MCP servers
description: How MCP servers are declared, selected per session, secret-injected, and turned into the agent's blast radius.
sidebar:
  order: 5
---

An MCP server is a tool provider the agent can call. The set of MCP servers on a session is the
session's blast radius — the complete list of things the agent can do outside its own clone.

## The entry format

MCP is the one artifact type with no separate body — the index entry *is* the connection config.
From `mcp.json`:

```json
"playwright-custom": {
  "title": "Playwright Custom",
  "description": "Playwright MCP server for browser automation and screenshots.",
  "type": "stdio",
  "command": "npx",
  "args": ["-y", "playwright-stealth-mcp-server@latest"],
  "env": { "STEALTH_MODE": "false", "HEADLESS": "true" },
  "default_in_roots": ["zimmer"]
}
```

| Field | Notes |
| --- | --- |
| `type` | `stdio` \| `sse` \| `streamable-http` (`http`) |
| `command` / `args` / `env` | stdio servers |
| `url` / `headers` | remote servers |
| `oauth` | remote servers that need an OAuth flow |
| `default_in_roots` | which roots get it by default |
| `unavailable` | a standing declaration that this entry cannot work here, and why |

`env` and `headers` values may contain `${VAR}` placeholders.

### `unavailable`: the breakage Zimmer cannot detect

Zimmer works out readiness for itself — see [Availability, and what an agent is
offered](#availability-and-what-an-agent-is-offered) below. `unavailable` exists for the one class it
cannot: an entry whose every `${VAR}` resolves and whose endpoint still cannot serve Zimmer. A server
written for OAuth whose endpoint accepts only static bearer tokens and publishes no OAuth discovery
passes every local check and is unusable anyway, and no amount of probing infers that.

```json
"strad-secrets-oauth": {
  "title": "Strad Secrets (OAuth)",
  "type": "streamable-http",
  "url": "https://secrets.example.com/mcp",
  "unavailable": "The endpoint accepts only static bearer tokens and exposes no OAuth discovery."
}
```

- **Type:** string. Non-empty (after trimming) means unavailable, and the string **is** the reason —
  reported on the Connectors page and in `get_configs`'s unavailable roster.
- **It is normalized before it is shown.** Whitespace collapses to single spaces and the reason is
  truncated at 200 characters, because it lands in a markdown list an agent reads as part of a tool
  response: a newline would split the line it sits on, and a long one would crowd out the roster.
  Write one sentence.
- **Absent, `null`, blank, or a non-string** means nothing is declared. Note what that is *not*: it
  is not a claim that the server works, only that the catalog is silent, so the ordinary readiness
  checks decide. There is deliberately no `"unavailable": true` — requiring the reason by
  construction is the whole point.
- **Remove it when the server is fixed.** It is a fact about the world, not a permanent label.

Do **not** encode availability in `description` instead. Prose like `⚠️ NOT USABLE YET` is invisible
to every check, cannot be acted on, and goes stale silently — which is exactly what this field
replaced.

The formal schema is published by AIR at
[`pulsemcp.github.io/air/schemas/mcp.schema.json`](https://pulsemcp.github.io/air/schemas/mcp.schema.json)
— which is what `mcp.json`'s own `$schema` key points at. A snapshot is also served from this site at
[`/mcp.schema.json`](/mcp.schema.json).

:::note[The local schema copy is only a convenience snapshot]
The old `docs/mcp.schema.json` had a `$id` pointing at a path inside `tadasant/zimmer-catalog` that
no longer exists in this repo's layout, while `mcp.json` validates against AIR's published schema.
The local file is a convenience copy for offline validation.
:::

## Secrets never touch the catalog

```mermaid
flowchart LR
    CAT["mcp.json (in git)<br/>env: { API_KEY: '${MY_API_KEY}' }"]
    SL["SecretsLoader.all<br/>Rails credentials → mcp_secrets<br/>+ XOauthTokenVendor + ENV"]
    AIR["air prepare<br/>@pulsemcp/air-secrets-env transform"]
    OUT[".mcp.json in the clone<br/>env: { API_KEY: 'sk-real-value' }"]
    VAL{"any ${VAR}<br/>left?"}
    FAIL["FAIL the prepare<br/>→ SecretResolutionError"]

    CAT --> AIR
    SL -->|"subprocess env"| AIR
    AIR --> VAL
    VAL -->|yes| FAIL
    VAL -->|no| OUT
```

The catalog carries the placeholder. The environment carries the value. The transform joins
them at prepare time, and AIR then validates that no `${VAR}` survived and fails if any did.

That validation is the good part: a typo'd secret name fails loudly at prepare, before the agent
ever gets a server that 401s on every call.

Zimmer's `SecretsLoader` resolves values in this order: `XOauthTokenVendor` (for X/Twitter tokens)
→ Rails encrypted credentials (`mcp_secrets`) → `ENV`.

## Selection is per session

A session's server list is seeded from the agent root's defaults and then owned by the session.
The UI and the API (`PATCH /api/v1/sessions/:id/mcp_servers`, max 50) mutate it directly, and `air
prepare` runs with `--without-defaults` so AIR won't re-add what you removed.

Beyond the ones you pick, a session also gets **auto-injected** servers — most notably the
self-session server (`SelfSessionInjector`), which is how an agent can archive itself, set its own
title, or schedule its own wake-up. `session_json` exposes three fields for this:
`mcp_servers` (what you chose), `injected_mcp_servers`, and `all_mcp_servers`.

The injected servers are Zimmer's own: streamable-HTTP entries pointing at this instance's native
`/mcp` endpoint (`zimmer-self-session`, and `zimmer` for roots with `default_subagent_roots`).
Zimmer synthesizes them rather than resolving them from the catalog, and retargets any `zimmer*`
entry at the instance preparing the session so a staging session never orchestrates production.

The catalog also carries `zimmer*` entries you attach deliberately, each scoped to a tool group:
`zimmer-sessions`, `zimmer-fleet`, and `zimmer-gate-decisions` (the [gate decision
ledger](/operate/gate-decisions/) — separate from `zimmer-sessions` on purpose, so that carrying
session orchestration does not carry the ability to write gate ratings). `gate_decisions` is an
opt-in tool group, so `zimmer-gate-decisions` is the *only* entry that reaches the ledger tools:
the unscoped `zimmer` entry does not carry them. `zimmer-work-backlog` is the same shape for the
[work backlog](/operate/work-backlog/): `work_backlog` is opt-in, and that entry is the only one
that can append to the queue or pull from it.

→ [Zimmer's MCP server](/extend/mcp-server/) for the tool surface, the scoped variants, and auth.

## Availability, and what an agent is offered

A catalog entry that cannot start is not a soft failure. `SecretsInterpolator` raises
`MissingVariableError` on an unresolved `${VAR}` at spawn, and nothing rescues it per entry — so
attaching one such server fails the **whole session**, not just that server.

`ConnectorStatusProbe` answers "could a session attach this right now?" from local signals only:
whether each required `${VAR}` resolves, and the state of the stored OAuth credential. Four of its
states block a spawn — `missing_configuration`, `needs_authorization`, `needs_reauth`, and
`declared_unavailable` (the `unavailable` field above). `token_expired` does not, because
`RefreshMcpOauthTokensJob` renews it unaided.

Every surface that offers a server reads that one computation:

- **[The Connectors page](/auth/mcp-oauth/#seeing-where-every-connector-stands)** renders every
  server with its state and what to do about it.
- **`get_configs`** — what an agent reads as "your options" — lists only the servers that can start,
  then names the rest in a short **Unavailable** roster, one line each with a compact reason. The
  roster is not a second catalog: it exists so an agent can tell *this server exists and is broken*
  from *this server does not exist*, the latter being an invitation to go and register a duplicate.
  A root default that is currently unavailable is marked `(unavailable)` in the root's own listing,
  since that list is otherwise copied into `start_session` verbatim.
- **The MCP-server pickers** on the new-session form, the trigger form and the session detail page
  show an unavailable server with an **Unavailable** badge and its reason, sorted below the ones
  that work. `McpServerOptions` builds that payload.
- **`GET /api/v1/configs` and `GET /api/v1/mcp_servers`** carry `unavailable` (a boolean) and
  `unavailable_reason` (a short string, `null` when startable) on every server.

### Why the pickers flag and `get_configs` omits

The two surfaces express the same fact in the idiom of their reader, and the difference is
deliberate.

An agent's list is a menu of things it may pass to `start_session`, and an agent can fix none of the
reasons a server is unavailable — it cannot seed a secret or complete an OAuth consent. Leaving an
unusable option in that menu only invites the failure, so `get_configs` takes it out and compensates
with the roster.

A human can fix most of them: "OAuth authorization not completed" is one click away at
`/connectors`, and "`FOO_TOKEN` unresolved" names the variable to set. For that reader a silent
absence is worse than a flagged entry — a server that vanishes from the picker reads as a broken
catalog, not as a credential to go and seed. So the picker keeps the entry, says why, and sorts it
last.

The picker does not *refuse* the pick. This is the read path: the list's job is to say. Rejecting or
warning on a selection that names an unavailable server is a separate question about the write path.

Neither surface ever filters on `store_unavailable` or `probe_failed` — see below.

Two signals are deliberately **not** on this path. Nothing here contacts an MCP server, so
`get_configs` stays fast and deterministic on a routing session's critical path, and a Ready badge
never claims the remote host answered. And a probe that could not determine an answer —
`store_unavailable` when the Parameter Store did not respond, `probe_failed` for anything unexpected
— leaves the server **listed**. Those are transient and hit every server at once; emptying the whole
option list because Google was slow is a worse failure than offering a server that might not start.

## When a server cannot connect, the server is left out — not the session

A handshake that fails is a lost *capability*, not a lost session. `AgentSessionJob#check_and_handle_mcp_failure`
classifies the failure and takes one of three routes:

| Failure class | What happens |
| --- | --- |
| An **OAuth-capable** server needs authorization | `session.fail!` with `failure_reason: oauth_required`. The one fatal class, because a human clicking Authorize is the fix. |
| Anything else, first three times | The retry ladder: `RetryBudget::MCP_CONNECTION` (3 attempts), backing off 30s / 60s / 120s. Most connect failures are transient — a server still starting after a deploy, an `npx` cache race — and self-heal here. |
| Anything else, definitively | The server is **left out** and the session runs on. Also taken immediately, with no retries, for a static credential the provider rejected: a wrong API token does not become right in 30 seconds. |

"A static credential the provider rejected" is read from two places, because a server can name the
rejection in words the transport's own error never carries. A stdio server that runs a credential
health check at startup and exits when it fails hands the runtime nothing but `Connection closed`;
what the provider actually said is only in the text the server printed on its **own stderr**, which
`McpLogPollerService` folds into the same error blob, joining every entry it saw with `" | "`:

```
Server stderr: BrightData: Invalid API key - authentication failed | Connection failed after 3941ms (CONNECTION_CLOSED): Connection closed
```

So the classifier reads that blob twice. The broad `AUTH_ERROR_PATTERN` (`401`, `unauthorized`,
`oauth`, `invalid_token`) covers what the transport says. A much narrower check covers what the
child process said: a `Server stderr:` marker **and** a phrase whose whole meaning is "the
credential was refused" (`invalid api key`, `authentication failed`, `bad credentials`), both in the
**same** joined segment — otherwise a transport-level `Connection failed: authentication failed`
sitting beside an unrelated stderr line would read as something the server never reported.

Both narrowings are deliberate, because a false positive here fails silently: it stops retrying a
server that would have connected, and nothing errors. So the stderr check never fires on the broad
pattern's words, and it never routes to the fatal `oauth_required` branch — an OAuth-capable server
keeps the ladder ([#645](https://github.com/tadasant/zimmer/issues/645)).

Leaving a server out means:

- It is marked `failed` in `mcp_servers_status`, so the session page and the JSON consumers show it red.
- It is recorded in `metadata["mcp_degraded_servers"]` with its error, and `AgentSessionJob#build_prompt_with_goal`
  renders that into an `<unavailable-mcp-servers>` block on **every** subsequent prompt — so the agent is told
  the tools are gone rather than discovering it from a tool call that is not there. The block tells it to stop
  and say so if it genuinely needs the missing capability, rather than improvising a substitute.
- The session is resumed with a `SYSTEM_RECOVERY` nudge, which preserves its scheduled wake-ups. A session whose
  runtime never started ignores the nudge and runs its original prompt instead.
- Nothing is rewritten in `.mcp.json`. The server stays configured, so if whatever broke it is fixed the next
  spawn reconnects for free. The record exists so the *same* server failing again is a no-op instead of another
  terminate-and-resume.

The record is retired by exactly one thing: `McpStatusPersisting` sees that server report `connected` again. That is
the only signal that is actually true about the outage being over, and it re-arms the ladder if the server fails
again later. In particular `mcp_degraded_servers` is deliberately **not** in `Session::STALE_RETRY_METADATA_KEYS` —
those keys are cleared by every automatic recovery path (a deploy sweep, an orphan sweep, an auth-outage park
lifting), and a write-off that vanished on a deploy would let the still-dead server burn the whole ladder again
while the agent silently stopped being told it had lost the capability.

Before this, exhausting the ladder killed the session. A last-resort fallback server the session had never called
— and never would have — could orphan two hours of completed work on a stale credential belonging to something
else entirely ([#521](https://github.com/tadasant/zimmer/issues/521)). An agent that genuinely needs the missing
capability can now say so and stop, which is a far cheaper failure than losing the transcript.

## Remote servers and OAuth

A remote server (`http` / `streamable-http` / `sse`) with no static `Authorization` header is assumed
to possibly need OAuth. Before spawn, `McpOauthCredentialInjector` checks each one; if any lacks a
valid credential, the session is parked in `failed` with `failure_reason: oauth_required`, and
the UI renders Authorize buttons.

→ [MCP server OAuth](/auth/mcp-oauth/) for the full flow.

:::tip[Prefer a remote server to a stdio one that wants an API token]
A remote server Zimmer authorizes over OAuth holds a short-lived token it rotates for you. A stdio
server with `env: { "FOO_API_KEY": "${FOO_API_KEY}" }` holds a long-lived one that sits in the
agent's environment for the life of the session, where it can end up in a log or a transcript.
[**Strad**](https://strad.tadasant.com) is the remote-MCP platform built to pair with Zimmer.

→ [Prefer remote MCP servers to long-lived API tokens](/auth/overview/#prefer-remote-mcp-servers-to-long-lived-api-tokens)
:::

## MCP connection status is inferred from logs

There is no protocol-level "did this server connect" signal that Zimmer consumes. Instead:

- **Claude**: `McpLogPollerService` scrapes the CLI's MCP log files.
- **Codex**: `CodexMcpStatusDetector` string-matches tool names against `codex-rs`'s
  `MCP_TOOL_NAME_DELIMITER = "__"`, and reimplements Codex's internal
  `sanitize_responses_api_tool_name` character rules in Ruby.

:::caution[Reimplementing another project's private internals]
That Codex detector is a Ruby port of a Rust function that is not a public API. If Codex changes its
tool-name sanitization, Zimmer's MCP status display silently goes wrong.

A related bug was fixed only recently: sessions whose root had no MCP servers of its own but which
got auto-injected ones would show "pending" forever in the UI even though the server was connected
and serving tools.

Tracked in [#63](https://github.com/tadasant/zimmer/issues/63).
:::

## Timeouts and caching

- **Three minutes to start**, for every MCP server, on Claude and Codex. The budget is one number
  — `McpStartupTimeout::SECONDS` — written in each runtime's own idiom, because they share no
  mechanism. Claude reads `MCP_TIMEOUT=180000` off the agent process's environment
  (`ClaudeSpawnEnv#configure_mcp_env`), which reaches every server it spawns. Codex has no such
  variable: it reads `startup_timeout_sec` out of each `[mcp_servers.*]` table, so
  `CodexConfigTomlPostProcessor` writes `startup_timeout_sec = 180` onto every **stdio** entry.
  HTTP entries get none — they reach a server that is already running, and a longer budget there
  would only delay reporting a URL that is simply unreachable.
- Codex's own default is 30 seconds, measured against the pinned `@openai/codex@0.146.0` binary:
  a stdio server that never answers delays the first model request by 29.9s over the
  no-server baseline, and `startup_timeout_sec = 5` moves the same measurement to 5.1s. That is
  the whole exposure — the cold clone below is guaranteed by the cache pinning, and installing all
  nine npx servers at once into one fresh clone cache takes 18s for the slowest on an idle
  production droplet. Under 2x margin, on the runtime where running out means the server is
  dropped rather than merely slow ([#702](https://github.com/tadasant/zimmer/issues/702)).
- The wider budget has a cost, and it is the one Claude already pays: a server that hangs holds
  the handshake for three minutes instead of thirty seconds, on every launch, since Zimmer
  respawns stdio servers per run. A slow start is recoverable and a dropped server is not, so
  that is the trade taken deliberately.
- **Pi gets neither.** `PiRuntimeAdapter` exports no timeout variable, and nothing Zimmer writes
  into the `.mcp.json` that `PiMcpConfigPostProcessor` seeds is read as one — yet those seeded
  entries are stdio `npx` servers on the same clone-scoped cold cache. Tracked in
  [#844](https://github.com/tadasant/zimmer/issues/844).
- A config entry that already carries `startup_timeout_sec` (or the deprecated
  `startup_timeout_ms` Codex folds into the same field) keeps its own value. A `mcp.json` catalog
  entry cannot express one — AIR's server schema has no such field — so what this preserves in
  practice is a timeout a repo wrote into its own checked-in `.codex/config.toml`, which AIR
  merges around rather than replaces.
- One flat number for every server is the coarse answer; per-server configurability is tracked in
  [#113](https://github.com/tadasant/zimmer/issues/113).
- Every server whose `command` is `npx` gets `NPM_CONFIG_CACHE` written into **its own `env` table**
  by `RuntimeConfigPostProcessor`, pointing at the clone's `.npm-cache`. So `npx` MCP servers in
  *different* sessions never fight over a shared cache. The match is exact: `sh -c "npx …"`, an
  absolute `/usr/bin/npx`, `npm exec`, `bunx` and `pnpm dlx` are out of scope and keep whatever cache
  they inherit. Every catalog entry uses the bare form.
- It is written per entry rather than inherited from the agent process on purpose. Codex never sets
  the variable — `CodexRuntimeAdapter`'s spawn env has none, and Codex builds each stdio server's
  environment from a fixed whitelist plus exactly what the entry's own `env`/`env_vars` name — so
  before this, every npx MCP server under Codex resolved against npm's user-level `~/.npm/_npx`,
  shared by every session on the host and outside every clone-scoped mechanism below. `ENOTEMPTY …
  rename` on `/home/rails/.npm/_npx/<hash>/node_modules/playwright` is what two concurrent sessions
  installing into one host-wide tree looks like
  ([#595](https://github.com/tadasant/zimmer/issues/595)). Claude does export the variable, but a
  config generator relying on inheritance is the wrong shape either way.
- Within one session two servers can still collide, because `npx` keys its install directory on the
  package spec alone: two servers running the byte-identical `npx -y <pkg>@latest` resolve to the same
  `_npx/<hash>` and, on a cold clone, race to populate it. `NpxCacheIsolator` finds those servers at
  config-write time and gives each its own `NPM_CONFIG_CACHE` under
  `.npm-cache/isolated/<server>/`, so there is nothing to race over. Servers that don't share a
  package share the clone's `.npm-cache`, so tarballs are still downloaded once. Both answers come
  from `NpxCacheLayout`, the one place that knows where a clone's npm caches live — the isolator
  writes those paths, the heal, clear and bin-permission mechanisms below walk them, and none of
  them can drift about which roots exist.
- A catalog entry that sets `NPM_CONFIG_CACHE` itself keeps its value — that is the operator's call.
- `NpxCacheHealService` exists to detect and delete a corrupted `_npx` cache — by matching npm's
  error text (`ENOTEMPTY`, `ERR_UNSUPPORTED_DIR_IMPORT`). An entire service that self-heals a
  filesystem bug by regexing stderr. It is the repair half; the isolator above is the prevention
  half, and healing still covers corruption from causes Zimmer can't see coming.
- `NpxBinExecutableGuard` runs on the way into every **Claude** MCP spawn and restores the execute bit
  on any `_npx/*/node_modules/.bin` target that has none. Some packages publish their entrypoint as
  `-rw-r--r--` and rely on npm's bin-linking to `chmod` it; when that does not land, the server dies
  on `exec` with `EACCES` identically on every retry, so the server is left out for the life of the
  clone ([#467](https://github.com/tadasant/zimmer/issues/467)). It sweeps every cache root the
  layout knows about — the shared one and each isolated root — because the two servers that get
  isolated in practice both run `onepassword-mcp-server`, the package whose published tarball ships
  its entrypoint `-rw-r--r--` ([#498](https://github.com/tadasant/zimmer/issues/498)). Each root is
  its own containment boundary, checked twice: a root that resolves outside the clone is not walked
  at all, and within a root a shim that resolves outside it is refused rather than chmod'ed. Codex sessions are not covered — see
  [Limitations](/limitations/#the-npx-bin-permission-repair-only-reaches-claude-sessions-and-only-on-the-next-launch).
- `MCP_PACKAGE_REINSTALL` and `Dockerfile.base`'s `bin/preinstall-mcp-packages` pre-warm the python
  packages listed in `mcp.json`, and `npm install -g` the npm ones. The npm half no longer helps an
  MCP server: `NPM_CONFIG_CACHE` moves the *whole* npm cache into the clone, `_cacache` included, so
  a cold clone pays the registry download for every npx server, on every runtime. The startup
  budget above is the headroom that absorbs it — see
  [Limitations](/limitations/#a-cold-clone-pays-the-npm-download-for-every-npx-mcp-server).

## The fourteen that ship

`playwright-custom` (the only one default-on, for the `zimmer` root), `context7`, `linear`, and
eleven others. Read `mcp.json` for the current list — it changes more often than this page will.
