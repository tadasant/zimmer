---
title: MCP Events spec pin
description: Which revision of the MCP Events extension (SEP-3415) Zimmer's mcp_event triggers implement, what of it is built, and where it departs from the spec.
---

[`mcp_event` triggers](/sessions/triggers/#mcp_event) implement part of the **MCP Events
extension**, SEP-3415. It merged as Final on 2026-11-19, and the extension can still be revised. This page is
the pin: the revision the code was written against, as a client and, for
[its own sessions' events](/extend/mcp-server/#mcp-events-what-sessions-do-as-events), as a server, which parts of it are built, and where the code
departs from it on purpose. `McpEvents::SPEC_REVISION` holds the same revision.

**Before changing anything under `McpEvents`, `SessionEvents`, `Mcp::EventsExtension`, `McpEventTriggerPollerJob` or the `mcp_event`
condition, check whether the SEP has moved past this pin.** If it has, bring the code, its tests and
this page up to the latest revision, in the same PR or one before it. Strad is the server half of
the same contract and keeps its own pin (`docs/mcp-events-spec-pin.md` in strad). When the wire
format changes, strad changes first, and Zimmer accepts both shapes for one release.

## Pinned revision

| | |
| --- | --- |
| Proposal | SEP-3415, "Events Extension" (status Final, Extensions Track; merged 2026-11-19) |
| Source | `seps/3415-events-extension.md` on `main` of `modelcontextprotocol/modelcontextprotocol`, with a docs copy that has the same body at `docs/seps/3415-events-extension.mdx`. Diff against the landed text from now on, not the closed PR |
| Revision | `bbc31f8` (2026-11-20). The normative text is also published at `specification/beta/events/events.mdx` in `modelcontextprotocol/ext-events`; check both |
| Extension id | `io.modelcontextprotocol/events` |

## What is implemented as a client

| Part of the SEP | Zimmer |
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
| `events/stream` (push), including `heartbeatMs` negotiation and reconnect jitter | **Not implemented** |
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
| `v1a,` (ed25519 server identity), Server Card `signingKeys` / `egressIpRanges` | **Not verified** and the Server Card is not read; skipped, as the SEP allows |
| `notifications/events/list_changed` | **Not implemented.** The six-hourly sweep re-reads `events/list` |
| `x-mcp-header` on an event type's `inputSchema`, mirrored into `Mcp-Param-{Name}` headers on `events/poll`, `events/subscribe` and `events/unsubscribe`; excluding an event type whose annotations break the transport's rules; retry after `HeaderMismatch` (`-32020`) | **Not implemented** (see deviations) |

## What is implemented as a server

Zimmer's `POST /mcp` publishes `session.message` and `session.state_changed`
([what they are](/extend/mcp-server/#mcp-events-what-sessions-do-as-events)).

| Part of the SEP | Zimmer |
| --- | --- |
| Capability under `capabilities.extensions["io.modelcontextprotocol/events"]` | Declared on `initialize`, empty settings (`listChanged` false), only for a connection that can read sessions (`Mcp::EventsExtension`) |
| `-32601` from a server that does not offer it | Yes: no `events/*` method is registered |
| `events/list` | Both event types, one page, `delivery: ["poll"]` |
| `events/poll` (`name`, `arguments`, `cursor`, `maxEvents`, `maxAgeMs`) | `SessionEvents::Feed`; `maxEvents` defaults to 50, at most 200 |
| `null` cursor means "from now" | Yes |
| `hasMore`, `nextPollMs` (5 seconds), `truncated` | Yes; `truncated` past 14 days of retention (what is kept is still served), past a `maxAgeMs` floor that skipped events, or on a cursor from a database whose transaction counter was reset |
| Stable `eventId` | `session:<id>:…`; a retried publish writes one row |
| `Mcp-Name` required on `events/poll` | 400 and `HeaderMismatch` (`-32020`) when missing or wrong |
| `InvalidParams`, `NotFound` (`data.kind`) | Yes |
| `Forbidden` | Not sent. A root a connection may not read is filtered out of its results, so a filter naming one returns nothing |
| `events/stream` (push), `events/subscribe` (webhook) | **Not implemented.** Zimmer's own subscribers are its sessions, and it delivers to those in process |
| `x-mcp-header`, `notifications/events/list_changed` | Not used: no argument is annotated and the event types are fixed |

## Deliberate deviations

- **A parent's subscription is held by Zimmer, not by the parent's runtime.** In the SEP the client owns
  its subscriptions. An agent session cannot hold a cursor between turns, so Zimmer is the client for it:
  the subscription is a `session_event_subscriptions` row written at spawn, and the event is handed to the
  parent's message queue in the transaction that publishes it, not polled.
- **The server answers `initialize`, at whatever revision the client asks for.** The extension is defined
  for 2026-07-28 and `server/discover`; the capability is declared on `initialize`, where Zimmer's own
  client and strad's read it.

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
- **`x-mcp-header` is not read.** The SEP requires a Streamable HTTP client to mirror annotated
  subscription arguments into `Mcp-Param-*` headers. Zimmer sends none. A server that annotates an
  argument would refuse Zimmer's poll with `HeaderMismatch`, and the poller reports it as a failing
  poll. No server Zimmer polls annotates one today; adopt it before pointing a condition at one
  that does.
- **`Mcp-Name` for a non-ASCII name.** The SEP calls for a Base64 sentinel form. Zimmer instead
  refuses to poll a name outside printable ASCII (`McpEvents::NAME_FORMAT`).

## Changelog

- **2026-11-11, still `b08e4f9`.** The SEP has not moved since the pin. Webhook mode
  (`events/subscribe`, `events/unsubscribe`, signed delivery, challenge echo) was implemented against
  the same revision. No drift to classify.
- **2026-11-16, `b08e4f9` → `4165cc2`.** The SEP file moved from `seps/0000-events-extension.md` to
  `seps/3415-events-extension.md`, and the proposal added a docs copy with the same body. Changes,
  classified: status Draft → Accepted (editorial, out of scope); push heartbeat interval negotiation
  (`heartbeatMs` suggested on `events/stream`, granted on `notifications/events/active`, dead stream
  at three times the grant rather than twice the interval, 30 seconds now only the recommended default) and reconnect jitter
  (additive, push only, out of scope: Zimmer has no push); the Server Card members `signingKeys` and
  `egressIpRanges` move from `remotes[].extensions[...]` to `remotes[].extensionsInfo[...]`, and a
  cross-origin card's keys MUST NOT be used (webhook, out of scope: Zimmer neither verifies `v1a,` nor
  reads the card); a new rationale paragraph and Open Question 6 (non-normative). `events/list`,
  `events/poll`, `events/subscribe`, `events/unsubscribe`, delivery and its signature, the capability
  shape, the extension id, cursor semantics, error codes and the `Mcp-Name` header are unchanged. No
  wire-breaking change, no code change beyond `McpEvents::SPEC_REVISION`.
- **2026-11-23, `4165cc2` → `8a18b4b` (merged).** SEP-3415 merged on 2026-11-19 with status Final;
  the pin now follows the landed text. Changes, classified: status Accepted → Final and the author's
  handle (editorial); the TypeScript SDK reference implementation listed (non-normative); `x-mcp-header`
  annotations on an event type's `inputSchema`, mirrored into `Mcp-Param-{Name}` headers on every
  events request over Streamable HTTP, with `HeaderMismatch` (`-32020`) for a mismatch (additive: it
  changes nothing on the wire until a server annotates an argument, which none Zimmer polls does;
  recorded as a deviation, not built). `events/list`, `events/poll`, the webhook mode, the capability
  shape, the extension id, cursor semantics and the other error codes are unchanged. Checked while
  adding `coalesce_key` to `mcp_event` conditions, a Zimmer-side change with no wire effect.
- **2026-11-23, `8a18b4b` → `bbc31f8`.** Editorial: the working group's name, its maintainers, and where
  the specification is published (`modelcontextprotocol/ext-events`, `specification/beta/events/`, at
  Beta). That copy was compared at `c77b843`: the same normative text with the rationale removed and
  links made absolute. Wire unchanged; no code change beyond `McpEvents::SPEC_REVISION`. Checked while
  adding human-message capture for Slack events, a Zimmer-side change with no wire effect.
- **2026-11-24, still `bbc31f8`.** The SEP file has not changed since the pin, and neither has the
  `ext-events` copy (`main` compared with `c77b843`: identical). No drift to classify. The server half was
  implemented against this revision: `events/list` and `events/poll` on Zimmer's own `POST /mcp`.
