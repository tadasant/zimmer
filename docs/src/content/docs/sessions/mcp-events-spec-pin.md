---
title: MCP Events spec pin
description: Which revision of the draft MCP Events extension Zimmer's mcp_event triggers implement, what of it is built, and where it departs from the draft.
---

[`mcp_event` triggers](/sessions/triggers/#mcp_event) implement part of the **MCP Events
extension**, the draft SEP-3415. It is an unmerged proposal that changes week to week. This page is
the pin: the revision the code was written against, which parts of it are built, and where the code
departs from it on purpose. `McpEvents::SPEC_REVISION` holds the same revision.

**Before changing anything under `McpEvents`, `McpEventTriggerPollerJob` or the `mcp_event`
condition, check whether the SEP has moved past this pin.** If it has, bring the code, its tests and
this page up to the latest revision, in the same PR or one before it. Strad is the server half of
the same contract and keeps its own pin (`docs/mcp-events-spec-pin.md` in strad). When the wire
format changes, strad changes first, and Zimmer accepts both shapes for one release.

## Pinned revision

| | |
| --- | --- |
| Proposal | SEP-3415, "Events Extension" (draft, Extensions Track) |
| Revision | `b08e4f9` (head of the proposal on 2026-10-28) |
| Extension id | `io.modelcontextprotocol/events` |

## What is implemented

| Part of the draft | Zimmer |
| --- | --- |
| Capability under `capabilities.extensions["io.modelcontextprotocol/events"]` | Read from the `initialize` result (see deviations) |
| `events/list` with `nextCursor` paging | `McpEvents::Client#list_events`, up to 10 pages |
| `events/poll` (`name`, `arguments`, `cursor`, `maxEvents`) | `McpEvents::Client#poll`, 50 events a request |
| `null` cursor means "from now" | Used to baseline a new condition |
| `hasMore` | Followed for up to 5 pages a tick |
| `nextPollMs` (advisory) | Honoured, clamped to 15 seconds to 15 minutes |
| `truncated` | Reported, and stamped on the condition |
| Dedupe on `eventId` within a subscription | `trigger_event_claims`, keyed `mcp:<server>:<eventId>` per condition |
| `Mcp-Method` / `Mcp-Name` headers | Sent on `events/poll`; `Mcp-Method` on `events/list` |
| Error codes (provisional numbers) | Named in one place, `McpEvents::ERROR_CODES` |
| Payloads are untrusted | `{{event.<field>\|untrusted}}` / `\|id` only; a bare field is refused |
| `events/stream` (push) | **Not implemented** |
| `events/subscribe` / `events/unsubscribe` (webhook) | **Not implemented** |
| `notifications/events/list_changed` | **Not implemented.** The six-hourly sweep re-reads `events/list` |

## Deliberate deviations

- **The protocol revision.** The extension is defined for 2026-07-28 and `server/discover`. The
  client initializes at 2025-06-18 and reads the extension off `initialize`, because that is where
  strad declares it. The per-request client capability goes in `_meta` on every `events/poll` all
  the same.
- **`Mcp-Name` for a non-ASCII name.** The draft calls for a Base64 sentinel form. Zimmer instead
  refuses to poll a name outside printable ASCII (`McpEvents::NAME_FORMAT`).
