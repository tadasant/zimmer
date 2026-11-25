# Standby: starting a Live call at the tap

The goal is that a tap on **New** or **Continue** starts the call with nothing left to wait for but
the microphone. The app holds a connection ready for each, on the voice engine the call would run on,
and for New it also holds the conversation. The tap makes the connection the call's, and Zimmer is
told at the same time rather than first.

**On GPT-Live, none is held by default.** A held GPT-Live connection bills before any call, so it is
opted into: the Live setting *Paid standby cap per day*, 0 until somebody raises it. Realtime's costs
nothing and is held.

This began as *CarPlay pre-warm* (#1488): one Realtime connection, for Continue, in the car. The file
keeps its name. The user-facing prose is
[docs: Standby](https://docs.zimmer.tadasant.com/sessions/live/#standby). The rest of the car is
[`CARPLAY_DESIGN.md`](CARPLAY_DESIGN.md).

## What was slow, measured

Production call log (`scope.name:="ios.live"`), the last five taps on New from the car, 21 to 24
November 2026. All ran on `gpt_live_claude`; all were `path=cold`.

| Conversation | Find or make it | Voice on and grant | Audio engine | GPT-Live start | Tap to ready |
| --- | --- | --- | --- | --- | --- |
| 45 | 5.47 s | 0.63 s | 0.55 s | 2.49 s | **9.14 s** |
| 44 | 0.35 s | 0.38 s | 0.58 s | 2.69 s | **3.99 s** |
| 43 | 0.33 s | 0.49 s | 0.59 s | 3.44 s | **4.84 s** |
| 42 | 5.48 s | 1.24 s | 0.52 s | 3.44 s | **10.68 s** |
| 41 | 5.37 s | 0.46 s | 0.57 s | 2.53 s | **8.92 s** |

Over the ten days to 24 November, 27 calls: 25 cold, 2 warm, and neither warm one was New. Of 77
pre-warm mints, 50 were refused because the engine was GPT-Live.

**The root cause is three things, in this order:**

1. **Nothing was ever warmed for this tap.** The pre-warm was Realtime-only and Continue-only. On
   GPT-Live, Zimmer refused every mint, so the car held nothing for either tile.
2. **The tap did everything one step after another**: make the conversation, turn voice on, ask for
   the engine, open the audio, start a GPT-Live session, and only then was there a call. GPT-Live's
   own start is 2.5–3.4 s of that, and it cannot be made short at the tap; it can only be done before.
3. **The first step is the one that stalls.** Finding or making the conversation is one request. It took
   about 0.35 s or about 5.4 s and nothing between: 5.0 s is added to some requests from the car and
   not to others. It is not only New's (a mint on the same drive took 5.6 s, the next 0.2 s), and the
   two fast ones came within a second of another request on the same connection. No trace covers the
   phone's side of it, so its cause is not established. Standby does not fix the stall. It takes it out
   of the wait.

**The two connecting screens were steps 1 and 2 of that.** The first was the home's own tile, which
read *Connecting…* for as long as the conversation took to find or make (`LiveRetry.lookingUp`,
`LiveTalkTile.connecting`). The second was the call screen's *Connecting…*
(`LiveCallScreen`, `LiveVoiceState.connecting`), from `call.starting` to `call.connected`. The call did
not exist until it had a conversation, so there was no call screen to show before that.

## What a tap does now

```mermaid
sequenceDiagram
    participant D as Driver
    participant A as App
    participant Z as Zimmer
    participant O as OpenAI
    Note over A: the car connects
    A->>Z: POST live_conversations/standby
    Z-->>A: conversation 46, kept ready, nobody's
    A->>Z: POST 46/client_secret prewarm=1 standby=1
    Z-->>A: gpt_live_claude
    A->>Z: POST 46/gpt_live_session standby=1, WebRTC offer
    Z->>O: POST live/sessions, wake_policy speech
    O-->>A: session.started, inference paused
    loop until the tap
        A->>O: ICE consent, silence on a muted track
    end
    D->>A: tap New
    A-->>D: call screen, Connecting…
    par
        A->>A: open the microphone
        A-->>D: connected cue, Listening
    and
        A->>Z: POST live_conversations standby_id=46
        Z-->>A: 46 is the open conversation
        A->>Z: POST 46/client_secret
        Z-->>A: gpt_live_claude, recorded
    end
    D->>O: speaks; inference wakes
```

- **The call begins at the tap**, with the conversation still to be found or made if nothing is held
  for it (`LiveCall.start(_ choice:)`). The call screen goes up from there, so there is one
  *Connecting…*, the call's, and the tile's is never shown for a call. This holds for the cold path too.
- **What is left is the audio engine**, about 0.6 s in the table above. It cannot be opened sooner: no
  microphone and no audio session before the tap.
- **Zimmer is told behind the call** (`LiveCall.settle`). Until it answers (`settled`), the call follows
  no other conversation, and its lines, its delegations and its ledger rows wait. A request that gets
  no answer is sent again after 1 s and 3 s (`LiveCall.repeating`), which is safe: a New asked for again
  (`again=1`) is answered the same. If Zimmer never answers, the call ends saying so, because a call on a
  conversation Zimmer does not have can do nothing. The car's retry of that New asks for the same
  conversation, or goes back to it if Zimmer answered late (`LiveNew`), so a retry never ends
  the conversation the driver just asked for. Another call beginning stops the asking, and a repeat
  that gets through for a conversation already left is refused (409) and ends nothing.
- **A session still on its way up is taken too**, and finishes coming up as the call's. It is seconds
  ahead of one started at the tap. It gets 6 s.
- **Anything that goes wrong with the connection before the call is up starts it from cold**, on the
  same call screen, with no second tap (`path=fallback`).

### Realtime

The same, with a WebSocket in place of the session, as the pre-warm had it. New's is opened on the
conversation kept ready, so its instructions are the new conversation's. The tap makes the
conversation the open one, sends a fresh `session.update`, and holds the microphone until OpenAI
answers `session.updated` (3 s, then cold).

## The conversation kept ready

A conversation with status `standby` (`LiveConversations::Standby`). It is nobody's: not open, so it
is never the current one and takes no message or turn; on no list; and it ends nothing. There is at
most one, by a unique index, and asking again answers with the same row brought up to date. So an app
that holds one all day and never taps New leaves one unused row. The tap takes it
(`LiveConversations::Start`, `standby_id`): in one transaction the open conversation ends and this one
starts, dated from the tap. One that is gone, or that another device took and is talking in, is not
missed: the conversation started is a new one, and the answer's id says so.

## Can the provider hold it, and for what?

**GPT-Live: yes, for money.** OpenAI added standby to WebRTC sessions on 19 November 2026, the day
after the second attempt at this. A session created with `wake_policy: {type: "speech"}` starts with
inference paused, keeps its connection and id, and wakes when it hears speech.

| | |
| --- | --- |
| Active | $0.05 a minute, billed by the second |
| Standby | $0.02 a minute ($1.20 an hour), while inference is paused |
| Muted but not in standby | active rate: muting does not pause it |
| Starting one | by default, 15 s of active time up front, credited against the session. Whether a session that starts in standby is charged it is not stated |
| Longest life | `expires_at` on `session.started`; no figure is published |

So a held connection is $0.02 a minute, and two are $0.04. What bounds that:

- **Time.** Held for 20 minutes from the last sign a call may be near: the car connecting, Zimmer coming
  to the front in the car or on the phone, a call starting or ending, a settings change. Then nothing,
  until the next. That is $0.80 at most for an untouched home screen.
- **Money.** The Live setting **Paid standby cap per day**: 0, the default, is off. Off or past it, Zimmer
  refuses the hold before it asks OpenAI for anything, the app does not ask again for that conversation
  (`LiveWarmStart.refused`), and calls start from cold. Standby's seconds are ledger rows (`voice_standby`)
  at their own rate, and count toward the engine's daily cap.
- **Place.** In the car while it is connected. On the phone, only while Live is on screen and on a
  conversation with voice on. Continue's is not held during a call; New's is, because New is what
  replaces the conversation a call is on.
- **Suspended.** Seconds iOS had the app asleep are not counted as held: no ICE consent went out, so
  OpenAI let the session go (`GptLiveConductor.longestHeldGap`).
- **Waking early.** A session that wakes, or says anything, before the tap is closed at once.

With `idle_timeout_s` left out, a session that has woken stays awake until it ends. So a call from
standby is, from its first word, the call it always was.

**Realtime: for nothing, by its billing model.** It bills by tokens, and an idle session makes none.

## The hard rule

> Nothing is sent and no microphone or audio session is touched before the tap.

The second half stands as it was. The first is revised, for GPT-Live only: **nothing a person said,
typed or did is sent before the tap, and nothing that asks for anything.** A WebRTC session is not
silent the way an idle WebSocket is. It carries ICE consent checks, and OpenAI asks that the
microphone track of a session in standby be kept active. So:

- The track is **muted when it is made** and stays muted until the call's microphone is open
  (`GptLiveLink(muted:)`, `GptLiveCall.open`). libwebrtc sends silence on a muted track whatever
  it is given. It is what keeps a call's microphone, which feeds every connection there is, off the one
  held beside it.
- What it is given is **silence made in memory** (`LiveStandbySilence`), and only while no call is up.
  The microphone is not open.
- No event is sent on the data channel (`GptLiveConductor.inStandby`, tested).
- `LiveWarmStart.Action` is still `refresh`, `mint`, `ping` and `close`: nothing that sends. A Realtime
  connection (`LiveWarmLink`) still has no method that can.
- On the server, nothing about the open conversation changes: no client noted, no `car_call`, no model,
  no engine, no voice.

## Architecture

```
ZimmerKit (Foundation only, tested on Linux)
  LiveWarmStart        the state machine, one per tap (Slot.open, Slot.new); no I/O
  GptLiveConductor     standby: says nothing, reports its seconds, claim(at:) makes it a call
  LiveEvent.warm*      the telemetry; call.startup, call.microphone_open, call.settled
  LiveAPI              liveStandby(), livePrewarmGrant(id), startLiveConversation(_:standby:)

App (iOS)
  LiveWarmKeeper       where taps may come from (the car, Live on the phone), the phone's state
  LiveWarmHolder       one slot: reads Zimmer, opens the connection, sees it is alive, closes it
  LiveWarmLink         a Realtime socket in standby
  GptLiveCall          a GPT-Live session in standby: adopt, then open
  LiveCall             start(_ choice:), startFromStandby, startOnStandby, settle, leaveStandby

Rails
  LiveConversations::Standby                            the conversation kept ready
  POST /api/v1/live_conversations/standby               make it, or bring it up to date
  POST /api/v1/live_conversations         standby_id=   New takes it
  POST …/:id/client_secret        prewarm=1 standby=1   which engine; change nothing
  POST …/:id/gpt_live_session               standby=1   start the session paused; change nothing
  SpendGuard.standby_refusal                            the daily cap
```

## Numbers

| | Realtime | GPT-Live | Why |
| --- | --- | --- | --- |
| Tick | 1 s | 1 s | Cheap; every rule is a comparison |
| Refresh, Continue | 30 s | 30 s | Follows the open conversation |
| Refresh, New | 10 min | 10 min | Only a tap changes it; 30 s after a failed one |
| Heartbeat | 20 s ping | 20 s look at ICE | Inside carrier NAT idle timeouts |
| Coming up | 15 s | 15 s | A cold call's 5 s, plus the 5 s stall |
| Stale | 45 s unheard | 45 s, and ICE up at the tap | Not handed to a call |
| Dead | 70 s unheard | 70 s | Closed, then backoff |
| Max age | 5 min | 20 min, or half of OpenAI's `expires_at` | Config is fixed at the mint |
| Rest | never | 20 min after the last sign of a call | It costs money |
| After a suspend | ping | close and start again | ICE consent lapsed while iOS had the app |
| Backoff | 5, 15, 60, 120 s | same | One per failure in a row |
| Refused (409) | asked again when Zimmer comes to the front, on a settings change, or after another conversation | same | An answer, not a failure |
| Budget | 15 mints a visit | same | A car connection or Live open on the phone, and any within the hour after |

Nothing is held on Low Power Mode, at a serious thermal state, on Low Data Mode or with no network. A
change to the Live settings made on this phone, the car's panel included, closes what is held and
starts again. A GPT-Live connection for Continue is made again when its conversation is added to,
because its instructions are fixed. A call coming back from the gear never takes one.

## Measuring it

| Metric | Event | Field |
| --- | --- | --- |
| Tap to ready, by tap and path | `call.startup` | `tap` (`new`, `continue`), `path` (`warm`, `warming`, `cold`, `fallback`), `engine`, `tap_to_ready_ms` |
| Hit rate, by tap | `warm.claimed` / (`warm.claimed` + `warm.missed`) | `slot`, `reason`, `hold` |
| Where the wait went | `call.microphone_open`, `call.connected` | `since_tap_ms`, `since_start_ms` |
| How long Zimmer took, behind the call | `call.settled` | `request_ms`, `since_tap_ms`, `moved` |
| Coming up | `warm.ready`, `warm.failed`, `warm.refused`, `warm.closed` | `slot`, `engine`, `since_mint_ms`, `session_life_ms`, `reason` |
| Cost | `voice_standby` on `/live/costs` | seconds |

The LogsQL is in [docs: observability](https://docs.zimmer.tadasant.com/operate/observability/#the-ios-apps-call-log).

**How to judge the first drives**, with paid standby opted into. For `tap=new` on GPT-Live: `path=warm` on most taps, and
`tap_to_ready_ms` at or under about 1 s for those. Before, the median of the five above was 8.9 s. A
warm tap over 1.5 s is the audio engine, which `call.microphone_open` says. Any `path=fallback`
or `warm.failed` is worth reading: it carries OpenAI's or Zimmer's reason. Compare the OpenAI
usage page with `voice_standby` on `/live/costs`.

## Turning it off

- **GPT-Live standby**: Live settings → *Paid standby cap per day* → 0, which is the default. No deploy. The
  next hold is refused; one already open goes on for up to 20 minutes, or until the app lets it go.
- **All of it, with a server deploy**: make `Actions#require_prewarm!` refuse with a 409. The app is refused once
  for each conversation, and calls start from cold.
- **All of it, in the app**: drop the `LiveWarmKeeper` calls in `CarPlaySceneDelegate` and `LiveHomeView`.

## Later

- **The 5 s stall.** A cold New still meets it. Telling the network's part from the server's needs the
  phone's own request timings (`URLSessionTaskMetrics`) on the call log.
- **Opening the audio engine faster.** It is all that is left of a warm tap.
