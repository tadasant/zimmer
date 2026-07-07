# OpenTranscripts v0.1 (vendored schema reference)

> **Source of truth:** This is a short, vendored copy of the OpenTranscripts
> schema maintained in **pulsemcp/ai-artifacts** (the `open-transcripts` spec
> plus the reference converters `open_transcripts.py` and `cc_jsonl.py`). When
> the upstream schema changes, update this doc **and** `app/services/open_transcript.rb`
> to match. Do not treat this file as authoritative on its own — it exists so Zimmer
> contributors have the field list at hand without leaving the repo.

OpenTranscripts is a vendor-neutral, event-based model for agent transcripts.
Zimmer normalizes both runtimes' native transcript JSONL
(Claude Code and Codex) into a single stream of these events, then renders every
event through one UI partial keyed on the event `type`
(`app/views/timeline_items/_item.html.erb`).

## Transcript envelope

| Field | Type | Notes |
|-------|------|-------|
| `schema_version` | string | `"0.1"` (pinned as `OpenTranscript::SCHEMA_VERSION`) |
| `transcript_id` | string \| null | Stable id for this transcript |
| `parent` | `{transcript_id, spawn_event_id}` \| null | Set for subagent transcripts |
| `agent` | `{name, version, model_default}` | e.g. name `"claude-code"` / `"codex"` |
| `cwd` | string \| null | Working directory |
| `created_at` | string | ts of first event |
| `ended_at` | string \| null | ts of last event |
| `events` | Event[] | Sorted by `ts` ascending (ties by id/order) |
| `subagents` | Transcript[] | Recursive; may be `[]` |
| `final_metrics` | `{total_tokens_in, total_tokens_out, cost_usd, wall_clock_s}` | `cost_usd` is null in the port |
| `provider` | `{vendor, vendor_version, raw}` | `raw` may carry `{unmapped_lines}` or be null |

## Event base (every event)

| Field | Type | Notes |
|-------|------|-------|
| `id` | string | Required, unique within the transcript |
| `parent_id` | string \| null | Parent event id (e.g. ToolCall's AssistantMessage) |
| `ts` | string (RFC3339) | Required, non-null |
| `type` | string | One of the nine discriminators below |
| `provider_raw` | object \| null | The raw source line (minus base fields), when retained |

## The nine event types

- **UserMessage** — `content` (ContentPart[]), `attachments` (omitted when empty)
- **AssistantMessage** — `content` (ContentPart[], text only), `model`, `stop_reason`, `usage` (omitted unless a dict), `cost_usd` (null in the port)
- **Thinking** — `text`, `signature`, `redacted` (bool)
- **ToolCall** — `tool_call_id`, `tool_name`, `arguments`
- **ToolResult** — `tool_call_id`, `output` (ContentPart[]), `is_error` (bool)
- **SubagentSpawn** — `tool_call_id`, `spawned_transcript_id`, `subagent_type`, `description`, `prompt`
- **Compaction** — `summary`, `first_kept_event_id` (null in the port), `tokens_before`, `tokens_after`, `trigger` (`"auto"`/`"manual"`/null)
- **Error** — `code` (null), `message`, `recoverable` (true), `related_event_id` (null)
- **SystemEvent** — `subtype`, `payload`

### ContentPart

- `{type: "text", text}` or
- `{type: "image", data, mime_type}`

### Usage

`{input_tokens, output_tokens, cache_read_tokens, cache_write_tokens}` (all
default 0; `cache_read_tokens` ← `cache_read_input_tokens`, `cache_write_tokens`
← `cache_creation_input_tokens`).

## Claude Code → OpenTranscripts mapping (summary)

One Claude Code JSONL line can fan out into several events:

- **assistant** line → one `AssistantMessage` (text content only), then one
  `Thinking` per thinking block, then per `tool_use` block a `ToolCall` (and an
  additional `SubagentSpawn` when the tool is `Task`/`Agent`). The
  AssistantMessage id is the bare line uuid; the other events use suffixed ids
  (`<uuid>:thinking:N`, `<uuid>:tool:N`, `<uuid>:spawn:N`) and set `parent_id`
  to the AssistantMessage id.
- **user** line with `tool_result` blocks → one `ToolResult` per block (no
  UserMessage). Otherwise → one `UserMessage`.
- **system** line with subtype `compact_boundary` → `Compaction`. Other system
  lines that look like errors → `Error`; otherwise → `SystemEvent`.
- Any other line type → `SystemEvent` (subtype = the line's `type`, or
  `"unmapped"` with the line appended to `provider.raw.unmapped_lines`).

Subagent linkage uses the `tool_use_id` (`toolu_…`) to connect a parent's
`Task`/`Agent` `tool_use` block to the spawned `agent-<agentId>.jsonl`
transcript.

## Zimmer fidelity notes (intentional differences from the reference converter)

- **No secret redaction.** The Python reference applies a `redact()` pass to
  content and `provider_raw`. Zimmer renders raw content exactly as it always has,
  so the port omits redaction.
- **Per-line normalization, no cross-line `ts` carry-forward.** Zimmer normalizes
  one source line at a time (to fit its incremental broadcast pipeline). A line
  missing a parseable timestamp falls back to the session's `created_at` rather
  than carrying forward the previous line's `ts`.
- **`first_kept_event_id`, `code`, `related_event_id`, `cost_usd`** are null in
  the port (matching the reference), and `recoverable` is always `true` for
  derived `Error` events.
