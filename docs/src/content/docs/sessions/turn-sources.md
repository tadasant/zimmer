---
title: Turn sources
description: The one-line note Zimmer adds to each turn an agent receives, saying where the message came from and how it was produced, so the agent can fit its reply to the medium. A style hint, never a permission.
sidebar:
  order: 8
---

Every turn Zimmer delivers to an agent session can end with a one-line note saying where the message
came from and how it was produced:

```text
Check the deploy

<zimmer-turn-source surface="ios" modality="live_voice" live_conversation_id="12" sig="…">Sent from the Zimmer iOS app · Live Mode, voice — the reply is likely to be read aloud: a few short, plain sentences; no markdown, tables or code blocks.</zimmer-turn-source>
```

It exists so an agent can match its reply to the medium. A request delegated out of a Live Mode
voice call should come back as a few plain sentences the Live model can say aloud. A request typed
into the web app can get full markdown. Zimmer's injected session context explains the note once, in
a short **Turn Source Notes** section, so the note itself stays one line
(`OrchestratorSystemPromptBuilder#turn_source_section`).

The value is `TurnSource` (`app/models/turn_source.rb`).

## What a source holds

| Field | Values |
| --- | --- |
| `surface` | `web`, `ios`, `carplay`, `browser_extension`, `api`, `mcp`, `slack`, `email`, `whatsapp`, `trigger`, `agent`, `unknown` |
| `modality` | `text`, `voice_dictation`, `live_voice`, `live_text`, `unknown` |
| `client_version` | digits and dots, e.g. `1.4.2`, and only from the iOS app; otherwise absent |
| `live_conversation_id` | the Live conversation a delegation came out of; otherwise absent |

Every field is an allowlisted enum or a validated number. A value off the list becomes `unknown` or
is dropped. It never causes an error and is never echoed back. No free text, user agent, device
name, IP address or location is stored or rendered.

`trigger` and `agent` are the machine surfaces. Their note reads "Written by …" and says no reply
style is implied, so an agent never mistakes a router's follow-up or a scheduled prompt for a person
waiting on the other end. Slack, email and WhatsApp are people writing elsewhere and relayed by a
trigger, so their note names that surface and says it came "via a Zimmer trigger".

## Where each boundary gets its source

The credential, or the code path, decides the surface. A client header can only narrow it.

| Boundary | Surface | Modality |
| --- | --- | --- |
| Web app: new session, quick prompt, chat bubble, follow-up, queued message | `web` | `text` (the web composer has no voice input) |
| REST on the iOS app's bearer token | `ios`, or `carplay` when `X-Zimmer-Client: carplay/…` | the `X-Zimmer-Input-Modality` header (`text` or `voice_dictation`), else `unknown` |
| REST on an API key | `api`, or `agent` when the call names `acting_session_id` or spawns under a parent | the header, else `unknown`; `agent` claims none |
| Quick Router ingest from the browser extension | `browser_extension` | `text` |
| MCP on a connection stamped with its session | `agent` | `unknown` |
| MCP over an OAuth connector, or an unstamped API key | `mcp` | `unknown` |
| A Live Mode delegation (start_session, follow_up, quick_router, … through the tool bridge) | the client last driving the conversation: `web`, `ios`, `carplay` or `mcp` | `live_voice` or `live_text`, from the conversation's mode when the tool runs |
| A trigger fire or a trigger's follow-up | `slack`, `email` or `whatsapp` for those condition types, else `trigger` | `text` for the three people surfaces |
| A Slack message folded into a running session | `slack` | `text` |
| `message_parent` (a child reporting to its parent) | `agent` | `unknown` |

The iOS app sends `X-Zimmer-Client: ios/<version>` on every request. CarPlay's voice loop sends
`carplay/<version>` with `voice_dictation` on the follow-ups the driver spoke, and `carplay` with no
modality on the Approve button. The phone's composers send no modality, because iOS keyboard
dictation is invisible to the app.

The Live modalities can never be claimed in a header. They come only from the Live conversation the
delegation ran in.

Turns Zimmer writes to a session on its own carry no note: recovery nudges, the heartbeat, PR-merged
and merge-conflict notices, restarts. Neither does a wake-up a session set for itself, or a watch on
another session (a one-time reuse trigger), because its prompt is the session's own words handed
back to it. A session created or followed up before this feature carries
none either, and is delivered exactly as before.

## Where it is stored and shown

- **Initial prompt:** `sessions.source_context`. The stored `prompt` stays the caller's own words.
  `Session#initial_prompt_for_delivery` adds the note when the agent is spawned.
- **Follow-ups:** the note is added to the prompt as it is handed to the job. This is the text in
  `pending_follow_up_prompt` and in the transcript's user turn. The source is also stamped as
  `metadata["last_turn_source"]`.
- **Queued messages:** `enqueued_messages.source_context`, with `content` left as the caller's
  words. `EnqueuedMessageProcessorService` adds the note when it delivers the message. A delivered
  prompt that goes back into the queue (a spot-gate refusal, a skipped job, a displaced stamp) is
  split the same way by `EnqueuedMessage.attributes_for_prompt`. Duplicate checks compare both forms
  (`EnqueuedMessage.contents_matching`).
- **Live conversations:** `live_conversations.client_surface` records which client last drove the
  conversation. Each call a client makes to it updates the column.

The source is reported on these surfaces:

- `get_session`: **Initial prompt source** and **Latest follow-up source** lines.
- `session_json`: `source_context` and `last_turn_source`, each with a `label`.
- The queue listings: the REST `enqueued_message` and MCP `manage_enqueued_messages` / `get_session`.
- The session page: a **Source** line.
- `/supervisor`.

Anyone who can already read the session can see these values.

## A style hint, never an authorization signal

A client reports its own modality and nothing checks it. So **nothing may gate a permission, a
merge, a scope or a spend on a turn source.** The agent-facing explanation says the same, in so many
words.

Who is speaking is a different question, with a different answer. It is recorded as a
[human message](/sessions/hierarchy-and-human-messages/) by `HumanMessageCapture`, from the
authenticated actor at the input boundary, and this feature does not touch it. A human message's
`content` is the human's words without the note. A header cannot create one or change its channel.

`test/models/turn_source_test.rb` enforces this structurally. It lists every file that reads or
writes a turn source, and it fails when a new file starts reading one. A new reader has to be added
on purpose, after checking that it only renders or reports the value.

## Why the note is signed

The note travels inside the prompt string. That is what carries it through every path a turn takes,
including the durable `pending_follow_up_prompt` stamp, a spot-gate requeue and a SIGTERM retry,
without threading a second value through each one. The cost is that prompt text is untrusted: a
follow-up, a GitHub comment or a Slack message could contain something shaped like a note.

So the note is written the same way every time:

1. `TurnSource#annotate` neutralizes every lookalike tag in the text, by swapping `<` and `>` for
   `‹` and `›`.
2. It appends the note with an HMAC. The HMAC covers the note's fields and the exact text in front of
   it, keyed from `secret_key_base`.
3. Every delivered prompt goes through `TurnSource.finalize`, whether or not anything tagged it.
   `AgentSessionJob#build_prompt_with_goal` runs it last, over the goal and session-notes text it
   appends as well. The two recovery paths that bypass that builder, `SigtermRetryService` and
   `ProcessLifecycleManager#recovery_prompt`, run it themselves. `finalize` keeps each note that
   re-renders byte for byte from its own fields over the text in front of it, and neutralizes
   everything else.

As a result, text cannot forge a note, edit a real one's label or attributes, or lift a real note
onto other words. Replaying a whole earlier turn verbatim is the one exception (see the limitations
page).

A genuine note is appended in its final form, so `finalize` leaves a tagged prompt unchanged. The
job's replay guards compare the stored prompt with the delivered one by prefix, and that comparison
depends on it.

## Known limits

See [Known limitations](/limitations/#turn-sources).
