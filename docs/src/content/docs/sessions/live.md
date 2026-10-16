---
title: Live Mode
description: One continuous conversation with Zimmer, typed or spoken, run by a fast OpenAI model that answers quick things itself and hands everything slower to background sessions.
---

A session is an agent working on one job. Sometimes you want something else: to think out loud, ask
what is going on, and kick off work as it occurs to you, without writing a prompt for each piece.
That is what Live Mode is for. It is **one continuous conversation** with a fast model that answers
quick things itself and hands anything slower to Zimmer's own [MCP surface](/extend/mcp-server/).
It starts a background session, says that it has, and checks back on it when you ask.

You can type or talk. Voice is not a separate mode with its own thread: **Enable voice**, next to the
composer, turns voice on in the conversation you are in, and **Type instead** turns it off again.
The thread carries both. Spoken turns are transcripts beside the typed ones.

| | Typed | Voice on |
| --- | --- | --- |
| Model (default; [tunable](#live-settings)) | `gpt-6-luna`, Chat Completions, `reasoning_effort: "none"` | `gpt-realtime-2.1-mini`, Realtime API |
| Where it runs | a job on the server | the browser's WebRTC or the phone's WebSocket connection to OpenAI |
| How it answers | longer answers, lists, snippets, links, light markdown | short spoken turns, nothing read out that is meant to be seen |
| Agent root | `live-mode` | `live-mode` |

You enter it from the main screen: **Live Mode** beside **New Session**, or the chat button and the
menu on a phone. `/live` has it as well, plus whether the OpenAI key is set.

## One conversation

Live Mode has one current conversation. Opening it resumes that conversation; **New conversation**
ends it and starts a fresh one, typed. The database enforces this with a unique index over open
conversations, so two starts racing cannot leave two current threads. Ended conversations stay
readable, including those from the retired `live-voice` root. The migration that folded voice into
Live Mode (`UnifyLiveModes`) ended any that were still open rather than deleting them.

`mode` on the record is `text` or `voice`: how the conversation runs right now. Switching it
(`POST /live_conversations/:id/mode`) changes the model too, because each path has its own, and
nothing else. The thread, the enabled MCP servers and the instructions stay as they were. While
voice is on, typed messages are refused, because the call holds the conversation and would never
hear a reply written behind its back. While it is off, no Realtime secret is minted. A call that is
already connected when voice goes off elsewhere can still record its last lines and finish a tool
call.

A conversation is its own record (`LiveConversation`, with `LiveConversationTurn` rows), not a
[session](/sessions/lifecycle/). A session is an agent process: it is spawned, heartbeated, swept
when its start stalls, and reaped with its clone. A live conversation has no process for any of that
to manage. What it shares with sessions is what it delegates to them.

Its lifecycle is short: `preparing` while Zimmer reads its agent root's AGENTS.md, then `active`,
then `ended`. It goes to `failed` when the instructions cannot be read, and the reason is shown on
the page.

## The agent root is the system prompt

Live Mode has one agent root in the catalog, `live-mode`, whose **AGENTS.md is the model's
instructions**, typed or spoken. Starting a conversation fetches that file: a shallow, blobless
clone with no checkout, then `git show` of the file, with the same stall detection as a session
clone (`LiveConversations::RootInstructions`). CLAUDE.md is accepted when a root ships only that.
The page says which commit the instructions came from.

The root can also ship one **style file per mode** beside it: `modes/text.md` for how to answer when
typed, `modes/voice.md` for how to answer out loud. Both are optional and read in the same fetch,
and they are kept on the conversation (`mode_instructions`), so a switch mid-conversation needs no
second fetch. A blank file counts as missing.

The model is told, in this order:

1. the root's AGENTS.md;
2. a short section Zimmer writes about mechanics only it knows: that the conversation can be typed
   or spoken and which it is now, the functions, and the conversation's URL;
3. **Right now: typed** or **Right now: spoken**. This is the root's style file for the current mode,
   or Zimmer's short default for that mode (`LiveConversations::MODES`) when the root ships none. It
   comes after AGENTS.md and says it takes precedence on style, so an AGENTS.md written with one mode
   in mind does not outvote the mode the conversation is in. The page's header says when the
   default is in use;
4. for a voice call only, a recap of the last thirty lines, because a new Realtime session remembers
   nothing. That is true whether it is reconnecting or the conversation was typed until a moment ago;
5. the [Live mode guidance](#live-mode-guidance), when there is any.

All of it is rebuilt every time it is used (`LiveConversations::SystemPrompt`). A typed reply builds
it for each request, and a voice call builds it when its secret is minted and for every
`session.update`. So a switch shows up in the very next answer.

The root's default MCP servers are the conversation's starting tool set. If the catalog has no
`live-mode` root, Live Mode is **off** and says so: on `/live`, on its start page, in
`GET /api/v1/live` and in `get_live_conversations`. It does not crash. Live Mode reads no other
root, so a `live-voice` root left in a catalog is ignored.

## The tool bridge

The model can call four kinds of function (`LiveConversations::ToolBridge`):

- **`zimmer(tool, arguments)`**, which calls one of Zimmer's own MCP tools in-process. This is the
  delegation path: `quick_router` or `start_session` to start work, `get_session` to check on it,
  `action_session` to follow up. It exists when the conversation has one of Zimmer's own catalog
  servers (`zimmer`, `zimmer-*`), scoped to the tool groups that server's URL names. It is one
  gateway rather than one function per tool because the default surface's definitions come to about
  200 KB, too much for a realtime model to carry on every turn. The gateway lists each tool in one
  line, and `describe_zimmer_tool` returns any tool's full schema.
- **`list_mcp_servers`, `enable_mcp_server`, `disable_mcp_server`**, through which the model manages
  its own catalog servers. This is the self-enable path.
- **`<server>__<tool>`**: every tool of every enabled non-Zimmer server, called directly.
- **`get_live_settings`, `update_live_settings`**: its own [settings](#live-settings) and guidance,
  always present. "Talk faster" or "from now on, always…" becomes a change the live agent makes
  itself.

```mermaid
flowchart LR
  subgraph Client["Browser / phone"]
    UI["Thread page"]
    Dock["Call dock (voice on)"]
  end
  subgraph OpenAI
    Chat["Chat Completions<br/>gpt-6-luna"]
    RT["Realtime<br/>gpt-realtime-2.1-mini"]
  end
  subgraph Rails["Zimmer"]
    Job["LiveConversationReplyJob"]
    Bridge["ToolBridge"]
    Mcp["Zimmer MCP tools<br/>(in-process)"]
    Cat["CatalogServer<br/>stdio / remote"]
    Mint["RealtimeSession<br/>client secret"]
  end
  UI -- "typed message" --> Job
  Job <--> Chat
  Job --> Bridge
  Dock -- "WebRTC audio + events" <--> RT
  Dock -- "function_call → POST tool_calls" --> Bridge
  Dock -- "POST client_secret" --> Mint
  Mint --> RT
  Bridge --> Mcp
  Bridge --> Cat
  Mcp -- "start_session / quick_router" --> Sessions["Background sessions"]
```

### Delegating, and when not to

The agent root's AGENTS.md owns the policy. The intended shape, which Zimmer's own section repeats in
one line, is this: anything that takes more than about five seconds becomes a background session,
and the live model stays responsive. The sessions it starts are ordinary sessions on the board.

Every session the live model starts, follows up or routes is told where the request came from. The
[turn-source note](/sessions/turn-sources/) reads `live_voice` or `live_text`, from the
conversation's mode when the tool runs, and names the client that last drove the conversation
(`live_conversations.client_surface`: web, ios, carplay or mcp). The background agent can then keep
what it reports back short enough for the live model to say aloud.

### Self-enabling a catalog server

When the live agent keeps reaching the same capability through a background session, it can call
`enable_mcp_server` with that server's catalog name and call the server's tools itself. That costs
one hop instead of a session. Enabling lists the server's tools once and keeps them on the
conversation (`mcp_tool_cache`), so building the function list never has to start the server. A
voice client is handed the new tool list and sends a `session.update`. Live Mode picks it up on its
next request. A conversation enables at most eight servers and exposes at most 80 direct tools.

The bridge runs on the server because nothing else can. Most catalog servers are `npx` stdio
processes or need credentials, and neither the browser nor OpenAI can run or hold those.

- **Remote servers** are reached with the URL, headers and OAuth token `McpServerEndpoint` resolves.
  These are the same ones MCP Apps uses.
- **Stdio servers** are spawned for one call and closed after it. Their environment is the server's
  own catalog `env` (interpolated through the secrets chain) plus `PATH`, `HOME`, `LANG`, `LC_ALL`,
  `TMPDIR` and `USER`. It is never the Rails environment, which holds the database password and every
  API key.

Every call is recorded as a `tool` turn with its arguments and output. The page shows it collapsed,
for example as `zimmer → quick_router`.

## Typed

A typed message becomes a `user` turn and enqueues `LiveConversationReplyJob` on the `inference`
queue. The job claims the conversation (`responding_since`, under a row lock), replays the last 80
turns to Chat Completions with the bridge's tools, and runs any function calls. It feeds the results
back and repeats until the model answers in words, giving up after eight rounds. A message typed
while a reply is running is answered by the same loop. Turns reach the page over Turbo Streams.
Nothing is stored at OpenAI: the thread is replayed from Zimmer's own rows every time.

## Voice

Audio never passes through Zimmer:

1. **Enable voice** switches the conversation to voice and starts the call in one press; **Talk**
   reconnects one that is already in voice. Either way the browser asks Rails for a client secret (`POST /live_conversations/:id/client_secret`). Rails
   calls OpenAI's `POST /v1/realtime/client_secrets` with the whole session config: model,
   instructions, tools, `gpt-4o-mini-transcribe` transcription, `semantic_vad` turn detection, and
   the voice (`marin`, or `LIVE_VOICE_VOICE`). The secret lasts ten minutes and the real key never
   leaves the server.
2. The browser opens WebRTC to OpenAI with that secret: an SDP offer to `/v1/realtime/calls` and the
   `oai-events` data channel.
3. On `response.function_call_arguments.done` it relays the call to `POST tool_calls` and sends the
   output back as a `function_call_output` item. When that response's `response.done` arrives and
   every result is in, it sends exactly one `response.create`.
4. Finished transcript lines (`conversation.item.input_audio_transcription.completed` and
   `response.output_audio_transcript.done`) are posted as turns, so the thread on the page and in
   the API carries what was said.

### Listening: which lines get an answer

An open microphone hears more than the person talking to Zimmer: a passenger, the radio, a
conversation across the room. **Listening** (a [Live setting](#live-settings)) picks what the call
answers:

| Mode | Answers | For |
| --- | --- | --- |
| Always (default) | every line it hears | a private space, the car |
| Wake word | a line that says "Zimmer", anywhere in it, or a follow-up within ten seconds of the last line kept or spoken | a room with other people in it |
| Dynamic | the same, or a line a text model judges was said to Zimmer | the same, without the wake word |

In Always, OpenAI's turn detection starts each reply itself. In the two gated modes, Zimmer builds
the call with `create_response: false` and `interrupt_response: false`, so turn detection does
neither. Each finished user line goes to `POST turns`, and `LiveConversations::Listening` decides.
A line that repeats Zimmer's last reply is its own voice coming back through the speaker, and is
dropped first. The wake word is a match on the transcript. The follow-up window means "yes" to a
question, or the second half of a sentence split at a pause, does not need the wake word. Dynamic
sends the line to the text model (`reasoning_effort: "none"`, a three-token answer) along with the
last six lines of the thread, so an answer to Zimmer counts and two people talking to each other
don't. If the judge cannot be reached (two seconds to connect, six to answer), the line is answered.
A kept line is written to the thread, and the client sends `response.create`. A dropped line, or one
that could not be transcribed, is not written anywhere, and the client deletes it from the call with
`conversation.item.delete`, so it never colours a later reply.

Gating needs a client that does its half. A client says it does with `listening_modes` on
`client_secret`, `session_update`, `tool_calls` and gated `turns`. Without it, an iOS build from
before Listening for instance, the call answers everything whatever the setting says. Which mode a
call is in follows from what OpenAI applied: `client_secret` answers `listening`, and after that the
client reads `create_response` from each `session.created` and `session.updated`. A refused
`session.update` does not leave the client thinking the call is gated when it isn't.

The call is owned by a dock in the layout (`shared/_live_voice_dock`, `data-turbo-permanent`), not by
the conversation page. A Turbo navigation replaces the page body, and a peer connection living in it
would drop on every click. The dock keeps the call, its mute and hang-up buttons, and a link back to
the thread while you look around Zimmer.

**Type instead** hangs up and switches back. Hanging up from the dock leaves voice on, and the
conversation page offers **Talk** to reconnect or **Type instead**. When another device switches the
mode, the header changes over Turbo Streams and the page re-renders its composer or call controls,
unless a message is half-typed.

## Live settings

`/live/settings` holds what is worth tuning about how Live Mode thinks, sounds and listens. There is
one set for the whole deployment, a single `LiveSetting` row. Reach it from the gear on a
conversation's page, from `/live`, or from Settings. Every field is blank until somebody sets it,
and blank means the shipped default: the behaviour from before any of this was tunable.
**Reset settings to defaults** writes blanks back. It leaves the guidance alone.

| Setting | Path | Default | Choices or range | Applies |
| --- | --- | --- | --- | --- |
| Text model | typed | `gpt-6-luna` (or `LIVE_MODE_MODEL`) | `gpt-6-luna`, `gpt-6-sol` | next turn |
| Text temperature | typed | OpenAI's (1.0) | 0–2 | next turn |
| Text max output tokens | typed | no cap | 256–128,000 | next turn |
| Voice model | voice | `gpt-realtime-2.1-mini` (or `LIVE_VOICE_MODEL`) | `gpt-realtime-2.1-mini`, `gpt-realtime-2.1`, `gpt-realtime-2` | next call |
| Voice reasoning effort | voice | the model's | `minimal` … `xhigh` | next call |
| Voice | voice | `marin` (or `LIVE_VOICE_VOICE`) | OpenAI's ten voices | next call |
| Speaking speed | voice | 1.0 | 0.25–1.5 | mid-call |
| Voice max output tokens | voice | no cap | 128–4,096 | mid-call |
| Listening | voice | `always` | `always`, `wake_word`, `dynamic` ([Listening](#listening-which-lines-get-an-answer)) | mid-call |
| Turn detection | voice | `semantic_vad` | `semantic_vad`, `server_vad` | mid-call |
| Eagerness (semantic) | voice | `auto` | `auto`, `low`, `medium`, `high` | mid-call |
| Threshold, prefix padding, silence duration (silence) | voice | 0.5, 300 ms, 500 ms | 0.1–0.95, 0–1,000 ms, 200–3,000 ms | mid-call |
| Noise reduction | voice | off | `near_field`, `far_field` | mid-call |
| Transcription model | voice | `gpt-4o-mini-transcribe` | that, `gpt-4o-transcribe` | mid-call |

The list is what each path can actually use. The typed path calls Chat Completions with function
tools, and OpenAI accepts those from the GPT-6 family only from `gpt-6-luna` and `gpt-6-sol`, only
at `reasoning_effort: "none"`. So there is no text reasoning-effort setting. The stronger GPT-6
models take tools only through the Responses API, and Live Mode does not use it yet. The ranges are
narrower than the API's where an extreme would silence the agent: a VAD threshold of 1.0 never hears
speech.

**When a change applies.** The typed path reads the settings before every request. The voice path
reads them when it mints a call's secret. An open call is also sent a `session.update` with
everything a Realtime session can change mid-call: instructions, tools, speed, turn detection, noise
reduction, transcription, and the output cap. It is sent when the live model changes a setting
itself (the tool-call response carries it), and when a person saves the settings page while the
call dock has a call open (`POST /live_conversations/:id/session_update`). OpenAI fixes a call's
model, voice and reasoning effort for its life, so those apply from the next call.

**A bad write cannot break Live Mode.** Every writer goes through
`LiveConversations::SettingsUpdate`: the page, REST, MCP, and the live model. An unknown setting,
or a model, voice or mode not on the list, is refused and nothing is saved. A number outside its
range is clamped, and the answer says so. If OpenAI still refuses what was saved (a model this key
cannot use, say), the typed reply and the voice call each retry once on the defaults and say so: on
the conversation's page, and as `settings_warning` from `client_secret`.

### Live mode guidance

The guidance is free text, up to 8,000 characters, appended to the system prompt on every turn,
typed and spoken. It comes after the root's AGENTS.md and Zimmer's section, last, so it reads as the
newest word. It exists for fast iteration: tune it here, then
lift what works into the `live-mode` root's AGENTS.md. **Copy** puts the whole text on the
clipboard.

The live agent can edit its own guidance. `update_live_settings` takes `append_guidance` for a
standing instruction and `guidance` to rewrite it. That is deliberate, and every agent write is
visible:

- the thread shows the change as an amber note, not a folded tool call;
- the **History** on the settings page records every change, field by field, before → after, and
  who made it: a person (the settings page, the iOS app) or an agent (a live conversation's model, or
  a session through MCP);
- any guidance edit in the history has **Restore the guidance from before this edit**.

The settings page posts only the fields you edited. A field you did not touch does not undo a
change the live agent made while the page was open.

## On the phone and in the car

The [iOS app](/extend/ios-app/) has Live Mode behind the session list's waveform button, over the
same REST routes, with the same **Enable voice** and **Type instead**. The button lands in the
current conversation with voice on and the call starting. When none is open it starts a new one
with voice on. One tap on **Type instead** turns voice off in that thread. **New conversation** on
the thread's toolbar and its confirmation are the two taps to a fresh one, in whichever mode the
thread is in. Back leads to the Live list. The web's `/live` keeps its own entry, which opens the
list. Starting a call on the phone
turns voice on first (`POST …/mode`), so Enable voice, Talk and CarPlay's Resume all take the same
path. A call on the phone opens a **WebSocket** to OpenAI rather than WebRTC.
It uses the `websocket_url` the client-secret call returns, sends 24 kHz PCM16 as
`input_audio_buffer.append`, and plays `response.output_audio.delta`. It relays function calls
and transcript lines exactly as the browser does: the shared rules are `RealtimeConductor` in
ZimmerKit. CarPlay offers *New conversation* (which starts with voice on) and *Resume conversation*
(which turns voice on in the open one, typed until then or not) on the same call. Every TestFlight
build signs in the CarPlay entitlement that makes it reachable.

The gear on the app's Live screens opens the same [Live settings](#live-settings) over
`/api/v1/live/settings`, guidance and history included. A save there sends an open phone call a
fresh `session.update`.

## The OpenAI key

Live Mode needs `LIVE_OPENAI_API_KEY`, typed or spoken, resolved through the
[secrets chain](/operate/secrets-parameter-store/) (Parameter Store, Rails credentials, environment).
Without it Live Mode is off, with that as the stated reason. Zimmer does not write the key: set it in the secrets console that administers
Zimmer's store, as a secret parameter at `/zimmer/<env>/secrets/static/LIVE_OPENAI_API_KEY`, or with
the `gcloud` commands in [Adding a secret](/operate/secrets-parameter-store/#adding-a-secret). A new
value reaches Zimmer within a minute, with no redeploy. `/live`'s "OpenAI API key" panel shows
whether the key is set, which link of the chain holds it, and that path, and links the console when
`ZIMMER_STORE_CONSOLE_URL` is set. It shows no value and no fingerprint. See
[Secrets Zimmer itself depends on](/operate/secrets-parameter-store/#secrets-zimmer-itself-depends-on).
The key has its own name rather than `OPENAI_API_KEY` because store-resolved variables can reach session
environments, and Codex and Pi read `OPENAI_API_KEY` on their own. A key set for Live must not change
how those sessions authenticate or bill.

| Variable | Default | What it does |
| --- | --- | --- |
| `LIVE_OPENAI_API_KEY` | none | The key. Required. |
| `LIVE_MODE_MODEL` | `gpt-6-luna` | The typed default model, when the Live settings name none |
| `LIVE_VOICE_MODEL` | `gpt-realtime-2.1-mini` | The voice default model, likewise |
| `LIVE_VOICE_VOICE` | `marin` | The default voice it speaks in, likewise |
| `LIVE_OPENAI_BASE_URL` | `https://api.openai.com/v1` | An OpenAI-compatible endpoint instead |
| `ZIMMER_STORE_CONSOLE_URL` | none | The console over Zimmer's own store, linked from the key panel. Unset, the panel shows the path without a link |
| `ZIMMER_STORE_CONSOLE_STORE_NAME` | none | What that console calls the store, shown beside the link |

## From an agent or a script

- **MCP:** `get_live_conversations` (whether Live Mode can start, the current and recent
  conversations, one thread) and `action_live_conversation` (`start`, `send_message`, `set_mode`,
  `finish`); `get_live_settings` and `action_live_settings` (`update`, `reset`, `restore_guidance`)
  for the [Live settings](#live-settings). All four are in the opt-in
  `live_conversations` group, which nothing carries by default: a live model can reach the whole
  catalog, so a session must not be able to steer one just by holding `sessions`. See
  [the MCP server](/extend/mcp-server/).
- **REST:** `/api/v1/live`, `/api/v1/live/settings` and `/api/v1/live_conversations`. An API key
  may read them. Starting, messaging, switching, finishing, the voice relay and changing the settings
  take the iOS app's sign-in acting as you, for the same reason. An agent changes the settings through
  MCP, where the change is recorded as an agent's. See [the REST API](/extend/rest-api/#live-conversations).
- **Supervisor:** `/supervisor/live_conversations` and `/supervisor/live_conversation_turns`, both
  read-only.

What is not proven yet, and the known rough edges, are on [Known limitations](/limitations/).
