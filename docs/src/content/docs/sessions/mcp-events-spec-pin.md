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
| `events/subscribe` (webhook), with client-generated `whsec_` secret, `cursor` and `ttlMs` | `McpEvents::Client#subscribe`, held by `McpEventSubscriptionsJob`: asks for six hours, refreshes before `refreshBefore` with the last cursor |
| `events/unsubscribe` | `McpEvents::Client#unsubscribe` when a condition is disabled, edited or deleted; `NotFound` counts as done |
| Webhook delivery: Standard Webhooks signature, 5-minute timestamp window, multi-signature rotation | `Webhooks::StandardWebhooksSignature`, checked against the Standard Webhooks reference vector |
| `X-MCP-Subscription-Id` | Recorded; Zimmer routes by a token in the callback path instead, so it never needs it to pick the secret |
| Dedupe on `webhook-id` | `webhook_deliveries`, source `mcp_events` |
| Dedupe on `eventId` scoped to the subscription | The same `mcp:<server>:<eventId>` claim per condition the poll takes, so push and poll share it |
| Endpoint verification | **Challenge echo only** (`verification` envelope). No well-known document, allowlist or out-of-band registration |
| `gap` / `terminated` envelopes | Cursor kept / subscription re-created on the next sweep |
| `410` for a delivery not wanted | Sent for a condition disabled or edited and not yet unsubscribed |
| `deliveryStatus` | `active: false` shows the condition as `suspended`; only the SEP's `lastError` categories are shown |
| `v1a,` (ed25519 server identity) | **Not verified**; skipped, as the SEP allows |
| `notifications/events/list_changed` | **Not implemented.** The six-hourly sweep re-reads `events/list` |

## Deliberate deviations

- **The poll cursor seeds the first webhook subscribe.** The SEP keeps the two modes' cursors
  separate in principle. Zimmer passes the condition's poll cursor on the first `events/subscribe`,
  then persists the webhook subscription's own cursor apart from the poll's. strad uses one cursor
  space for both modes, so this is exact there. A server whose poll cursors mean nothing in webhook
  mode should answer `truncated` and start from now. The poll catches up either way.
- **Refreshes are hourly, not only before `refreshBefore`.** The SEP has a client refresh before
  expiry. Zimmer also refreshes every hour, because a suspended subscription resumes only on a
  refresh and `deliveryStatus` is read only there.

- **The protocol revision.** The extension is defined for 2026-07-28 and `server/discover`. The
  client initializes at 2025-06-18 and reads the extension off `initialize`, because that is where
  strad declares it. The per-request client capability goes in `_meta` on every `events/poll` all
  the same.
- **`Mcp-Name` for a non-ASCII name.** The draft calls for a Base64 sentinel form. Zimmer instead
  refuses to poll a name outside printable ASCII (`McpEvents::NAME_FORMAT`).

## Changelog

- **2026-11-11, still `b08e4f9`.** The SEP has not moved since the pin. Webhook mode
  (`events/subscribe`, `events/unsubscribe`, signed delivery, challenge echo) was implemented against
  the same revision. No drift to classify.
