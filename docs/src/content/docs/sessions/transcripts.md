---
title: Transcripts
description: How agent output is captured, normalized into OpenTranscripts, streamed to the UI, and archived — plus subagent transcripts and the regression guard.
sidebar:
  order: 4
---

The agent writes JSONL to a file. Zimmer polls that file, normalizes it, and streams it to your
browser. That's the whole loop. Each step has a wrinkle.

## The pipeline

```mermaid
flowchart LR
    CLI["Agent CLI<br/>writes JSONL to disk"] --> F["~/.claude/projects/…/*.jsonl<br/>or ~/.codex/…/*.jsonl.zst"]
    F --> TS["TranscriptSource<br/>locate → read → parse<br/>(Codex: zstd-decompress)"]
    TS --> TP["TranscriptPollerService"]
    TP --> RG{"transcript<br/>regression?"}
    RG -->|"new file is shorter"| SKIP["refuse to overwrite<br/>log once"]
    RG -->|no| NM["TranscriptNormalizer<br/>→ OpenTranscripts v0.1 events"]
    NM --> SUB["discover agent-*.jsonl<br/>→ SubagentTranscript rows"]
    NM --> MCP["MCP status detector"]
    NM --> HK["Transcript hooks<br/>(GithubPrUrlHook)"]
    NM --> DB[("sessions.transcript<br/>(whole raw file as a string)")]
    NM --> BC["BroadcastService<br/>Turbo Stream → session_&lt;id&gt;_timeline"]
    BC --> UI["Browser"]
```

## OpenTranscripts — the normalization layer

Claude and Codex write completely different JSONL. Rather than teaching the UI both dialects,
Zimmer normalizes into **OpenTranscripts v0.1** (`app/services/open_transcript.rb`), a
vendor-neutral schema vendored from `pulsemcp/ai-artifacts`. Nine event types:

`UserMessage` · `AssistantMessage` · `Thinking` · `ToolCall` · `ToolResult` · `SubagentSpawn` ·
`Compaction` · `Error` · `SystemEvent`

Every one renders through a single partial (`app/views/timeline_items/_item.html.erb`), keyed on
type. One raw JSONL line can fan out into several events.

:::caution[OpenTranscripts is a hand-synced copy, and it diverges]
`docs/OPEN_TRANSCRIPTS.md` (now this page) explicitly said the vendored schema must be manually
kept in sync with upstream — a silent-drift hazard with no test guarding it. Zimmer's copy also
diverges intentionally: no secret redaction, per-line normalization with no cross-line
timestamp carry-forward, and several fields hardcoded to null.

The "no secret redaction" part matters if you ever expose a transcript outside your tailnet.
Tracked in [#51](https://github.com/tadasant/zimmer/issues/51).
:::

## The regression guard

If the clone is recreated, the agent starts a *fresh* transcript file. Naively overwriting
`sessions.transcript` with it would wipe the session's history.

So `Session.transcript_regression?` refuses to overwrite a stored transcript with a shorter one,
and logs it once via `metadata["transcript_regression_detected"]`. If a *resume* hits an
unrepairable regression, the resume is refused outright — because resuming would silently
drop the user's prompt.

That guard existing tells you the underlying condition happens.

## Rotation: when a shorter file is *new*, not lost

The guard above assumes one canonical transcript file per session, which is true for Claude Code
and false for Codex. Codex rollouts are append-only and immutable, and `codex exec` mints a **new**
rollout UUID for every run that is not a resume — so when a resume fails and Zimmer fresh-starts
the turn, the conversation continues in a brand-new, initially tiny file.

`TranscriptSource#rotates_transcript_files?` is what tells the two apart: `false` for Claude
(shorter means *lost*, refuse and repair), `true` for Codex (shorter means *next file*, carry
history forward).

On a rotation the poller folds the whole stored transcript into an immutable prefix and records
its length in `metadata["transcript_carryover_event_count"]`, alongside
`metadata["transcript_source_path"]`. Later polls re-derive the prefix as the first N lines of
what is stored — the stored transcript is always `carryover + live` — so the timeline reads as one
continuous conversation across any number of rotations. Requiring the *path* to change is what
keeps a partially flushed read of the same file from duplicating history.

:::caution[This was a real freeze, not a theoretical one]
Before rotation was handled, a fresh-started Codex session went permanently silent. The live
rollout was shorter than `broadcast_message_count`, so `new_messages[broadcast_count..]` returned
`nil` and nothing broadcast; the regression guard refused to persist and flagged
`transcript_regression_detected` once, silencing the log too. Nothing cleared that state, so the
session streamed stale content until a deploy recreated the clone — which is why sessions appeared
frozen for tens of minutes and then caught up all at once.
:::

The other half of the same failure is the id the poller looks the file up by. Codex mints its own
rollout UUID, so after a fresh start the stored `session_id` names an abandoned rollout;
`ProcessLifecycleManager#release_stale_runtime_session_id!` drops it so
`CodexTranscriptSource#find_main_transcript` falls back to matching on the session's clone path and
finds the live rollout. Without that, the locator kept returning the dead file and
`capture_runtime_session_id!` could never learn the new UUID — it reads that UUID from a file the
locator would never hand it.

## Broadcast bookkeeping

The poller only broadcasts `new_messages[broadcast_count..]`, where `broadcast_count` comes from
`metadata["broadcast_message_count"]` (recomputed from the stored transcript when nil). This is
what prevents the entire transcript from replaying into your browser on every poll.

Note the sharp edge in that expression: Ruby returns `nil`, not `[]`, when the index is past the
end of the array. Any change that can make the parsed transcript *shorter* than `broadcast_count`
therefore stops the timeline dead rather than degrading — which is exactly how the rotation bug
above stayed invisible.

There is also an ownership guard: the poller skips if `session.running_job_id != job_id`,
which is what stops two monitoring jobs from double-broadcasting the same session.

## Subagent transcripts

When an agent spawns subagents (Claude's `Task` tool), each writes its own `agent-*.jsonl`. The
poller discovers them, stores each as a `SubagentTranscript` row, and links it back to the parent
`Task` tool call by matching `tool_use_id` against `toolUseResult.agentId` — filling in
`subagent_type`, `description`, `status`, `duration_ms`, `total_tokens`, and `tool_use_count`.

They render as a nested, collapsible accordion inside the parent's timeline row.

:::caution[Subagent transcripts assume Claude]
`SubagentTranscript#open_transcript_events` hardcodes `ClaudeTranscriptNormalizer`. Codex
subagents, if they produced discoverable transcripts, would be normalized with the wrong parser.
:::

## Transcript hooks

A small Ruby plugin system that runs inside Zimmer (not inside the agent) whenever new
transcript messages are broadcast. Sequential, error-isolated per hook, run after the transcript
is saved. Each hook writes into `session.custom_metadata`.

`GithubPrUrlHook` records the pull requests a session *opened* — read out of `gh pr create` output
or the agent's own "opened PR `<url>`" prose — into `custom_metadata["github_pull_request_urls"]`.
That list is what the GitHub PR poller, the comment poller, and the merge-conflict poller all key
off, so a PR missing from it is invisible to Zimmer, and a PR wrongly on it sends another session's
comments here. `GithubCommentAuthorshipHook` ships alongside it, recording the comments a session
posted so the comment poller never reads one back as if a human wrote it.

→ [Transcript hooks](/extend/transcript-hooks/) for the contract and how to write one.

## Archive and download

`TranscriptArchiveJob` rebuilds a `latest.zip` of all transcripts every 10 minutes (temp file +
atomic rename). It's served by `GET /api/v1/transcript_archive/download`.

## Rendering to plain text

`TranscriptTextRenderer` turns a parsed transcript into a reading copy. One class serves both
surfaces that need one — `GET /api/v1/sessions/:id/transcript` and the `get_session` MCP tool's
`transcript_format: "text"` — because they previously carried separate copies of the same `case`
and drifted apart.

`user`, `assistant`, `tool_use` and `tool_result` get a labelled section each. Every other entry
type is labelled and dumped rather than dropped, so the text never quietly disagrees with the raw
transcript — this matters most for Codex, whose rollout lines are all `session_meta` /
`response_item` / `event_msg` / `turn_context` and would otherwise render as nothing at all.

Content that arrives as an array of blocks is rendered block by block: `text`, `thinking`, `image`,
`tool_use`, `tool_result`, and pretty JSON for anything unrecognized.

Two truncations keep this a summary rather than a second copy of the file: tool results at 500
characters, unrecognized entries at 1,000.

:::danger[Transcripts have no authorization check]
There is none to have. Sessions have no owner and Zimmer has no `User` model, so there is no
principal to check a transcript against — `SessionsController#transcript` says as much in place of
the TODO it used to carry.

Since [the web UI has no authentication at all](/limitations/#the-web-ui-has-no-login-by-design-and-the-sharp-edge-that-follows)
outside the `/supervisor` panel, anyone who can reach the host can read every transcript. Guarding
that is the perimeter's job.
Tracked in [#44](https://github.com/tadasant/zimmer/issues/44).
:::
