# Events (OpenTranscripts v0.1)

The nine event types that go inside `Transcript.events[]`. The `Transcript` wrapper is documented in [`transcript.md`](./transcript.md).

## Shared event base

Every event carries these fields:

```jsonc
{
  "id":           "evt_01HXYZ...",   // stable, unique within the Transcript
  "parent_id":    null,              // string | null — the previous event in conversational order
  "ts":           "2025-05-13T16:00:01Z",
  "type":         "UserMessage",     // discriminator — one of the 9 types below
  "provider_raw": { /* opaque */ }   // original vendor-shape, post-redaction; null when not preserved
}
```

### Base fields

#### `id` — `string`

**What:** Stable per-event identifier, unique within this Transcript. ULIDs preferred.

**Tag:** `[conv]`

**Citation — Pi `SessionEntryBase`:**
> `interface SessionEntryBase { type: string; id: string; /* 8-char hex ID */ parentId: string | null; timestamp: string; /* ISO timestamp */ }`

**Citation — OpenAI Chat Completions:** Every `tool_calls[].id` requires a stable id readable across messages (`tool_call_id` references it in subsequent tool messages). Same idea, generalized to every event.

---

#### `parent_id` — `string | null`

**What:** The id of the event this one logically follows. For a strictly linear transcript, this is "the previous event in `events[]`." For branched flows (Pi's tree, future OT support for branching), `parent_id` is the actual graph parent. `null` for the first event.

**Tag:** `[conv]`

**Citation — Pi `SessionEntryBase`:**
> `parentId: string | null;  // Parent entry ID (null for first entry)`

**Citation — Pi `session-format.md`:**
> "Session entries form a tree structure via `id`/`parentId` fields, enabling in-place branching without creating new files."

For v0.1 we encode `events[]` as a linear array (`parent_id` is just "the prior event's id"), but we keep the field so a future branching mode is additive, not breaking.

---

#### `ts` — `string` (RFC 3339)

**What:** When this event happened, ISO 8601, UTC.

**Tag:** `[conv]`

**Citation — Pi `SessionEntryBase`:** `timestamp: string; // ISO timestamp`

**Citation — Codex `RolloutLine`:** `pub struct RolloutLine { pub timestamp: String, ... }`

---

#### `type` — `string` (discriminator)

**What:** One of the nine literal values below. Discriminator for the typed union.

**Tag:** `[conv]` — every precedent uses a discriminator field on each line.

**Citation — Pi `session-format.md`:** "Each line is a JSON object with a `type` field."

**Citation — Codex `RolloutItem`:**
> `#[serde(tag = "type", content = "payload", rename_all = "snake_case")] pub enum RolloutItem { SessionMeta(SessionMetaLine), ResponseItem(ResponseItem), Compacted(CompactedItem), TurnContext(TurnContextItem), EventMsg(EventMsg) }`

**Citation — OpenCode message-v2:** The 12 part discriminants: `"text"`, `"patch"`, `"snapshot"`, `"reasoning"`, `"file"`, `"agent"`, `"compaction"`, `"subtask"`, `"retry"`, `"step-start"`, `"step-finish"`, `"tool"`.

---

#### `provider_raw` — `object | null`

**What:** The original vendor-shaped payload (post-redaction) for this event. Lets a curious consumer drop back to the raw CC line. Lossy round-trip is fine if a reader needs vendor-specific detail.

**Tag:** `[ours]`

**Why it's ours and not lifted:** No precedent carries a passthrough field per event — each format *is* the vendor shape. OT generalizes, so we keep the original line accessible. The convention: analyzers never read `provider_raw`; debug tooling and one-off scripts do.

**Generated from CC how:** The original JSONL line, secret-redacted, attached as the event is constructed.

---

## The nine event types

| `type` | Tag | Purpose |
|---|---|---|
| `UserMessage` | `[chat-completions]` | Something the user typed/sent. |
| `AssistantMessage` | `[chat-completions]` | Model-generated content (text only — tool calls are their own event). |
| `Thinking` | `[conv]` | Extended-thinking / reasoning block. |
| `ToolCall` | `[chat-completions]` | Model invoked a tool. |
| `ToolResult` | `[chat-completions]` | Result returned to the model. |
| `SubagentSpawn` | `[conv]` | A `Task`/`Agent` tool call that started a subagent transcript. |
| `Compaction` | `[conv]` | Context was summarized; the tail of `events[]` was replaced. |
| `Error` | `[conv]` | A transcript-level error (API failure, abort, etc.). |
| `SystemEvent` | `[ours]` | Catchall for vendor-specific non-conversation lines we don't yet model first-class. |

---

### 1. `UserMessage`

```jsonc
{
  "type": "UserMessage",
  "id": "...", "parent_id": "...", "ts": "...", "provider_raw": {...},
  "content": [ /* ContentPart[] — see below */ ],
  "attachments": [ /* Attachment[] | omitted */ ]
}
```

**Tag:** `[chat-completions]`

**Citation — OpenAI Chat Completions API (messages):** `role: "user"` with a `content` field that is a string or an array of typed content parts (text, image).

**Citation — Anthropic Messages API:** Same — `role: "user"`, `content` is a string or an array of content blocks.

**Citation — Pi `UserMessage`:**
> `interface UserMessage { role: "user"; content: string | (TextContent | ImageContent)[]; timestamp: number; }`

`content` is always an array in OT (never a bare string) for consistency. See `ContentPart` below.

`attachments` is included when the user attached files/images that aren't represented inline in `content`. Optional; omit when empty.

---

### 2. `AssistantMessage`

```jsonc
{
  "type": "AssistantMessage",
  "id": "...", "parent_id": "...", "ts": "...", "provider_raw": {...},
  "content":     [ /* ContentPart[] — text only; ToolCall lives in its own event */ ],
  "model":       "claude-sonnet-4-6",
  "stop_reason": "end_turn",   // "end_turn" | "stop_sequence" | "max_tokens" | "tool_use" | "refusal" | null
  "usage":       { /* Usage — see below */ },
  "cost_usd":    0.0083                  // number | null
}
```

**Tag:** `[chat-completions]`

**Citation — Anthropic Messages API:**
> Stop reason values: `"end_turn"` — Model naturally completed its response; `"stop_sequence"` — Model hit a custom stop sequence; `"max_tokens"` — Response hit token limit.

(Anthropic also defines `"tool_use"`; we accept that too. Spelling: OT keeps the snake_case literals verbatim.)

**Citation — Pi `AssistantMessage`:**
> `interface AssistantMessage { role: "assistant"; content: (TextContent | ThinkingContent | ToolCall)[]; api: string; provider: string; model: string; usage: Usage; stopReason: "stop" | "length" | "toolUse" | "error" | "aborted"; ... }`

OT differs from Pi in one place: Pi packs `ThinkingContent` and `ToolCall` into the assistant message's `content` array; OT splits them into separate events (`Thinking`, `ToolCall`) because the analysis pipeline treats them as independently-addressable units. The trade-off: Pi's shape is closer to the wire API; OT's shape is easier to walk.

`cost_usd` follows Pi's per-message cost convention:
> `cost: { input: number; output: number; cacheRead: number; cacheWrite: number; total: number }`

We keep only the total to avoid duplicating per-token-bucket pricing; `final_metrics.cost_usd` rolls up.

---

### 3. `Thinking`

```jsonc
{
  "type": "Thinking",
  "id": "...", "parent_id": "...", "ts": "...", "provider_raw": {...},
  "text":      "...",
  "signature": "...",     // string | null — provider continuity signature, when present
  "redacted":  false      // true if the provider returned a redacted_thinking block
}
```

**Tag:** `[conv]`

**Citation — Anthropic Messages API (thinking block):**
> `type: "thinking"`; `thinking: string` — The thinking content; `signature: string` — Signature for multi-turn continuity.

**Citation — Pi content blocks:**
> `interface ThinkingContent { type: "thinking"; thinking: string; }`

**Citation — OpenCode part discriminants:** `"reasoning"` is one of the 12 first-class part types.

OT renames Anthropic's `thinking` field to `text` for symmetry with `UserMessage.content[*].text` / `AssistantMessage.content[*].text`. `signature` and `redacted` preserve the provider-specific signal.

---

### 4. `ToolCall`

```jsonc
{
  "type": "ToolCall",
  "id": "...", "parent_id": "...", "ts": "...", "provider_raw": {...},
  "tool_call_id": "toolu_01ABC...",
  "tool_name":    "Read",
  "arguments":    { /* opaque object — tool-specific schema */ }
}
```

**Tag:** `[chat-completions]`

**Citation — OpenAI Chat Completions API:** Assistant message carries `tool_calls[]`, each with `id` (string), `type: "function"`, and `function: { name: string, arguments: string }`.

**Citation — Anthropic Messages API (tool_use block):**
> `type: "tool_use"`; `id: string` — Tool use ID; `name: string` — Tool name; `input: map[unknown]` — Tool input parameters.

**Citation — Pi content blocks:**
> `interface ToolCall { type: "toolCall"; id: string; name: string; arguments: Record<string, any>; }`

OT picks `arguments` over Anthropic's `input` because OpenAI's name is more widely echoed in coding-agent code (Pi uses `arguments`; OpenCode's tool parts have an `input` field on state but the call ID is `callID`). The semantic is identical: the structured tool input.

`tool_call_id` follows OpenAI's spelling exactly so a `ToolResult` can reference it via the same field name.

`arguments` stays opaque (no schema) — see [`README.md`](../README.md) non-goals.

---

### 5. `ToolResult`

```jsonc
{
  "type": "ToolResult",
  "id": "...", "parent_id": "...", "ts": "...", "provider_raw": {...},
  "tool_call_id": "toolu_01ABC...",
  "output":       [ /* ContentPart[] — usually a single text part */ ],
  "is_error":     false
}
```

**Tag:** `[chat-completions]`

**Citation — Anthropic Messages API (tool_result block):**
> `type: "tool_result"`; `tool_use_id: string` — ID of the tool use being responded to; `content: optional string or array` — Tool result content; `is_error: optional boolean` — Whether the tool call resulted in an error.

**Citation — Pi `ToolResultMessage`:**
> `interface ToolResultMessage { role: "toolResult"; toolCallId: string; toolName: string; content: (TextContent | ImageContent)[]; details?: any; isError: boolean; timestamp: number; }`

OT uses `tool_call_id` (OpenAI spelling) rather than Anthropic's `tool_use_id` for symmetry with the `ToolCall.tool_call_id` field. The semantic is identical. `output` instead of `content` to mirror the natural "call → result" framing.

---

### 6. `SubagentSpawn`

```jsonc
{
  "type": "SubagentSpawn",
  "id": "...", "parent_id": "...", "ts": "...", "provider_raw": {...},
  "tool_call_id":         "toolu_01ABC...",  // the parent ToolCall that spawned this subagent
  "spawned_transcript_id": "agent_xyz...",   // matches subagents[].transcript_id
  "subagent_type":         "Explore",        // string | null — vendor-specific routing tag
  "description":           "Find all auth middleware",  // short description / prompt summary
  "prompt":                "..."             // full prompt passed to the subagent; may be long
}
```

**Tag:** `[conv]`

**Citation — OpenCode `SubtaskPart`:**
> "SubtaskPart contains `prompt`, `description`, `agent`, optional `model` (with `providerID`/`modelID`), and optional `command`."

**Citation — Pi `session-format.md`:** Pi's `parentSession` on the header (`{"parentSession":"/path/to/original/session.jsonl"}`) is the same idea, but path-based rather than id-based.

**Citation — Claude Code JSONL (empirical):** A `Task` tool call (`{"type":"tool_use","id":"toolu_...","name":"Task","input":{"subagent_type":"Explore","description":"...","prompt":"..."}}`) followed by a `tool_result` whose `toolUseResult.agentId` names the spawned session file. We hoist these fields to first-class because subagent spawns are central to coding-agent analysis.

`tool_call_id` is the original `Task` tool_use id from the parent transcript. `spawned_transcript_id` is the child's `Transcript.transcript_id`. Together they form the bidirectional link between parent's `events[]` and parent's `subagents[]`.

---

### 7. `Compaction`

```jsonc
{
  "type": "Compaction",
  "id": "...", "parent_id": "...", "ts": "...", "provider_raw": {...},
  "summary":             "User asked about X, Y, Z. We did A, B, ...",
  "first_kept_event_id": "evt_01HABC...",   // null if all prior events were dropped
  "tokens_before":       50000,
  "tokens_after":        12000,
  "trigger":             "auto"             // "auto" | "manual" | null
}
```

**Tag:** `[conv]`

**Citation — Pi `CompactionEntry`:**
> `{"type":"compaction","id":"...","parentId":"...","timestamp":"...","summary":"User discussed X, Y, Z...","firstKeptEntryId":"...","tokensBefore":50000}`

**Citation — Pi `CompactionSummaryMessage`:**
> `interface CompactionSummaryMessage { role: "compactionSummary"; summary: string; tokensBefore: number; timestamp: number; }`

**Citation — Codex `CompactedItem`:**
> `pub struct CompactedItem { pub message: String, #[serde(default, skip_serializing_if = "Option::is_none")] pub replacement_history: Option<Vec<ResponseItem>> }`

**Citation — OpenCode part discriminants:** `"compaction"` is a first-class part type.

OT keeps Pi's `firstKeptEntryId` (renamed `first_kept_event_id`) because it's the cleanest representation of "what gets thrown away vs kept" — the field points at the first event of the *kept tail*, and everything before it has been replaced by `summary`. We add `tokens_after` (Pi only has `tokensBefore`) to make the compression ratio explicit, and `trigger` to distinguish auto-compact from user-invoked `/compact`.

---

### 8. `Error`

```jsonc
{
  "type": "Error",
  "id": "...", "parent_id": "...", "ts": "...", "provider_raw": {...},
  "code":             "rate_limit_exceeded",   // string | null — provider error code
  "message":          "...",
  "recoverable":      true,                    // bool — whether the agent retried after this
  "related_event_id": "evt_01HXYZ..."          // string | null — the event this error pertains to
}
```

**Tag:** `[conv]`

**Citation — Pi `AssistantMessage` error fields:**
> `stopReason: "stop" | "length" | "toolUse" | "error" | "aborted"; errorMessage?: string;`

Pi attaches error info to the failing assistant message. OT promotes it to a first-class event so transcript-level errors (network failures, abort signals, rate limits that don't produce an assistant message) have a place to live.

**Citation — Claude Code JSONL (empirical):** CC emits assistant lines with content like `[{"type":"text","text":"API Error: ..."}]` plus internal error markers. We map those to `Error` events.

`related_event_id` links to the event that triggered or was interrupted by the error (e.g., a `ToolCall` that failed at the transport layer before yielding a `ToolResult`).

---

### 9. `SystemEvent`

```jsonc
{
  "type": "SystemEvent",
  "id": "...", "parent_id": "...", "ts": "...", "provider_raw": {...},
  "subtype": "permission_mode_change",   // string — vendor-specific subtype
  "payload": { /* opaque, vendor-shape */ }
}
```

**Tag:** `[ours]`

**Why it's ours and not lifted:** No precedent has a generic catchall. Pi has 11 distinct entry types (some of which — `LabelEntry`, `CustomEntry`, `SessionInfoEntry`, `ThinkingLevelChangeEntry`, `ModelChangeEntry` — would each warrant promotion to first-class OT events if we had multi-vendor evidence they matter for analysis). Until we do, we collapse them all into `SystemEvent` with a `subtype` discriminator. The convention: analyzers may skip `SystemEvent`s; consumers that care can dispatch on `subtype`.

**Generated from CC how:** Claude Code's JSONL has ~13 non-conversation line types beyond `user` / `assistant`: `system`, `attachment`, `ai-title`, `last-prompt`, `queue-operation`, `permission-mode`, `pr-link`, `file-history-snapshot`, etc. Phase 1 maps each to a `SystemEvent` with `subtype` = the CC line type and `payload` = the redacted line minus the fields hoisted to base.

**Cross-reference (the precedent shape that closest):** Pi's `CustomEntry`:
> `{"type":"custom","id":"...","parentId":"...","timestamp":"...","customType":"my-extension","data":{...}}` — "Extension state persistence. Does NOT participate in LLM context."

`SystemEvent.subtype` and `SystemEvent.payload` mirror Pi's `customType` and `data` shape exactly, just with the conventional name "system" rather than "custom" since these aren't extension-provided in OT — they're vendor system metadata.

If a `SystemEvent.subtype` becomes common enough across vendors (≥3 of {CC, Pi, Codex, OpenCode, Cursor}), it graduates to a first-class event in a future schema_version bump.

---

## Supporting types

### `ContentPart`

```jsonc
// Text
{ "type": "text", "text": "..." }

// Image
{ "type": "image", "data": "<base64>", "mime_type": "image/png" }
```

**Tag:** `[chat-completions]`

**Citation — Anthropic Messages API:** Text block: `type: "text"`, `text: string`.

**Citation — Pi:**
> `interface TextContent { type: "text"; text: string; } interface ImageContent { type: "image"; data: string; /* base64 */ mimeType: string; }`

OT picks Anthropic's snake_case `mime_type` for consistency with the rest of the schema (Pi camelCases; we don't).

### `Usage`

```jsonc
{
  "input_tokens":         18200,
  "output_tokens":         6400,
  "cache_read_tokens":     2100,    // number | null
  "cache_write_tokens":     350     // number | null
}
```

**Tag:** `[chat-completions]`

**Citation — Anthropic Messages API:**
> `usage` object: `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`.

**Citation — Pi `Usage`:**
> `interface Usage { input: number; output: number; cacheRead: number; cacheWrite: number; totalTokens: number; cost: {...} }`

OT shortens Anthropic's `cache_read_input_tokens` / `cache_creation_input_tokens` to `cache_read_tokens` / `cache_write_tokens` (Pi's spelling, more readable). Semantics unchanged. Total tokens are not separately stored — readers sum.

### `Attachment`

```jsonc
{
  "name":      "screenshot.png",
  "mime_type": "image/png",
  "size":      14820,
  "ref":       "file_01HXYZ..."   // string | null — opaque vendor reference
}
```

**Tag:** `[conv]`

**Citation — Pi `session-format.md`:** The `attachment` line type exists in Claude Code and `file` is one of OpenCode's part types (`"file"`).

**Citation — OpenCode message-v2:** `"file"` is one of the 12 part discriminants.

OT keeps attachments as inline metadata on `UserMessage.attachments[]` rather than as their own event because most analyses want them adjacent to the message that referenced them. The `ref` opaquely points at vendor storage if the actual bytes aren't inlined.
