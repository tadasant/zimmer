# Transcript (OpenTranscripts v0.1)

A `Transcript` is a single self-contained JSON document representing one agent session — its events, its subagents (recursively), and a small envelope of metadata. This is what phase 1 of `agent-transcript-analysis` emits; everything downstream consumes it.

This page covers the top-level wrapper. The event shapes inside `events[]` are in [`events.md`](./events.md).

## Top-level shape

```jsonc
{
  "schema_version": "0.1",
  "transcript_id":  "01HXYZ...",
  "parent":         null,                 // or { transcript_id, spawn_event_id }
  "agent":          { "name": "claude-code", "version": "1.x", "model_default": "claude-sonnet-4-6" },
  "cwd":            "/Users/me/projects/foo",
  "created_at":     "2025-05-13T16:00:00Z",
  "ended_at":       "2025-05-13T16:42:31Z",
  "events":         [ /* Event[] — see events.md */ ],
  "subagents":      [ /* Transcript[] — recursive, same shape */ ],
  "final_metrics":  { "total_tokens_in": 18200, "total_tokens_out": 6400, "cost_usd": 0.41, "wall_clock_s": 2551 },
  "provider":       { "vendor": "claude-code", "vendor_version": "1.x", "raw": { /* opaque */ } }
}
```

Empty fields use `null` (typed objects), `[]` (arrays), or are omitted (truly optional). No field carries `undefined`.

## Field-by-field

Every entry below is in the form: **what**, **tag**, **citation quote**, and, when the tag is `[ours]`, **why it's ours and not lifted**.

---

### `schema_version` — `string`

**What:** The OpenTranscripts schema version this document conforms to. `"0.1"` for v0.1.

**Tag:** `[conv]` — schema versioning is universal across the precedents.

**Citation — Pi `session-format.md`:**
> "Sessions have a version field in the header: **Version 1**: Linear entry sequence (legacy, auto-migrated on load); **Version 2**: Tree structure with `id`/`parentId` linking; **Version 3**: Renamed `hookMessage` role to `custom` (extensions unification)."

**Citation — Codex `RolloutItem`:** The `SessionMeta` variant carries session metadata as the first line of a rollout (`pub enum RolloutItem { SessionMeta(SessionMetaLine), ResponseItem(ResponseItem), Compacted(CompactedItem), TurnContext(TurnContextItem), EventMsg(EventMsg) }`), establishing the "first line is metadata" convention we follow with a wrapper rather than a leading line.

---

### `transcript_id` — `string`

**What:** Stable, unique identifier for this transcript. ULIDs preferred; UUIDs and provider-native ids (e.g., CC's session UUID) are accepted.

**Tag:** `[conv]`

**Citation — Pi `SessionHeader`:**
> `{"type":"session","version":3,"id":"uuid","timestamp":"...","cwd":"/path/to/project"}`

**Citation — Anthropic Messages API:** Every API call yields a message id; this is the same shape applied at the session scope.

---

### `parent` — `{ transcript_id: string, spawn_event_id: string } | null`

**What:** If this transcript is a subagent run, points at the parent transcript and the specific `SubagentSpawn` event in the parent that caused it. `null` for top-level transcripts.

**Tag:** `[ours]`

**Why it's ours and not lifted:** No precedent exposes parent-linkage as a typed object at the transcript wrapper level — they all leave subagent linkage implicit (Pi keeps `parentSession` as a path string; OpenCode's `SubtaskPart` carries the prompt but no explicit parent pointer; Claude Code stores the linkage in per-line `agentId` fields and `tool_use_id`s rather than at the top level). We make it explicit because the analysis pipeline needs a deterministic way to walk a tree of transcripts and resolve "which event in the parent spawned me?" without re-deriving the chain.

**Generated from CC how:** From the canonical 4-field chain in Claude Code's JSONL:
- subagent file: `~/.claude/projects/<proj>/<agentId>.jsonl` — filename *is* the `agentId`
- subagent line: every line carries `"agentId": "<agentId>"`
- parent's `tool_use` for the Agent call: `{"type":"tool_use","id":"toolu_xyz","name":"Task",...}`
- parent's `tool_result`: `{"type":"tool_result","tool_use_id":"toolu_xyz","toolUseResult":{"agentId":"<agentId>"}}`

Phase 1 walks parent → finds Task tool_uses → matches `toolu_xyz` → emits a `SubagentSpawn` event with `spawned_transcript_id = <agentId>` and recurses into that file. The child's `parent.spawn_event_id` is the id of that `SubagentSpawn` event.

**Cross-reference:** Pi has a one-way version of this:
> "For sessions with a parent (created via `/fork`, `/clone`, or `newSession({ parentSession })`): `{...,"parentSession":"/path/to/original/session.jsonl"}`"

Pi's `parentSession` is a path, not a structured id-pair; we keep the id-pair so the wire shape is filesystem-independent.

---

### `agent` — `{ name: string, version: string|null, model_default: string|null }`

**What:** Which agent runner produced this transcript and which model it was configured with by default. Per-message model overrides live on individual `AssistantMessage` events.

**Tag:** `[conv]`

**Citation — Pi `AssistantMessage`:**
> `interface AssistantMessage { role: "assistant"; content: ...; api: string; provider: string; model: string; usage: Usage; stopReason: ... }`

Pi attaches `provider` + `model` to every assistant message. We hoist the *default* to the wrapper (since most sessions don't switch) and keep per-event overrides on `AssistantMessage.model`.

**Citation — OpenCode message-v2:** Tracks `providerID`/`modelID` on the optional `SubtaskPart.model` field, confirming the `{provider, model}` pair as the conventional shape.

---

### `cwd` — `string`

**What:** Working directory the agent ran in. Absolute path. Useful for re-resolving file references in events.

**Tag:** `[conv]`

**Citation — Pi `SessionHeader`:**
> `{"type":"session","version":3,"id":"uuid","timestamp":"2024-12-03T14:00:00.000Z","cwd":"/path/to/project"}`

**Citation — Codex `SessionMeta`:**
> `RolloutItem::SessionMeta(meta_line) => Some(meta_line.meta.cwd.clone())`

---

### `created_at` — `string` (RFC 3339)

**What:** Timestamp of the first event in `events[]`. RFC 3339 / ISO 8601, UTC.

**Tag:** `[conv]`

**Citation — Pi `SessionHeader`:**
> `{"type":"session",...,"timestamp":"2024-12-03T14:00:00.000Z",...}`

**Citation — Codex `RolloutLine`:**
> `pub struct RolloutLine { pub timestamp: String, #[serde(flatten)] pub item: RolloutItem }`

---

### `ended_at` — `string` (RFC 3339) | `null`

**What:** Timestamp of the last event in `events[]`. `null` if the session is unfinished (rare for offline analysis).

**Tag:** `[conv]` — same precedent as `created_at`, just the closing bookend. No precedent emits a dedicated `ended_at` (sessions end implicitly with the last line), but every consumer derives one. We hoist it to avoid every analyzer redoing the work.

---

### `events` — `Event[]`

**What:** The ordered list of events that make up this session. See [`events.md`](./events.md) for the nine event types.

**Tag:** `[conv]`

**Citation — Pi `session-format.md`:**
> "Sessions are stored as JSONL (JSON Lines) files. Each line is a JSON object with a `type` field."

**Citation — Codex `RolloutItem`:**
> `pub enum RolloutItem { SessionMeta(SessionMetaLine), ResponseItem(ResponseItem), Compacted(CompactedItem), TurnContext(TurnContextItem), EventMsg(EventMsg) }`

Every coding-agent transcript format reduces to "ordered list of typed entries." We hold the same shape but as a JSON array on the wrapper rather than JSONL on disk — the wrapper composes better when one document needs to carry many subagents.

---

### `subagents` — `Transcript[]`

**What:** Recursively-nested subagent transcripts. Each entry is a full `Transcript` (same shape, with `parent` populated). May be empty.

**Tag:** `[conv]`

**Citation — OpenCode `SubtaskPart`:**
> "SubtaskPart contains `prompt`, `description`, `agent`, optional `model` (with `providerID`/`modelID`), and optional `command`."

OpenCode's SubtaskPart describes the *spawn* but not the spawned transcript's contents. Pi handles subagent-like flows via the entry tree (`parentSession` + branching). Claude Code keeps each subagent's transcript in a sibling JSONL file. We unify these by embedding the full child `Transcript` rather than referencing it externally — keeps the bundle self-contained.

---

### `final_metrics` — `{ total_tokens_in: number, total_tokens_out: number, cost_usd: number|null, wall_clock_s: number }`

**What:** Roll-up totals across `events[]` and across all `subagents[]` (recursive sum). Provided so downstream analyzers don't have to re-walk the tree to answer "how big was this session?"

**Tag:** `[conv]`

**Citation — Pi `Usage`:**
> `interface Usage { input: number; output: number; cacheRead: number; cacheWrite: number; totalTokens: number; cost: { input: number; output: number; cacheRead: number; cacheWrite: number; total: number } }`

**Citation — Anthropic Messages API:**
> `usage` object with `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`.

Pi attaches `Usage` to every assistant message. We do the same at the per-event level (see `events.md` → `AssistantMessage.usage`) and additionally roll up to `final_metrics` at the wrapper.

---

### `provider` — `{ vendor: string, vendor_version: string|null, raw: object|null }`

**What:** Where this transcript came from and an escape hatch for fields the OT schema doesn't yet model. `raw` holds anything vendor-specific that's worth keeping but isn't first-class.

**Tag:** `[ours]`

**Why it's ours and not lifted:** No precedent has a single "vendor passthrough" field — each format is shipped *by* a single vendor and doesn't anticipate cross-vendor use. OT does, so we need a place to keep CC-specific quirks (e.g., the `attachment` / `ai-title` / `last-prompt` / `queue-operation` / `permission-mode` / `pr-link` / `file-history-snapshot` line types that don't map cleanly into the 9 OT events) without losing them. The convention is: anything `provider.raw[*]` is preserved on round-trip but never read by analyzers.

**Generated from CC how:** Phase 1 sets `vendor = "claude-code"`, `vendor_version` from the `claudeVersion` field if present, and stuffs anything it couldn't map into `raw.unmapped_lines[]` (an array of original JSONL lines, post-redaction).

**Cross-reference:** OpenCode's `metadata` field on tool parts is the closest analogue — "extension state persistence" — but it's per-part, not per-transcript.

---

## Invariants a Transcript must satisfy

- **Event ordering.** `events[]` is sorted by `ts` ascending. Ties broken by `id`.
- **Subagent linkage.** Every `SubagentSpawn` event in `events[]` (or in any descendant's `events[]`) has a corresponding entry in the same level's `subagents[]` whose `parent.spawn_event_id` matches. Conversely, every entry in `subagents[]` has its spawning event reachable in the parent.
- **Recursion is real.** A subagent can have its own subagents. There is no depth limit.
- **`schema_version` consistent.** All transcripts in a tree carry the same `schema_version`.
- **No `undefined`.** Optional fields are omitted or `null`. Empty arrays are `[]`.

## Why not JSONL on disk?

The precedents (Pi, Codex, Claude Code) all use JSONL. We use one JSON document instead because:

1. The bundle has to carry **subagents inline** to be self-contained; JSONL doesn't natively express nesting.
2. A single document with `subagents: Transcript[]` round-trips through any JSON tool unchanged.
3. The size penalty is negligible (events still serialize as compact objects).

A future revision could add a JSONL "flat" mode if streaming becomes a need, but v0.1 is document-oriented.
