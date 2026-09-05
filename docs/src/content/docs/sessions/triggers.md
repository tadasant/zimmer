---
title: Triggers and schedules
description: The five trigger condition types, how they create or resume sessions, and the wake-up semantics that back an agent's "wake me later" tools.
sidebar:
  order: 5
---

A **trigger** is a session template plus one or more conditions. When any condition fires, the
trigger creates a new session — or resumes an existing one.

Conditions on a trigger are ORed. Any one firing fires the trigger.

## The six condition types

```mermaid
flowchart LR
    subgraph conditions["TriggerCondition"]
        SL["slack<br/>channel_id + event_type<br/>(new_message | bot_mention | dm_message |<br/>passive_listen_thread | passive_listen_channel)"]
        SC["schedule<br/>recurring (interval/unit/time/day)<br/>or one-time (scheduled_at)"]
        AO["ao_event<br/>session_needs_input<br/>session_failed<br/>session_archived<br/>account_needs_reauth"]
        SE["system_event<br/>quota_available<br/>no_sessions_in_progress"]
        GL["github_label<br/>repos + target<br/>(pull_request | issue) + labels"]
        GI["github_issue<br/>repos + exclude_labels"]
    end

    SL -->|"SlackTriggerPollerJob<br/>(cron, every minute)"| T["Trigger"]
    SC -->|"ScheduleTriggerJob<br/>(cron, every minute)"| T
    AO -->|"AoEventTriggerJob<br/>(enqueued from state machine callbacks)"| T
    SE -->|"SystemEventTriggerJob<br/>(enqueued from QuotaAvailabilityMonitor<br/>or FleetIdleMonitor)"| T
    GL -->|"GithubTriggerPollerJob<br/>(cron, every minute)"| T
    GI -->|"GithubTriggerPollerJob<br/>(cron, every minute)"| T

    T --> H["heal stale catalog refs<br/>(agent root repointed, never raised)"]
    H --> D{"reuse_session?"}
    D -->|"yes + session is<br/>needs_input/running/waiting"| FU["follow_up_session!"]
    D -->|"resuscitate_archived<br/>+ archived<br/>+ the session started"| RS["unarchive + follow up"]
    D -->|"one-time reuse trigger,<br/>target not reusable"| SK["skip — nothing to spawn,<br/>nothing to resolve"]
    D -->|no| HR["resolve the agent root<br/>(raises if it cannot)"]
    D -->|"archived, never started<br/>(nothing to follow up into)"| HR
    HR --> NEW["create_new_session!"]
```

### `slack`

Polls a channel for `new_message`, `bot_mention`, or one of the two passive-listening event types —
or, with `dm_message`, polls the bot's DMs instead of a channel. Optionally scoped to a thread
(`thread_ts`) and an allowlist of user IDs.

#### Picking the channel

In the triggers form the Slack channel is chosen from a dropdown that lazily loads the channels the
bot can see — `GET /triggers/channels`, backed by Slack's `conversations.list` — the first time a
Slack condition is shown, rather than on every page load. Selecting a channel stores its
`channel_id` (the value the poller keys on) under the hood and saves the human-readable
`channel_name` alongside it as a display cache. If the list can't be loaded — Slack unconfigured, an
API error, or a workspace the bot isn't in — the form falls back to a manual channel-ID input so a
trigger can still be created, and a saved channel that is no longer in the accessible list is kept
selected rather than silently blanked.

#### DMs: `dm_message`

`dm_message` fires on **every message the bot receives in a DM** from a user the condition allows.
It is the DM half of `bot_mention`, available on its own.

That split is the whole feature. `bot_mention` has always polled DMs — unconditionally, with no
mention required, because a DM is already addressed to the bot — but it polls them *as well as*
@mentions in every channel the bot is in. So a trigger that should answer your DMs and nothing else
could not be expressed: you had to accept a trigger anyone could fire from any channel. `dm_message`
is that trigger.

Mechanically it reuses the DM path `bot_mention` already had, so the semantics are the ones
documented above and below: one cursor per conversation in `configuration.dm_timestamps`, the first
poll baselines instead of replaying history, the bot's own messages never fire, and a DM with the
bot itself is skipped outright. The allow-list is applied by **enumeration** rather than filtering —
`SlackService.list_dm_channels` returns only the allowed users' conversations — which is why an
unrestricted condition passes `nil` rather than an empty array, since "everyone" cannot be written as
a list of IDs and an empty list means nobody. (It still paginates every IM and filters client-side,
so the allow-list narrows what is polled, not what is fetched. The poller memoizes the result per
run, keyed on the allow-list, so two conditions sharing one do not walk those pages twice.)

Leave the channel blank; `dm_message` ignores `channel_id` entirely, and `thread_ts` is rejected
(there is nothing for it to scope). `SlackTriggerHealthCheckJob` skips these conditions for the same
reason it skips `bot_mention` — there is no single monitored source to measure staleness against.

:::caution[A `dm_message` condition and a `bot_mention` condition both fire on the same DM]
`bot_mention` covers DMs unconditionally, and `dm_message` deliberately applies no mention filter.
Two conditions covering the same DM therefore each fire on it, spawning two sessions — and that
holds whether they sit on two triggers or on the *same* one, which is the likelier mistake:
`SlackTriggerPollerJob` iterates conditions, not triggers, and each one calls `create_session!`.
Nothing dedupes them, because Zimmer cannot tell an accidental overlap from a deliberate one. Pick
one per conversation.
:::

:::caution[The allow-list is open by default, and the form does not render it]
`dm_message` inherits the [three allow-list layers](#who-may-trigger-a-bot_mention-or-a-passive-listener)
below, including their default: **blank or unset means everyone**. No view renders
`allowed_user_ids`, so a condition created in the Triggers form falls through to
`SLACK_BOT_MENTION_ALLOWED_USER_IDS` — and if that is unset, any member of the workspace who opens a
DM with the bot spawns a session. Enumeration is the only gate on the DM path; there is no
second `user_allowed?` check behind it. Set the list through the API or the console, or set the env
var, before pointing a `dm_message` trigger at anything consequential. See
[the caveat](/limitations/#anyone-in-the-workspace-can-trigger-an-agent-via-bot-mention-by-default).
:::

#### Who may trigger a `bot_mention`, a `dm_message`, or a passive listener

Three layers, most specific first:

1. **The condition's own `allowed_user_ids`** (set from the triggers UI or the API), if present.
2. **`SLACK_BOT_MENTION_ALLOWED_USER_IDS`** — a comma-separated list of Slack user IDs, read from
   encrypted credentials (`mcp_secrets`) first and process ENV second. This is how a deployment
   narrows the default.
3. **Otherwise: everyone.** An unconfigured Zimmer lets any member of the workspace @mention or DM
   the bot.

Zimmer's own messages never trigger anything, whatever the allowlist says — it posts to Slack with
the same token (`AlertService`), and a `bot_mention` condition with no channel configured polls
*every* channel the bot is in, so without that rule an alert could trigger a session that alerts.
Messages from *other* apps do still qualify: bots are valid trigger sources.

:::caution[The open default means any workspace member can spawn an agent session]
With `SLACK_BOT_MENTION_ALLOWED_USER_IDS` unset, anyone who can DM the bot — or @mention it in a
channel it has been invited to — can start a session. That is bounded by the bot only ever seeing
channels it is invited to, but it is a real grant. Set the allowlist on any deployment where the
workspace is larger than the circle of trust.
:::

:::caution[`thread_ts` doesn't work for bot mentions]
`TriggerCondition` explicitly rejects it: *"thread_ts is not supported for bot_mention
conditions."* You can watch a thread for new messages, but not for bot mentions. The same
applies to the passive-listening types — they walk threads themselves.
Tracked in [#78](https://github.com/tadasant/zimmer/issues/78).
:::

#### Passive listening (`passive_listen_thread`, `passive_listen_channel`)

An @mention is how you *start* a conversation with Zimmer. Passive listening is how it stays in one:
it fires on messages that continue a conversation Zimmer is already part of, with no mention
required.

It is **two** event types rather than one, because a Trigger ORs its conditions. Carry one, the
other, or both:

| Event type | Fires on | Requires | Bounded by |
| --- | --- | --- | --- |
| `passive_listen_thread` | A new reply in a thread | Zimmer has spoken in that thread | Nothing time-based. `RECHECK_HORIZON` (45 days) only bounds how far back a thread whose parent has scrolled out of recent history keeps being re-visited |
| `passive_listen_channel` | A new top-level message in a channel | Zimmer has posted **at the top level** of that channel within `CHANNEL_ENGAGEMENT_WINDOW` | 6 hours |

Thread replies are deliberately *not* time-bounded. A reply to a thread you are in is addressed to
that conversation whenever it lands. A top-level message in a busy channel is not, which is why
"recently involved" there has to be bounded by something explicit — otherwise one message months ago
would make Zimmer a permanent listener on every message in the channel.

:::note[A thread reply is not channel engagement]
`passive_listen_channel` counts only Zimmer's **top-level** posts. A reply it left inside a thread
makes it party to *that thread* — which is exactly what `passive_listen_thread` follows — not to
everything else said in the channel. This is the narrower of the two readings available, chosen
because the cost of under-firing is a message Zimmer misses and the cost of over-firing is noise in
a channel nobody asked it into.
:::

Both sweep channels exactly like `bot_mention` — one channel if `channel_id` is set, otherwise every
channel the bot is a member of — and keep the same cursors: per-channel in `channel_timestamps`,
per-thread in `thread_timestamps` (`"channel_id:thread_ts" => last_reply_ts`), advanced for
everything fetched whether or not it fired, so a quiet spell never replays as a burst. Aged-out
threads are re-visited under the same `MAX_TRACKED_THREAD_RECHECKS` (20 per channel per poll)
budget, reading only the tail since each thread's cursor. What changes is the filter: participation
instead of mention.

A `passive_listen_channel` condition never reads threads at all, and a `passive_listen_thread`
condition never reads or writes the channel-engagement signal. Each pays only for the thread and
history calls its own signal needs — both still sweep top-level messages per channel per poll, since
that cursor is what a first-sight thread falls back to.

Participation is answered without ever re-reading a thread's history. The first time a thread is
seen there is no cursor, so the read returns the whole thread — that read decides participation.
After that, every reply Zimmer has not already inspected is in the tail, and a thread it has spoken
in is remembered in `participating_threads`, so the tail alone is enough from then on.

Channel engagement is learned from what the poll already fetches: Zimmer's own posts in the last 50
top-level messages. The newest is remembered per channel in `bot_activity_timestamps` and only ever
moves forward, so a channel stays engaged for the full window even through polls where nothing has
moved, and a tick that happens to observe *older* activity can't wind it back and disengage early.

The alert channel (`ENG_ALERTS_SLACK_CHANNEL_ID`) is excluded from that signal. `AlertService` posts
there with the same token and therefore the same user ID, so one automated alert would otherwise
mark the channel engaged and turn the whole window of it into a session per message — in the one
channel guaranteed to be noisy when things are going wrong. Threads there are unaffected: if Zimmer
actually replied in one, that is a conversation and `passive_listen_thread` still follows it.

A thread seen for the first time has no cursor of its own and falls back to the channel's, which
tracks *top-level* messages — in a channel whose conversation lives in threads that can be weeks
old. It is clamped to `THREAD_BACKFILL_HORIZON` (24 hours), so meeting a thread late costs at most a
day of catch-up rather than the entire backlog. The clamp applies to a thread's **own** cursor too,
which is only as fresh as its last re-check: across a deploy, a long outage, or a gap in the re-check
rotation below, that cursor can fall arbitrarily far behind, and replaying the whole gap would spawn
a session per accumulated reply on messages nobody is waiting for an answer to any more. That is deliberately its **own** constant and not
`CHANNEL_ENGAGEMENT_WINDOW`: it bounds a one-off backfill on discovery, which has nothing to do with
how long a channel stays engaged, and tying the two together would silently retune first-discovery
behaviour every time the channel window is adjusted.

Passive listening never fires on:

- **Zimmer's own messages**, the same self-loop rule `bot_mention` has.
- **Any other app's messages.** `bot_mention` accepts them because an @mention is an explicit
  request; a passive listener firing on every CI notification that lands in a thread it once
  replied to is exactly the noise it must not make.
- **Channel-event subtypes** — joins, leaves, topic/purpose/name changes, huddles, pins, edits
  (`PASSIVE_IGNORED_SUBTYPES`). "Sam has joined the channel" is not a conversation continuing.
  Subtypes that *are* somebody talking — `file_share`, `me_message`, `thread_broadcast` — still
  fire.
- **DMs.** Every DM to the bot is already directed at it, and a `bot_mention` condition covers DMs
  unconditionally; firing passively there would double-spawn.
- **Anything that @mentions Zimmer.** Mentions belong to `bot_mention`; the passive types own
  everything else. See below.

The allowlist is the same three layers as `bot_mention` above, including
`SLACK_BOT_MENTION_ALLOWED_USER_IDS`.

:::note[Mentions belong to `bot_mention`, on both passive types]
A mention posted inside a thread Zimmer is in is *both* a mention and a reply in a participated
thread; a mention in an engaged channel is *both* a mention and a top-level message there. Both
conditions matched, so one Slack message spawned **two concurrent sessions on identical text** —
observed in production, one per matching trigger, on every mention. `passive_candidate?` therefore
excludes any message that mentions the bot, using the same `mentions_bot?` predicate `bot_mention`
filters on; two different notions of "is a mention" would leave a gap that double-fires again.

The exclusion is unconditional: it does not check that a `bot_mention` condition would in fact pick
the message up, because conditions are polled independently and none can see the others. So a
mention falls through the gap entirely if the deployment has no `bot_mention` condition, if that
condition is disabled or scoped to a different channel than the passive one, or if the two carry
different `allowed_user_ids`. That is the intended division of labour — being addressed directly is
what `bot_mention` is for — but it is a silent drop, so the poller logs one line at `info` naming
the message and the condition that declined it.
:::

:::caution[Restraint belongs in the prompt, not just the poller]
The poller decides which messages Zimmer *sees*. It cannot decide which deserve a reply — a
teammate saying "thanks, that worked" in a thread Zimmer is in fires the trigger just as a direct
follow-up question does. A passive-listening trigger's prompt template has to make silence the
default, and it should tell the session to add its :eyes: reaction only once it has decided to
respond, so the reaction is a commitment rather than an acknowledgement. See
[the draft template](#a-passive-listening-prompt-template).
:::

:::note[`passive_listen` is deprecated, not removed]
The original single event type fired on both signals at once. It still works — a deploy of the split
must not strand a trigger that names it — and behaves as though both new conditions were present,
including the 6-hour window and the top-level-only engagement rule. The triggers form offers it only
on a condition that already carries it; the REST API still accepts it, since it is a member of
`EVENT_TYPES` like any other. Removal is tracked in
[#253](https://github.com/tadasant/zimmer/issues/253).

**Replacing it means two fresh condition rows, and a fresh condition starts with empty
bookkeeping.** Carry the old condition's cursors across, or the two new ones are worse than the one
they replace in both directions at once:

- **They over-fire.** A fresh condition baselines its *channel* cursor on the first poll, which is
  the newest top-level message — in a thread-heavy channel that can be weeks old. On the second poll
  every thread is a first-sight thread, so each replays back to `THREAD_BACKFILL_HORIZON` (24 hours).
  Every reply from the last day in every thread Zimmer is in fires at once, bounded only by the
  trigger's `max_sessions_per_minute` (above which the rest are dropped).
- **They also under-fire, permanently.** A thread is only ever discovered through its parent
  appearing in the last 50 top-level messages, or through an existing `thread_timestamps` entry. A
  thread whose parent has already scrolled past that window and has no entry is invisible — and
  stays invisible, even after Zimmer next speaks in it.

Copy `thread_timestamps` and `participating_threads` onto the thread condition,
`bot_activity_timestamps` onto the channel condition, and `channel_timestamps` onto **both** (a
first-sight thread falls back to that cursor). Editing `configuration` directly is the only way:
the trigger form does not render these keys, and `TriggerCondition::SLACK_POLL_STATE_KEYS` exists
precisely so that saving the form does not *destroy* them.
:::

:::note[No stall detection]
`SlackTriggerHealthCheckJob` skips every passive-listening event type for the same reason it skips
`bot_mention`: the condition fans out across many channels, each with its own cursor, so there is no
single "newest message" to compare against.
:::

#### Re-checking more threads than one poll can afford

A thread whose parent has scrolled past the last 50 top-level messages is only reachable through its
`thread_timestamps` entry, and each one costs a `conversations.replies` call — the synthesized parent
carries no `latest_reply`, so the cheap "nothing new here" skip cannot fire for it. Slack rate-limits
that method hard enough to have taken the whole poller down before, so the number of those calls per
channel per poll is fixed at `MAX_TRACKED_THREAD_RECHECKS`.

That number is a **budget, not a coverage cap**, and the difference matters because a live condition
here tracks hundreds of threads across its channels, most of them inside the 45-day
`RECHECK_HORIZON`. Truncating the budget to the 20 most-recently-active and dropping the rest leaves
most tracked threads never re-checked at all, and unrecoverably so: the ranking is by tracked
activity, and a reply nobody fetches never advances a tracked timestamp
([#518](https://github.com/tadasant/zimmer/issues/518)).

The budget is instead split, per channel:

- `HOT_TRACKED_THREAD_RECHECKS` (10) go to the most-recently-active tracked threads, **every poll**.
  A conversation that is actually live answers at the poll cadence.
- The remaining 10 walk everything else in a stable order, resuming from where the previous poll
  stopped — the position is remembered per channel in `thread_recheck_cursors`.

So a channel with *n* eligible tracked threads sweeps all of them every `ceil((n - 10) / 10)` polls
— 17 minutes for 172 threads at the one-minute cadence — while re-checking the same number of
threads per poll as a truncation would. The wait is latency, not loss: a thread's cursor is
untouched while it waits its turn, so when its slot comes up the fetch still starts from the last
reply Zimmer saw. A channel tracking fewer threads than the budget rotates nothing and writes no
cursor.

Two things the budget does *not* bound, both of which matter when a thread is reached across a long
gap rather than at the ordinary cadence. `conversations.replies` paginates at 100, so a thread with
more than a page of unfetched replies costs more than one call — the budget bounds threads per poll,
not calls. And passive listening would fire on every reply in that backlog, which is why the
`THREAD_BACKFILL_HORIZON` clamp above applies to a thread's own stale cursor and not only to a
first-sight one.

#### A passive-listening prompt template

A starting point for the trigger's `prompt_template`, tuned for restraint. `{{text}}`, `{{author}}`,
`{{channel}}` and `{{link}}` are interpolated by `Trigger#interpolate_prompt`.

```text
A message landed in #{{channel}}, in a Slack conversation you are already part of.
Nobody @mentioned you. You are here because you have spoken in this thread before,
or you posted in this channel within the last few hours.

Author: {{author}}
Message: {{text}}
Link: {{link}}

Your default is to say nothing. Most messages in a conversation you are part of are
not for you, and a wrong guess is worse than silence.

Read the thread with the slack-workspace MCP server before deciding anything.

Respond ONLY if one of these is clearly true:
- The message asks you something, or asks for something you were doing.
- It continues a task you were working on in this thread — an answer to a question
  you asked, a review of work you delivered, a report that something you shipped is
  broken.
- It is a direct instruction that plainly lands on you given what you were doing.

Stay silent if any of these is true:
- It is two people talking to each other, even about work you did.
- It mentions a topic, repo, or PR you touched, without asking you for anything.
- It is an acknowledgement, a reaction, or small talk ("thanks", "nice", "lol").
- You are unsure. Ambiguous means silent. Do not split the difference by posting a
  short reply just in case.

If you are staying silent: add NO reaction, post NOTHING, and archive your own
session immediately. That is a successful outcome, not a failure.

If you are responding: FIRST add an :eyes: reaction to the message, so the humans
know you have picked it up. The reaction is a commitment to reply — never add it
before you have decided to. Then do the work and reply in the thread.
```

### `schedule`

Either recurring (`interval` + `unit`, or `time` + `day_of_week` + `timezone`) or one-time
(`scheduled_at`). `ScheduleTriggerJob` is scheduled `* * * * *`, so a schedule is
minute-resolution. That is the cadence chosen for the job, not a platform limit — six-field
cron with a seconds field works, and three other pollers use it
([Background jobs](/operate/background-jobs/)).

#### When a new recurring schedule first fires

The two families of `unit` answer that differently, because only one of them names a
wall-clock instant to wait for.

`minutes` and `hours` are pure intervals. "Every 15 minutes" has no anchor time to miss, so a
newly created one is due on the next tick, and that first fire becomes the anchor the interval
is measured from thereafter.

`days` and `weeks` do have an anchor — `time`, plus `day_of_week` for weekly, both required by
validation — and it governs the first fire exactly as it governs every later one. **A schedule
first fires at the first configured slot that arrives after it was created.** Create "every day
at 03:00 America/Los_Angeles" at 01:00 and it runs at 03:00 that same morning; create it at
05:00 and its first run is 03:00 the *next* day. The 03:00 slot that passed before the schedule
existed was not missed — there was nothing there to miss.

That reading is deliberate, and the alternative is worse than it looks: treating "has never fired"
as "is due" fires a daily schedule within a minute of being created, at whatever hour that happens
to be — and because firing advances `last_triggered_at`, it *consumes* that day's slot, so the run
you actually asked for never happens
([#447](https://github.com/tadasant/zimmer/issues/447)).

The comparison is wall-clock in the condition's own `timezone`, never UTC, so a schedule keeps its
local hour across a DST change rather than sliding by one.

**Creation is the only arming instant, and two edits slip past it.** Re-enabling a schedule that
was disabled when its slot passed, and changing the `time` on one that has never fired, both leave
the original creation instant in place — so either can still fire once at an arbitrary hour, the
same symptom in miniature. Closing that needs a stored arming timestamp rather than a derived one
([#745](https://github.com/tadasant/zimmer/issues/745), and
[Limitations](/limitations/#a-re-enabled-or-retimed-schedule-can-still-fire-off-slot-once)). A
schedule that has fired at least once is unaffected either way.

#### When a one-time fire fails

A one-time trigger whose fire raises is **not** destroyed. `ScheduleTriggerJob` parks it in
the `failed` status, records `failed_at` and `last_error` on the row, and alerts. The trigger
stays in the list at `/triggers` with a red **Failed** badge and the error that stopped it, so
"wake me at 6am to check the deploy" cannot quietly become "you are not woken, and you find out
at 9".

`failed` is a third status alongside `enabled` and `disabled`, not a flavour of `disabled`:
"you turned this off" and "this tried to run and could not" are different facts. Every firing
path filters on `status = "enabled"`, so a failed trigger fires no more often than a disabled
one — that status, not a bumped timestamp, is what closes the infinite-retry loop.

Which is why the failure path deliberately leaves the condition's `last_triggered_at` alone.
The schedule stays *due*, so pressing **Re-arm** on the trigger (or calling `action_trigger`
with `action=toggle`) clears the failure and the wake fires for real on the next minute's tick.
No edit, no re-creation. Every route off `failed` — the toggle, the edit form, the REST API,
`action_trigger` — clears `failed_at` and `last_error`, so a recovered trigger never keeps
advertising the failure it recovered from.

One failure does not re-arm, and does not pretend to. A raise from the cleanup that *follows* a
successful fire (holding the wake group) arrives with the schedule already consumed
and the session already created, so re-firing would duplicate it. `Trigger#spent_one_shot_wake?`
is what the trigger page and the alert read to tell the two apart: in that case they say the
schedule was consumed and ask you to check the session rather than offering a re-arm that would
deliver nothing.

`CleanupStaleTriggersJob` skips failed triggers in both of its sweeps, and
`Trigger#hold_wake_group!` skips them too. A parked trigger is lapsed by definition, so the
lapsed-schedule ground matches every one of them, and the consumed-wake ground matches a strict
subset of those sooner — the one failure that does not re-arm is precisely the one that arrives
with its schedule already spent. And in the triple-wake pattern below, a sibling that fires
successfully later would otherwise delete the record of the one that tried and could not. All of
them would delete the evidence as a side effect, which is the silent loss the parking exists to
prevent. Only you clear a failed trigger — which also means nothing bounds how many
accumulate, so a systemic fault leaves a list to clear by hand
([Limitations](/limitations/#a-failed-one-time-wake-does-not-retry-itself)).

A recurring schedule behaves differently on a bad tick: it advances `last_triggered_at`, stays
enabled, and tries again on its next interval.

### `ao_event`

Fires on an internal Zimmer event. The events divide by their **subject** — what the event is about —
and the subject decides which rules apply:

| Event | Subject | Emitted by |
| --- | --- | --- |
| `session_needs_input`, `session_failed`, `session_archived` | a Session | the state machine's `pause` / `fail` / `archive` callbacks (deferred via `after_all_transactions_commit`, so the row is visible to the job) |
| `account_needs_reauth` | a `ClaudeAccount` | `ClaudeAccount`'s status-transition callback, when a runtime account's refresh token dies for good |

For a **session** event: with `watched_session_id` it's session-scoped and one-shot. Without it, it's
a broadcast, and it only fires for `is_autonomous` sessions.

#### `session_needs_input` means "came to rest", and it is settled before it fires

`failed` and `archived` are terminal: once a session is there, it stays there, and the event can be
delivered the moment the transition commits. `needs_input` is not terminal, and that asymmetry used
to be invisible.

`pause` runs at **every turn boundary**, including the boundaries a session leaves again
immediately. Two of them are routine:

- A session asleep on its own `wake_me_up_later` wakes, takes a turn and sleeps again. `pause`'s
  own `execute_pending_sleep` runs it straight back to `waiting`, *inside the same callback*, so
  the `needs_input` leg lasts microseconds.
- A session pauses with a message queued for it. `EnqueuedMessageDrainJob` resumes it a few seconds
  later.

Neither is a session that needs anything, but both emitted `session_needs_input` and woke every
watcher subscribed to it. Because a fired one-time wake destroys its siblings, each spurious wake
cost the watcher a full agent turn *and* the re-registration of every wake it still wanted — the
"flap storm" that production router session #9964 hit four times in 25 minutes while its one healthy
child cycled through the open-pr skill's bounded self-wake.

So `session_needs_input` is now **settled**:

1. `SessionStateMachine#fire_settled_needs_input_ao_event` enqueues `AoEventTriggerJob` with a
   `wait:` of `NEEDS_INPUT_SETTLE_WINDOW` (30 seconds) and a marker — the same
   `custom_metadata["needs_input_count"]` counter the debounced push notification already used.
   One `pause` bumps the counter once and hands the same marker to both consumers.
2. When the job runs, `AoEventSubject::SessionSubject#stale?` drops the event unless the session is
   still `Session#resting_in_needs_input?`, and unless the marker still matches — which is what
   supersedes an event a later transition has already replaced.

`session_failed` and `session_archived` are untouched: no delay, no re-check, because a terminal
state cannot flap.

#### `resting_in_needs_input?` asks about status, and only status

That looks too weak to do the job, and it is worth saying why it is not — and why the richer
versions are worse.

Every boundary this suppresses leaves `needs_input` for somewhere else. `execute_pending_sleep`
runs *synchronously inside the pause callback*, so a session that slept on its own wake is already
`waiting` before the job is even enqueued; a session whose queued message drained is `running`,
because `EnqueuedMessageDrainJob::DELAY` is well inside the window. Status catches both.

The two richer disqualifiers — a lingering `pending_sleep`, a still-pending enqueued message — can
only *still* be true when the window closes if the thing that was going to move the session has
failed. `sleep!` raised and left the flag behind. The drain exhausted `MAX_ATTEMPTS` and left the
rows `pending` on an idle session, or one of its three `skip_reason` refusals is holding the message
indefinitely. Those sessions are stuck at rest, and they are exactly the ones a watcher must hear
about — so treating them as "not a rest" would not delay the wake, it would **lose** it. `pause`
only fires from `running`, so once a session is at rest nothing re-emits the event; there is no
second chance.

The cost of the narrow check is an occasionally early wake — a drain whose first attempt fails
resumes the session at `DELAY + RETRY_DELAY`, just past the window. That trade is the right way
round. A wake that arrives seconds early costs a re-poll; a wake that never arrives costs a router
its whole backstop interval.

#### What is and is not covered

The **immediate-fire path** (`Trigger#fire_ao_event_immediately_if_state_matches`) enqueues the same
job, so it runs through the same rest check. Registering a watcher on a session sitting in
`needs_input` still fires at once — but if that session gets going again before the job runs, the
fire is dropped rather than delivered against a session that has moved on. It carries no marker and
no wait, which is also how `DISPATCH_LATENCY_WARN_THRESHOLD` tells it apart from a settled job and
declines to discount its latency.

The one thing the rest check cannot do for it is recognise a **recovery pause**. That path enqueues
with no marker and no wait, so the settle window never applies, and `resting_in_needs_input?` — status
and nothing else, by design — is true for a session parked by a recovery sweep. So the immediate-fire
path asks the same question the `pause` callback asks,
[`announcement_deferred_to_recovery_sweep?`](/sessions/lifecycle/#which-pauses-announce-themselves),
and leaves the watcher armed instead of firing it. A frozen category still fires at once, because no
sweep is coming to make the announcement later.

What that buys is the wake *set*, not a promise that a lone `session_needs_input` condition is
enough. The continued session can go on to archive — which prunes every non-`session_archived`
condition watching it — or to fail, and a recovery that keeps succeeding clears the attempt counter
along with the rest of `Session::STALE_RETRY_METADATA_KEYS`, so the give-up branch may never be
reached. Those outcomes are what the other two events and the `wake_me_up_later` deadline are for,
and keeping that set intact is the whole point of not firing here.

**Broadcast (unscoped) `session_needs_input` conditions are settled too.** They ride the same job, so
a broadcast trigger no longer fires on a turn boundary either — and it inherits the 30-second delay.

`block_on_elicitation` emits through the settled path as well. An elicitation the user answers in
seconds flips the session back to `running` via `unblock_from_elicitation`, which is a turn-boundary
flap by another name; one that is still waiting on a human survives the window and wakes the
watcher, which is right, because that is a session genuinely asking for something.

The settle window is a constant, not a per-trigger option. A wake on a transition the watched
session had already left is not useful to any caller, so there is no posture to configure; the
knob would only be a way to get it wrong.

An **account** event has no session to watch, no autonomy flag to consult, and no session the trigger
could have created — so it is always broadcast, and `watched_session_id` is rejected on it outright.
It is throttled at the source instead: at most one fire per account per 12 hours, released when a
human completes a login for that account. See
[a dead account tells you so](/auth/harness/#a-dead-account-tells-you-so).

`AoEventSubject` is where that split lives. Adding a third kind of subject means adding a class there
and a name to `TriggerCondition::AO_EVENT_NAMES`; `AoEventTriggerJob` does not change.

Both kinds are creatable from the /triggers form and from the MCP `action_trigger` tool. To wake
*yourself* on a session you are waiting for, use `wake_me_up_when_session_changes_state` instead — it
creates the one-shot wake **and** puts your session to sleep.

Two guards apply to `ao_event` specifically, because a broadcast session condition fires on every
autonomous session's transition and loop prevention is only per-trigger — two of them (one on
`session_needs_input`, one on `session_archived`) would otherwise feed each other unbounded:

- **A broadcast session condition created through `action_trigger` gets a default
  `max_sessions_per_minute`** (`BROADCAST_SESSION_AO_EVENT_BURST_CAP`) when the caller names none.
  Send the value explicitly to choose your own, including no cap. Account events and session-scoped
  wakes are exempt: the first is already bounded at source, and a cap there could only drop alerts
  during the mass failure it exists to report; the second fires at most once.
- **An update that drops `watched_session_id` from a session-scoped condition is refused.**
  `configuration` replaces a condition's user-facing keys, so omitting it would silently widen a
  one-shot wake into a broadcast — including one of the rows `wake_me_up_when_session_changes_state`
  creates. Delete the condition and add a new one if a broadcast is genuinely what you want.

#### When an `ao_event` fire fails

The same two-shapes rule as schedules, drawn along the scoping line rather than the
recurring/one-time line — because for `ao_event` that *is* the line.

A **session-scoped** wake is one-shot, and it only ever fires on its watched session's
transitions. If firing it raises and it is left enabled, "it will try again on the next
transition" is a promise the event stream cannot keep: the watched session may have just made
its last transition, which is precisely the `session_failed` / `session_archived` case agents
schedule most. So `AoEventTriggerJob` parks it as `failed` — same status, same badge, same
`failed_at` / `last_error` as a failed schedule — and alerts. The condition's `last_triggered_at`
is left alone for the same reason as above: the status closes the retry loop, so re-enabling
the trigger re-arms an unspent wake. The alert says plainly that a re-arm only helps if the
watched session transitions again, and that a terminal one never will.

A **broadcast** condition is not parked. It is recurring by nature — every autonomous session's
transition fires it — so it alerts, stays enabled, and fires on the next matching transition.
Parking one would silently stop every future wake, which is the same failure this parking exists
to remove, pointed the other way.

A raise *after* the wake was delivered splits in two, and the alert distinguishes them, because
"a session was created" and "the one-shot guard was recorded" are different facts and
`condition.update!` sits between them. If the guard did persist, re-arming delivers nothing and
the alert says so — the same distinction the schedule path draws. If the guard is what failed,
the session exists *and* the condition is still armed, so re-arming would create a **second**
session; the alert warns against it rather than inviting it.

`Trigger#spent_one_shot_wake?` is the predicate behind both the alert and the trigger page, and it
covers both one-shot shapes — a one-time schedule and a session-scoped `ao_event`. A predicate that
saw only schedules would offer every parked state-change wake a "Re-arm" button with no caveat.

### `system_event`

Fires when the **deployment** changes state, rather than a session. Two events:
`quota_available`, the account pool going from serving nothing to serving something; and
`no_sessions_in_progress`, the fleet having had room for more work for five minutes.

It is a separate condition type rather than a fourth `AO_EVENT_NAMES` entry because every decision
`ao_event` makes is about a session — watched-session scoping, the `is_autonomous` filter, the guard
that stops a trigger firing on the session it created. A fleet-wide event has no session at all.

Every system event is **edge-fired**: a monitor owns the detection and decides when the deployment
ENTERED the state, and `SystemEventTriggerJob` does the firing. `QuotaAvailabilityMonitor` owns
`quota_available`; `FleetIdleMonitor` owns `no_sessions_in_progress`. System events are broadcast and
recurring by nature: every enabled trigger carrying a matching condition fires, the condition is
never spent, and the trigger is never auto-deleted. A fire that raises alerts and stays enabled —
parking it would silently stop every future recovery wake.

#### `quota_available`

This is what wakes quota-parked spot sessions. The shipped trigger spawns one `fleet-maintenance`
session running the `awaken-waiting-sessions` skill, which decides — in precedence order, against the
spot thresholds and the concurrency ceiling — which `waiting` sessions start. See
[When the pool runs dry](/auth/harness/#when-the-pool-runs-dry).

Two things have to be true for it to fire: the account pool has to cross from serving nothing to
serving something, **and** the spot gate must not be holding spot work at a window's
`at_utilization_limit`. The pool's edge alone is not enough — an account is `available` again once
Anthropic's own window clears, while the gate measures the pool's spend against the operator's
reserve and pacing curve, so the two can disagree for days at a time. A rising edge observed against
a window-held gate is **deferred**, not spent: the stored level stays `false` and the next
fifteen-minute sweep asks again, so the event fires as soon as the hold lifts rather than never.

A **full fleet** (`fleet_at_cap`) is deliberately not a reason to defer, even though it leaves the
woken session just as little to hand out. The two holds run on different clocks: a window's moves on
the window's clock, slower than the fifteen-minute sweep, while cap contention moves on a session's,
much faster — so a fleet habitually at its cap would show `fleet_at_cap` to every sweep while
ordinary held spot sessions took the freed slots on their own ten-minute ladder, starving the
outage-parked sessions whose only wake path this is. Firing into a full fleet costs one session;
never firing costs the whole parked population.

Parked **priority** sessions never wait on any of this — `QuotaResetCheckerJob` resumes them
directly, ungated. But the precondition applies to the *event*, not just to the shipped trigger: an
operator trigger listening on `quota_available` to do priority work is deferred by the spot gate too,
even though nothing would have held that work.

#### `no_sessions_in_progress`

Fires when the deployment has been **running fewer sessions than its configured ceiling** for the
whole of a configured stretch — three and five minutes by default. It is the "the fleet has room for
more work" signal, so a job that hands work out has a second way to be started besides its daily
schedule.

Only sessions with a **turn in flight** count. Sessions in `waiting` do not, of any class, and neither
does a `running` row asleep on its own future wake — see [What counts as idle](#what-counts-as-idle).

The name is a wire name: it is stored as a condition on live trigger rows, so it kept its original
spelling when the boolean behind it became a number. Read it as *few enough* sessions in progress.

##### The three knobs

All three live on `app_settings` and are set from the **Backlog top-up** card on `/inference`, or over
MCP with `action_spot_policy` `set_top_up`. `FleetIdleMonitor` re-reads them on every sweep, so a
change takes effect within the minute and needs no deploy.

| Column | Default | Means |
| --- | --- | --- |
| `fleet_idle_max_sessions` | 3 | the fleet counts as idle enough while **fewer than** this many sessions have a **turn in flight** |
| `fleet_idle_threshold_minutes` | 5 | how long it must stay under that ceiling first |
| `fleet_idle_min_fire_interval_minutes` | 60 | the floor between two fires |

**`fleet_idle_max_sessions = 1` means simply "nothing running"** — the boolean this replaced. The
reason the default is 3 rather than 1 is that requiring literally zero made the event a poor fit for
its own purpose. Measured over one 10.6-hour window, a ten-slot fleet ran at two slots and fired this
event twice, while 109 items sat on the work backlog — the fleet had eight free slots and the only
thing standing between them and the backlog was the last running session.

##### What counts as idle

*Idle* means the fleet has little enough to do, never that it cannot do anything. Confusing the two is
the expensive mistake — it hands more work to a deployment that is already blocked, at the moment it
has least room for it — so three questions all have to answer no:

| Question | Why it counts |
| --- | --- |
| Does the fleet have `fleet_idle_max_sessions` or more **turns in flight**? | One population and one number, every runtime and every scheduling class — a running Codex session occupies the deployment as much as a Claude one. Sessions in `waiting` do not count, of any class, and neither does a `running` row asleep on its own future wake with nothing queued for it. A turn merely waiting for a worker does — see [What "in flight" counts](/sessions/spot-and-priority/#what-in-flight-counts-and-what-it-does-not) |
| Any session parked on an auth outage, **either class**? | A park is the clearest statement Zimmer makes that work exists and cannot run. Deliberately **not** a threshold and not scoped to spot: an outage parks priority sessions too, `QuotaResetCheckerJob` resumes those on its own schedule, and one parked session is evidence about the *pool* rather than about how busy the fleet is |
| Can the account pool serve anything? | Asked of the pool directly, via `QuotaAvailabilityMonitor.pool_available?`. An empty pool makes a quiet fleet a symptom rather than an opportunity. Deliberately **not** `AppSetting#quota_pool_available`: that column is an *announcement latch*, held at `false` through a recovery whose event has not fired yet, and a recovery deferred at the spot gate says nothing about whether the pool can serve |

##### Why a `running` row is not always a session running

`running` is stamped when a turn is **handed to** a session, not when a worker starts executing it,
and the `agents` queue (default 8 threads) sits between the two. So the column holds turns being
executed and turns waiting for a worker at once — both count, because a waiting turn takes the next
free slot — plus a third population that does not: a row asleep on its own future wake with no
`AgentSessionJob` at all, running or queued. Nothing will happen to those until the wake fires, so
they can consume nothing in the meantime.

[#957](https://github.com/tadasant/zimmer/issues/957) is what named this. A fleet reporting 15
sessions at a ceiling of 7 had 8 agent processes alive; the rest were turns queued behind the pool,
and three of them were routers that had already gone back to sleep. Both `/inference` cards now print
the split, and `RunningTurns` is the one place the rule lives.

##### Why `waiting` sessions do not count

Until 2026-09-04 the first row counted spot sessions dormant in `waiting` too, against the same
ceiling, on the argument that a deployment sitting on a spot queue should not be handed more. That
was wrong about what `waiting` is.

`waiting` is Zimmer's only resting state short of a terminal one, so it holds sessions asleep on
their **own** self-scheduled wake alongside anything genuinely queued — and the sleepers dominate.
The biggest single population is the [`open-pr`](/sessions/lifecycle/) terminal step: a session that
has **finished** its work and is sleeping on its open PR, for tens of minutes at a time, occupying
nothing. Counting those made a deployment with 5 sessions running and 8 asleep report itself as
holding 13 against a ceiling of 7 — "at its work ceiling", no top-up due — while more than half its
slots sat empty.

The spot queue is not an exception. A dormant spot session is work waiting for capacity, which is the
condition top-up exists to relieve rather than a reason to withhold it, and the session this event
spawns is **priority** and ungated: it fills an idle machine rather than deepening the queue it would
once have been counted against. Queue depth is a statement about the budget the
[spot gate](/sessions/spot-and-priority/) is pacing to, and the gate holds spot work whether or not
this event fires.

What the queue count was really doing was damping churn — keeping the moment between one session
ending and the next starting from reading as an idle fleet. **`fleet_idle_threshold_minutes` absorbs
that directly**, and it is why dropping the queue from the count is safe: the fleet has to stay under
the ceiling for the *whole* stretch, and `record_busy!` restarts that clock unconditionally the
moment any session enters `running`. A fleet that flaps never accumulates a stretch, at any ceiling.

The `running` count is scoped `not_in_frozen_category`, matching `CleanupOrphanedSessionsJob` and
`DeploymentRecoveryJob`: a `running` row in a frozen category is one nothing will ever repair, and
counting it would pin the monitor to "busy" forever with nothing to say why.

##### Why a latch as well as a level

This is the one system event where the analogy to `quota_available` needs care. A pool recovering is
naturally a transition; "the fleet is under its ceiling" is a **state** that stays true for as long as
the deployment is quiet, so a monitor that fired whenever it observed the state would fire every tick,
forever, precisely while nothing was happening. `FleetIdleMonitor` turns it into an edge with two more
columns on `app_settings`:

| Column | Means |
| --- | --- |
| `fleet_idle_since` | when the fleet was first observed under its ceiling — the clock the threshold is measured against. `NULL` means the fleet was at or over it at the last observation |
| `fleet_idle_event_fired_at` | when the event last fired. Two jobs: within one quiet stretch it is the **latch**, and across stretches it is the **cooldown** clock |

`fleet_idle_since` is cleared the moment the fleet has work again, and that happens two ways:
`FleetIdleCheckerJob` observes it on its next tick, and `SessionStateMachine` writes it directly the
moment any session enters `running`. The second is what makes a session that starts and finishes
inside one tick count — sampling alone would never see it, and the latch would stay spent against a
fleet that had gone back to work. (It is an `after_commit`, so it does not cover a `update_column`
write of `status`; nothing does that today, and the sweep re-arms on its next tick regardless.)

##### The latch is not enough on its own

The reason is circular and easy to miss: **the fire spawns a session, that session enters `running`,
and running is exactly what re-arms the latch.** On a deployment quiet for some other reason — an
empty backlog, a gate that declines — the steady state would be one spawned session every five
minutes plus however long it takes to finish, forever. The event's own answer would keep
re-qualifying it.

`fleet_idle_min_fire_interval_minutes` — one hour by default — is the floor under that, which is why
`fleet_idle_event_fired_at` is *not* cleared when the fleet gets work. "Has this stretch already
fired" is the comparison `fired_at >= idle_since`, not mere presence.

**A ceiling above 1 makes the cooldown the load-bearing half of that pair, and the real cap on how
often work gets started.** With the old boolean the fire's own session took the fleet from zero
running to one, which ended the stretch outright and left the cooldown to matter only on the next
one. Under a ceiling the fleet is routinely still under it while the spawned session runs, so the
stretch does not end on its own — the cooldown is the only thing between the deployment and a fire
per threshold. At the shipped 60 minutes that is at most **24 top-ups a day**, whatever the ceiling
is set to. Retune the interval, not the ceiling, to change the cadence.

The re-arm on `running` stays **unconditional** rather than becoming ceiling-aware, and that is
deliberate. A version that only cleared the clock when the fleet climbed *above* its ceiling would
leave `fleet_idle_since` frozen behind `fleet_idle_event_fired_at` on a fleet that never gets that
busy, the latch would hold forever, and the event would fire exactly once in the deployment's life.
Ending the stretch is what hands the cadence to the cooldown.

The fire itself is a guarded `UPDATE` on `(id, fleet_idle_since, fleet_idle_event_fired_at)` rather
than a plain write, so a re-arm landing between the read and the write cannot be clobbered from a
stale record — losing that race means the fleet got work while the monitor was deciding, which is
exactly when it must not fire.

One more asymmetry. An undelivered `quota_available` fire **re-arms** its edge, because the sessions
it exists to wake are still parked and the next sweep should try again. An undelivered
`no_sessions_in_progress` fire does not: nothing is waiting on it, and re-arming would produce one
fire per tick for as long as the quiet lasted — the exact loop the latch exists to prevent.

### `github_label`

Fires when one of the watched labels is **added** to a pull request or an issue in one of the
watched repos.

```json
{
  "repos": ["tadasant/zimmer", "tadasant/zimmer-catalog"],
  "target": "pull_request",
  "labels": ["ready to merge"]
}
```

`target` is `pull_request` (the default) or `issue`. Any *one* of `labels` firing is enough — they
are ORed, not ANDed. Up to 20 repos.

Labels are matched **case-insensitively**, because GitHub's `label:` search qualifier is. Typing
`Ready To Merge` for a repo label named `ready to merge` works.

The motivating flow: the `open-pr` skill applies `ready to merge` as its terminal act, and a
`github_label` trigger on that label is what picks it up and fires the merge gate.

### `github_issue`

Fires when a new issue is opened in one of the watched repos.

```json
{
  "repos": ["tadasant/zimmer"],
  "exclude_labels": ["hold issue work gate"]
}
```

#### Opting an issue out, with a label

`exclude_labels` is optional, and it is an **escape hatch for the issue's author**, not a filter for
whoever configured the trigger. An issue opened carrying *any* of those labels does not fire the
condition; every other issue still does. That is what makes it usable as a default-on gate you can
step around deliberately — the motivating case being a batch of issues filed at once, none of which
should each spawn a session.

The exclusion is expressed as a negation in the search itself, one `-label:` term per entry:

```
is:issue (repo:tadasant/zimmer) created:>=… -label:"hold issue work gate"
```

Negations are ANDed, so an issue is returned only if it carries **none** of the excluded labels. An
excluded issue is never seen by the poller at all: it does not fire, and it does not advance the
cursor past itself either.

:::caution[The label has to be there when the issue is created]
The exclusion is evaluated at *search* time, and the poll runs every minute. Label the issue as you
open it —

```sh
gh issue create --label "hold issue work gate" --title "…" --body "…"
```

— rather than opening it and adding the label a moment later. A label added after the fact races the
next tick, and if the tick wins, the trigger has already fired.

*Removing* the label later is not a reliable way to un-hold an issue either. The poller re-queries a
30-minute window behind its cursor, and that cursor advances only when an issue **fires** — so the
window trails the last fired issue rather than the clock. Un-holding re-exposes the issue when
nothing else has fired past it since, and does nothing once something has. Open a fresh issue when
you want the gate.
:::

Only a **widening** rebases the cursor: adding a repo. Editing `exclude_labels`, or removing a
repo, does not — a `github_issue` condition's cursor is a timestamp, and a narrowing cannot make an
old issue look new, so throwing it away would lose live position for nothing. Adding a repo is
different: the cursor advances only when an issue *fires*, so on a quiet trigger it can be months
behind the clock, and querying from there would return the new repo's entire back catalogue.

The rebase happens **at the moment of the edit**, not at the next tick: `last_issue_at` restarts at
"now" as the edit is saved, so nothing opened in the up-to-a-minute gap before the next poll falls
through the crack between the two.

What the rebase does **not** do is throw the rest of the state away. The poller queries 30 minutes
*behind* the cursor to absorb index lag, so a cursor of "now" still returns the last half hour —
and an emptied fired-key set made every issue already fired in it read as fresh, spawning a
duplicate session for each ([#759](https://github.com/tadasant/zimmer/issues/759)). The fired keys
survive the edit. The newly-watched repo is held back by `issue_repo_baselines` instead: a
`"owner/repo" => timestamp` map saying when each repo joined the scope, which the poller compares
against an issue's `created_at`. A first poll stamps every watched repo the same way — at the
*condition's* `created_at`, not the tick's, so an issue opened in the minute between saving the
trigger and the first poll is still an event. That is what makes "issues that predate the condition
are history" true rather than merely intended.

Because the comparison is on *creation* time, it holds however late GitHub indexes an issue — and
because it is per repo, the lag window stays fully live for the repos already being watched. An
issue opened seconds before the edit in a repo watched all along, and indexed only afterwards,
still fires. An entry is dropped once the cursor has carried the window past it, so the steady
state carries none.

:::note[Why the two GitHub types baseline differently]
A `github_label` condition keeps a per-item seen-set, so `baseline_scope` records *what its
baseline covers* and the set itself never has to move. A `github_issue` condition has a cursor, and
a cursor has to restart or it re-reads history — so it restarts, and `issue_repo_baselines` carries
the "what" the cursor cannot.
:::

### What a GitHub-triggered session receives

The prompt template can use `{{repo}}`, `{{number}}`, `{{link}}`, `{{title}}`, `{{author}}`,
`{{text}}` (the body), `{{labels}}` and `{{event}}`.

A template that names *none* of them gets the item appended as a context block instead, so a
GitHub-triggered session always knows its repo, number and URL without re-fetching them.

### The state-vs-event problem, and what Zimmer chose

"A label was added" is an **event**, but a poll can only observe **state** — the label is
*currently* there. A timestamp cursor cannot bridge that gap: a PR's `updated_at` moves for every
push and comment, so a cursor would either re-fire a still-labelled PR forever or miss a label
added during a quiet moment.

So `github_label` conditions keep a **seen-set**, not a cursor. Each tick asks GitHub for the set
of open items that currently carry a watched label, keys them as `owner/repo#number:label`, and
fires on the *difference* against the previous tick. That set then becomes the new seen-set.

A key is not dropped from the seen-set the instant it is missing, though. GitHub's search index is
eventually consistent, so a still-open, still-labelled PR can vanish from one tick's results and
return on the next. Treating that single miss as a label removal drops the key, and the reappearing
PR then looks new and re-fires a duplicate session — the label poller's version of the index lag the
`github_issue` path below guards against. So a missing key is **retained through a short grace
window** (`GithubTriggerPollerJob::REMOVAL_GRACE_TICKS` consecutive misses — roughly three minutes at
the one-minute cadence, tracked in the companion `seen_missing_counts`) before it is accepted as
genuinely unlabelled. A real removal simply takes that long to register.

The seen-set carries a companion, `baseline_scope`: the repos, target and labels it was built
against. It exists to answer the one question the set alone cannot — *is this item new, or has it
been sitting there labelled since before its repo was watched?* Adding a repo to a live condition
therefore baselines only that repo; the condition keeps firing for the repos it was already
watching. Before that was recorded, any edit to `repos` or `labels` dropped the whole seen-set, and
the next tick absorbed everything currently labelled — including PRs labelled in the minutes since
the edit, in repos that had been watched all along. Those never got a session and never would, since
they were now in the seen-set
([#647](https://github.com/tadasant/zimmer/issues/647)).

A condition that has polled before and comes back with **no** seen-set at all is now an anomaly
rather than a routine consequence of editing it. It is still re-baselined conservatively — firing a
session for every currently-labelled PR would be the worse failure, since on the merge gate that
means a gate session per already-handled PR — but it **alerts** rather than doing it silently, naming
the items it absorbed so they can be checked and, if one never fired, replayed with the trigger's
`invoke`.

The semantics that follow — all of them covered by tests:

| Situation | What happens |
| --- | --- |
| Label added to a PR | Fires **once**. |
| PR keeps the label across many ticks | Never re-fires — the key stays in the seen-set. |
| PR already carried the label when you created the trigger | **Does not fire.** The first tick records a baseline and fires nothing. |
| PR briefly drops out of the search (index blip) then returns | **Does not re-fire.** The key is held through the grace window, so the reappearance is not seen as new. |
| Label removed, then added again | Fires **again**, once the removal has persisted through the grace window. Removal eventually drops the key; re-adding makes it new. |
| Two watched labels added to one item | Two events, so two sessions. Keys are per `(item, label)`. |
| A tick is skipped (deploy, rate limit) | Harmless. The seen-set is state, not a cursor, so the next tick still sees the label. Misses are only counted on a real poll, so downtime never expires a key's grace early. |
| PR is closed or merged while labelled | Drops out of the `is:open` search; after the grace window it leaves the seen-set. If it is reopened still labelled, it fires again. |
| You add a repo or a label to the condition | Only the **addition** is baselined. Items already labelled in the newly-watched repo or under the newly-watched label are absorbed rather than stampeded into sessions; labels added in the repos it was already watching still fire as normal. |
| You change the condition's `target` (PRs ↔ issues) | Full re-baseline, firing nothing. A repo numbers its issues and its PRs from one sequence, so the seen-set's keys stop denoting the same items. |
| A `reuse_session` trigger *drops* the follow-up (target session busy) | Not counted as a fire. The item stays unseen and is retried next tick, rather than the event being silently consumed. |
| Session creation fails **before** a session exists | The item is not recorded, so the next tick retries it. |
| Session creation fails **after** the session row exists | Counted as a fire. A session exists for that label; re-firing would spawn a second one. See below. |

`github_issue` conditions are genuinely event-shaped — an issue's creation time never changes — so
those use an ordinary `created_at` cursor. Two wrinkles, both of which would otherwise lose issues
silently:

- GitHub's `created:` qualifier has only *second* granularity, so a strict `>` would drop an issue
  that shared its second with the previous tick's newest. The cursor is inclusive (`>=`).
- GitHub's search index is eventually consistent **and unordered** — of two issues opened seconds
  apart, the newer can be indexed first. A cursor that advanced to the newer one would then never
  see the older. So each tick re-queries a **30-minute window behind** the cursor
  (`GithubTriggerPollerJob::INDEX_LAG_GRACE`), and a set of already-fired keys covering that window
  is what stops the re-query from firing them twice. Observed indexing lag in practice is seconds;
  an issue indexed more than 30 minutes late is missed.
- That window reaches back *through* a baseline, so the cursor alone cannot say "everything that
  already existed is history". `issue_repo_baselines` says it separately — when each repo joined the
  condition's scope — and the poller refuses anything created before its repo's entry. See the
  re-baselining section above.


In both cases state advances only for items that actually produced a session. A failure to create
one leaves the item to be retried on the next tick rather than swallowing it.

#### "Produced a session" is not "returned cleanly"

Creating a session is two steps, and only the first is a database write. `Session` commits the row,
then enqueues the one `AgentSessionJob` the session's first turn rides on, and the trigger keeps
working after that — repointing its reuse pointer, bumping its counter, clearing its missed-fire
run. Any of that can fail over a session that already exists.

The poller therefore asks **"does a session exist for this item"**, not "did the fire return
cleanly". A fire that raised after the row was committed is a fire: the item is recorded, the error
is logged loudly, and nothing spawns for it again. A fire that raised before the row existed is a
dropped event: the item stays unseen and the next tick retries it.

Reading a post-commit failure as "nothing happened" is what put **two** merge-gate sessions on one
`ready to merge` label on 2026-08-29 — 55 seconds apart, and 43 seconds apart on a second PR where
both of them ran. Two gate sessions rating one PR concurrently is a double-merge race on the one
mechanism authorized to merge without human sign-off.

A session created that way may still have lost its start job, and that is a separate condition with
a separate owner: `StalledStartSweepJob` restarts a `waiting` session that has no job
([Background jobs](/operate/background-jobs/)). Re-firing would not have rescued it
either — it would have spawned a sibling and left the original stranded regardless.

The other half of the same guarantee, and it applies to the **`github_label` seen-set only**, is
*when* the record is written. A fired key is persisted the instant its session exists, rather than
only in the single state write at the end of the tick. Everything between those two points can fail
— another item's fire, the re-read the state write does, the write itself, or the worker being torn
down mid-tick — and every one of those failures used to lose keys whose sessions had already been
created, handing the next tick an event that was already in hand. The end-of-tick write is still the
authority on the whole seen-set: it is what maintains the grace counts and what drops keys whose
grace has run out. The per-fire write only ever *adds* a key that just fired, so it cannot resurrect
a key the grace window was about to drop.

A `github_issue` condition has no such floor. Its cursor and its fired-key set are still written once,
at the end of the tick, so a lost write there leaves both untouched and the next tick re-fires every
issue in that batch — the same duplicate, on the other condition type. The half of this that *is*
shared is the one that produced the observed defect: "does a session exist for this item" is asked by
the same `#fire` for both, so a raise after the row was committed consumes the event on either path.
Tracked in [#748](https://github.com/tadasant/zimmer/issues/748).

### Rate-limit budget

Every condition costs **one** search request per tick, whatever its repo count: GitHub's search API
expresses all the watched repos and labels as a single query.

```
is:open is:pr (repo:tadasant/zimmer OR repo:tadasant/zimmer-catalog) (label:"ready to merge")
```

The search API is rate-limited **separately** from the core API — 30 requests/minute authenticated,
against core's 5,000/hour. At one tick per minute, *N* GitHub conditions cost *N* of those 30. The
existing `GithubCommentPollerJob` spends from the core bucket, so the two never contend.

Polling every minute holds comfortably: ~10 conditions is a third of the search budget, and adding
repos to a condition is free.

:::caution[The query syntax is pinned on purpose]
GitHub is migrating its issue-search API to an "advanced" query syntax, and the two syntaxes are
mutually incompatible for the multi-repo query this poller is built on — legacy wants
`repo:a repo:b` (implicit OR) and 422s on the explicit form; advanced wants `(repo:a OR repo:b)`
and *silently returns zero rows* for the implicit one.

The silent zero is the dangerous half. Under the seen-set semantics an empty result means "nothing
carries the label", so a query that quietly started being evaluated as advanced would drain the
seen-set and then re-fire every labelled item the moment the syntax was corrected.
`GithubSearchService` therefore pins `advanced_search=true` on every request, so the syntax Zimmer
builds is the syntax GitHub evaluates — whichever default the API ends up settling on.
:::

:::note[No gh credential → the poller skips, it does not storm]
The poller shells out to the `gh` CLI, which authenticates from a `gh auth login` credential or a
`GH_TOKEN`/`GITHUB_TOKEN` in the environment. On an instance whose worker has neither, every tick
would otherwise fail one API call per condition and alert on each — an every-minute error storm over
a missing credential.

So each tick preflights `GithubSearchService.auth_preflight` (a quiet `gh auth status`) and returns early
unless it authenticated, logging a single WARN — the same shape as `SlackTriggerPollerJob`'s
`return unless SlackService.configured?`. This is deliberately distinct from a transient API failure on
a *configured* host (a rate-limit or network blip), which still raises and alerts, because that is a
real incident rather than an unconfigured environment.

**The skip is the same three ways it can fail; the WARN is not.** `gh auth status` is a live API call,
so it fails during a GitHub outage too — and its human-readable output then asserts "The token … is
invalid" about a credential it never managed to check. Taking that at face value is how a GitHub
degradation once got reported as a missing credential, in text byte-identical to a revoked token's.
So the preflight reads `gh auth status --json hosts` instead, which carries the transport error `gh`
swallows on its way to that prose, and reports one of four states:

| State | What `gh` reported | The poller's WARN says |
| --- | --- | --- |
| `:authenticated` | a host entry with `state: "success"` | — (it polls) |
| `:unconfigured` | an empty `hosts` map, or no `gh` binary | `gh CLI is not authenticated (no gh auth login / GH_TOKEN)` |
| `:rejected` | `401` / `Bad credentials` | GitHub rejected the credential; it likely needs rotating |
| `:unknown` | a 5xx, a DNS failure, a timeout, anything else | it could not reach GitHub, so the credential's validity is **unknown** |

Only `:unconfigured` keeps the original wording, because it is the only state that ever deserved it.
None of them alerts: a preflight failure is by construction the *total* case, and the total case is
already reported by the stale heartbeat that `GithubTriggerHealthCheckJob` pages on within 15
minutes. What changed is that the WARNs an operator reads while that counts down now name the right
fault — a credential to provision, a credential to rotate, or githubstatus.com.
:::

:::note[A timed-out search index is refused, retried, and then skipped — not paged]
GitHub answers `incomplete_results: true` when its search index times out and returns only what it
managed to index in time. Zimmer never accepts that as the complete picture: under the seen-set
semantics a short read looks like "these items lost their label", which would drop them from the set
and re-fire every one of them on the next tick. So the read is refused — the tick keeps the seen-set
it already had, and nothing advances.

Nobody is paged for it, though. The index blip usually clears within a second, so
`GithubSearchService` re-runs the whole search (`INCOMPLETE_RESULT_RETRY_DELAYS`, 0.5s then 1.5s)
before giving up, and most occurrences never surface at all. If it is still incomplete, the narrower
`IncompleteResultsError` tells `GithubTriggerPollerJob` to skip that condition for the tick with a
WARN rather than page: the next tick re-derives the entire seen-set from scratch, so a skipped tick
is self-correcting and costs nothing. It happens on the order of once a month, and a page for it is
a page for something that has already fixed itself.

The retry re-runs the search from page 1 rather than re-fetching the page that came back short. For
a multi-page read the earlier pages came from an index that was already struggling, and splicing
them onto a page fetched seconds later — after the index changed state — can drop an item whose page
boundary moved underneath the pagination. Whole read or nothing, on every attempt.

A degradation that does *not* clear still surfaces, by two routes. One condition stuck on it —
an expensive query the index keeps timing out on — pages once its consecutive-skip streak reaches
`CONSECUTIVE_INCOMPLETE_SEARCHES_TO_ALERT` (5 ticks ≈ 5 minutes, tracked per condition in Redis and
cleared by any clean poll). Every condition stuck on it stamps no heartbeat at all, so
`GithubTriggerHealthCheckJob` pages on the stale value — see
[background jobs](/operate/background-jobs/#trigger-poll-liveness).
:::

:::note[A request that fails is retried before it pages — and pages just as loudly if it keeps failing]
The same nuance, for the request that does not come back at all. GitHub's API has bad minutes: over
one week in August 2026 the label poller's searches failed with `Bad credentials (HTTP 401)` (both
enabled conditions at once, 0.35s apart), with `HTTP 504`, and with a body that stopped mid-stream
(`unexpected end of JSON input`) — every one of them cleared on the very next tick, and every one of
them paged `#alerts` first. A page that arrives at a system which has already healed carries no
action.

So `GithubSearchService` re-runs the whole search on a failure that reads as GitHub's rather than
Zimmer's (`TRANSIENT_REQUEST_RETRY_DELAYS`, 1s then 3s), logging each intermediate attempt at INFO.
Only when the third attempt fails does a `SearchError` leave the service, and the poller then logs
ERROR and pages exactly as it always has. **Nothing is suppressed** — a revoked credential, an
unreachable API, a query GitHub will never answer all still page, about four seconds later than
before, on that tick and every tick after. A search that fails outright *and* ends on an incomplete
index raises the pageable `SearchError` too, not the quiet `IncompleteResultsError`: the quiet skip
is a promise that a slow index was all that happened.

What is *not* retried is as deliberate:

- **A failure GitHub attributes to the request.** A 4xx other than 401 and 408 — a malformed query
  (422), a repo the token cannot see (404), a permission denial (403) — fails fast, because waiting
  cannot change the answer. So does `gh` rejecting the command line itself.
- **A rate limit**, though it is transient in every other sense. The search endpoint allows 30
  requests a minute and a secondary limit's `Retry-After` is usually 60s or more, so no retry inside
  this budget can succeed — and since a retry re-runs the whole search, it would spend more of the
  very quota that produced the failure. The next tick is the retry.
- **A hang.** A request killed at `REQUEST_TIMEOUT` has already spent 15s of a 60-second tick, and a
  repeat would spend another 15s before reaching its backoff. The next tick is a better time to ask.

The classification is a deny-list — retry unless the failure is recognisably Zimmer's — because two
of the four modes production produced carry no HTTP status at all, so an allow-list of known
signatures would keep paging for the next mode nobody has seen yet. Where `gh` prints more than one
status, *every* one has to be retryable: repo and label names reach the query from the trigger's
configuration and `gh` echoes the query back in its error, so a label named `x (HTTP 503)` must not
be able to talk a permanent 422 into a retry.

Two things bound what a retry can cost. The delay lists cap the *sleeping* at 4s here plus 2s for an
incomplete index, spent per search attempt however many pages the search spans. They say nothing
about the requests a restart re-issues, so `TRANSIENT_RETRY_DEADLINE` (20s) caps that separately: no
new attempt starts once a search has been running that long. Against a healthy API — these searches
return in well under a second — neither bound is ever reached.
:::

## Stale catalog references

A trigger is a template, and it outlives the catalog it names. Between one fire and the next a skill
can be renamed, a plugin retired, an MCP server dropped — and the trigger goes on carrying the old
name. So each of the four catalog-artifact columns is checked twice, and the two checks answer
different questions:

| Artifact | Column | Validated at save? | Healed at fire? |
| --- | --- | --- | --- |
| MCP servers | `mcp_servers` | ✅ | ✅ |
| Skills | `catalog_skills` | ✅ | ✅ |
| Hooks | `catalog_hooks` | ✅ | ✅ |
| Plugins | `catalog_plugins` | ✅ | ✅ |
| Agent root | `agent_root_name` | presence only | ✅ — [and differently](#the-agent-root-is-resolved-only-where-it-is-used) |

**Validated at save** rejects a name the catalog does not know *now*, on the form, the REST payload
and the `action_trigger` MCP tool alike. The check is scoped to the column that changed, so a row
persisted before a name went stale still saves when the edit is to some other column — otherwise the
catalog moving would lock an operator out of editing anything else about the trigger.

**Healed at fire** is what cleans those up. `Trigger#heal_catalog_references!` runs at the top of
`#create_session!`, on the reuse path as well as the spawn path — `#follow_up_session!` syncs all
four columns onto the reused session, so a stale name is load-bearing either way. It drops the names
the catalog no longer knows, `update_column`s the survivors so the next fire does not re-discover
them, and raises one deduped alert per artifact kind naming what it removed and what remains.

Healing **skips entirely when a catalog resolves empty**. A catalog that fails to load leaves the
config facade an empty list ([#112](https://github.com/tadasant/zimmer/issues/112)), and against an
empty catalog every reference looks stale — healing on that reading would strip all four columns on
every trigger in the deployment. An empty catalog is never evidence that a reference is gone.

That guard is narrower than it reads, and this is the limit of what it buys. A *degraded* resolve
usually leaves the facade non-empty: `AirCatalogService` serves a last-known-good tree, which can
predate a rename, so a name that is perfectly valid today can still look stale to a fire. The
session-side scrub in `AirPrepareService#scrubbed_catalog_skills` refuses to persist a drop while
`AirCatalogService.degraded?` for exactly that reason; the trigger heal has never made that second
check, and a heal that drops a renamed reference does not repoint it —
[#853](https://github.com/tadasant/zimmer/issues/853) covers both.

The four columns are declared once each, on both `Trigger` and `Session`, by the
`CatalogArtifactReferences` concern; the validators and the heal are generated from those
declarations rather than written out per column. `agent_root_name` is deliberately not one of them —
it is a single name rather than a list, and its heal looks up a successor root and can raise.

## Reusing a session

`reuse_session` makes a trigger follow up into the session it last created instead of spawning a new
one. The candidate is `last_session_id`, and it is used when the session is alive — `needs_input`,
`running`, or `waiting` — and nobody has taken it over by hand.

`resuscitate_archived` extends that to a session already in trash: `UnarchiveSessionService`
restores its clone and its transcript, and the follow-up lands in the resumed conversation.

### The archived session that never started

Resuscitation only works when there is a conversation to follow up **into**. A session whose agent
process never launched has none: no runtime `session_id`, no transcript. `Session#never_ran?` is that
pair, and both halves have to be blank.

That pair is what the [spot gate](/sessions/spot-and-priority/#the-gate) produces at scale: a `spot`
session can sit at the starting line for a whole quota window without ever starting, and then be
archived. `session_id` is stamped once the spawn pipeline has the session's clone and *before* the
runtime is launched (Zimmer passes it to the CLI as `--session-id`), so a blank one means the session
never got that far — and its transcript is blank for the same reason.

Restoring one of those is fine on its own — that is what
[restoring a session that never ran](/sessions/lifecycle/#restoring-a-session-that-never-ran) does,
and `UnarchiveSessionService` no longer refuses it. **Reusing one is not.** A follow-up prompt to a
session with no `session_id` is reclassified by `AgentSessionJob` as a fresh start, and a fresh start
runs the session's **own** prompt — so this fire's prompt would be silently dropped in favour of the
one the session was created with. Spawning gives the trigger a session that runs the prompt it
actually sent.

It also has to stay a screen because it once bricked triggers outright. The unarchive refused such a
session, the fire raised, `ScheduleTriggerJob` advanced `last_triggered_at` to close the retry loop,
and the schedule was consumed with nothing created — on that fire and on every one after it, since
the candidate never changes. A daily sweep died silently and permanently on one held session.

So a never-started session is not a reuse candidate at all. The trigger logs a warning and falls
through to the paths it would take with no candidate — the same paths an archived session takes when
`resuscitate_archived` is off:

- a **recurring** trigger spawns a fresh session, which repoints `last_session_id` at it and so heals
  the trigger on that same fire;
- a **one-time reuse** trigger ("wake *this* session at 9am") skips silently, because it means that
  one session and a fresh stranger would be no use to it. As with any other undeliverable one-time
  reuse fire, the schedule is still consumed and the trigger is held along with its sibling
  wakes — it is not parked as `failed`, because nothing raised.

Every other unarchive failure still raises and alerts. A clone that will not restore, a database
error, a row that cannot leave its state — and the one case where the id and the transcript come
apart: a runtime that mints its own conversation id (codex) has that id cleared on a fresh-start
recovery, so a long-running session can be archived holding a full transcript and no id. That
session is **not** never-run — it *has* state — so the unarchive still tries to resume it, still
cannot, and says so loudly. Abandoning it quietly and spawning a duplicate alongside it would be the
wrong answer, and so would restarting it fresh over the top of hours of work.

`UnarchiveSessionService` writes a restored transcript under the session's `session_id` for a runtime
with a single-file resume path; a Codex unarchive writes nothing and is not failed for it — see
[Writing a transcript back to disk](/sessions/transcripts/#writing-a-transcript-back-to-disk).

### The agent root is resolved only where it is used

`agent_root_name` is a **spawn-path** field on the fire path. `Trigger#create_new_session!` (and the
burst notice) hands it to `Session.create_from_agent_root!`; a reuse hands it to nobody, because the
session it follows up into was already created with a root of its own.

`Trigger#heal_stale_agent_root!` therefore runs twice, and the two calls differ in one thing —
whether an unresolvable name is allowed to raise.

- **Before the reuse paths, non-raising.** A *renamed* root is still repointed onto its successor on
  every fire — matched on an exact `git_root` + `subdirectory` match. That repair belongs on every
  fire because `agent_root_name` is read off the fire path too: `search_triggers` and
  `action_trigger` gate a scope-restricted MCP connection on it, and the trigger page and the REST
  payload display it. A reuse trigger that never spawns would otherwise keep a vanished name forever
  and drop out of a scoped agent's view of its own triggers.
- **After them, on the spawn path, raising.** A name with no successor is a real failure only for a
  fire that was about to create a session under it. `ScheduleTriggerJob` parks a one-time wake
  `failed` on that raise; a recurring schedule instead advances `last_triggered_at` and retries on
  its next interval, and `AoEventTriggerJob` parks only a session-scoped condition.

Raising up front made the check wrong for a whole class of trigger. Every per-session wake —
`Sessions::ScheduleWakeUp` behind the `wake_me_up_later` MCP tool, and the session-scoped `ao_event`
wake behind `wake_me_up_when_session_changes_state` — labels itself with the root of the session it
is going to reuse, and falls back to the session's runtime name when the session resolves to no
catalog root at all (a legacy session, or one whose root has since left the catalog).
`"claude_code"` is not a root, so the wake raised on its own label, the trigger was parked `failed`,
every firing path filters on `enabled` — and the session slept forever, silently. See
[#600](https://github.com/tadasant/zimmer/issues/600).

### Re-arming the wakes that were already bricked

Deferring the raise fixed the *arming*, not the wreckage: a trigger already parked `failed` is a
tombstone only you clear, and `CleanupStaleTriggersJob` exempts it from every sweep, so those wake
rows stayed dead and the prompts they carried were never delivered. The retroactive repair is the
post-deploy task `db/post_deploy/20260904120000_rearm_wakes_bricked_by_unresolvable_agent_root.rb` —
an ops action that ships with the deploy rather than needing somebody to find the rows and press
**Re-arm** ([#836](https://github.com/tadasant/zimmer/issues/836)).

This is the trigger-side counterpart to
[`StrandedSleepRescue`](/sessions/lifecycle/#who-else-moves-sessions-around), which since
[#855](https://github.com/tadasant/zimmer/issues/855) already nudges the *session* that lost its wake.
That sweep gets a stranded session moving again; it does nothing about the parked row or the specific
prompt the wake was carrying. This task delivers that prompt — and only to a session that is still
waiting for it.

It re-enables a trigger only when all of these hold: it is `failed`, its `last_error` names
`AgentRootsConfig::AgentRootNotFoundError`, it is a one-time reuse wake (`one_time_reuse_trigger?`),
its one-shot is not already spent (`spent_one_shot_wake?`), and its target session is still `waiting`,
not paused by a user, and **not already resting on a wake that can still fire**
(`Session#awaiting_scheduled_wake?` — the same predicate `StrandedSleepRescue` reads). That last term
matters because a bricked session may since have been rescued and armed a *fresh* wake: firing the
stale one would resume it early, and the delivery would then take `#hold_wake_group!` through
the live wake on its way out — putting a wake the session is genuinely waiting on onto a turn that
retires it. Anything else is left parked.

**A past-dated wake is re-armed as it is, not retimed.** Nearly every row here is past-dated by
construction, and for a one-time schedule `TriggerCondition#schedule_due?` answers `now >= scheduled_at`
— so an overdue wake is *immediately* due and fires on the next tick, which is the point. The
past-dated guard in `Sessions::ScheduleWakeUp` is about a different moment: at creation the target may
still be `running` with only `pending_sleep` set, so a condition due on the very next tick can fire
before the sleep lands and get dropped. Here the target is already `waiting`, so the fire takes the
reuse path and resumes it. Retiming would only make a late wake later, and would overwrite the record
of when it was asked for.

Because `enable!` sheds `failed_at` and `last_error`, the task logs each row — trigger id and name,
target session, condition shape and scheduled time, the prior error verbatim — *before* it writes, and
puts a bounded digest in `post_deploy_task_runs.stats` so the ledger on `/health` answers what it did.

## Coalescing a repeated fire

A recurring trigger that reuses a session is a drumbeat: one fire, one run. If the session it reuses
is still holding the **previous** prompt undelivered, the next fire is coalesced into it rather than
stacking a second copy — `Trigger#coalesce_recurring_fire?`. The queued prompt already carries
exactly this intent and runs when the session next takes a turn.

**Only a purely recurring trigger is coalesced** — one where no condition is a one-time schedule or a
session-scoped ao_event. A wake is a one-shot signal that has to survive the race between "the watched
session transitioned" and "the requester's turn ended", so it keeps the narrower guard on the
`running?` branch, which treats an existing pending message as already representing the event.

The test is `Trigger#purely_recurring?` rather than the negation of `#one_time_reuse_trigger?`, and
the difference matters for a trigger that *mixes* the two. `#one_time_reuse_trigger?` demands that
**every** condition be one-shot, so a trigger carrying a recurring schedule alongside a one-time one
fails it — while `ScheduleTriggerJob` keys its post-fire bookkeeping on
`condition.one_time_schedule?` and checks only `#last_follow_up_dropped?` before handing the trigger
to the requester. A coalesced fire is not `:dropped`, so coalescing that shape would consume the
one-shot schedule and hand over a trigger that delivered nothing. Refusing to coalesce any trigger that carries a one-shot condition at all keeps the
previous behaviour intact for those shapes.

### Why a queue can grow when nothing looks wrong

The obvious reading — "an idle session gets the prompt delivered, so nothing queues" — is wrong for a
`spot` session held at the [quota gate](/sessions/spot-and-priority/#the-gate). Such a session sits in
`waiting`, which reads as idle, so the follow-up takes the delivery branch: it resumes the session
into a job, and `SpotSessionHold` then defers that job and files the prompt in `enqueued_messages`
behind the turn already scheduled. The delivery becomes a queued row on the way through.

Repeat that nightly and the queue grows by one a night while every other signal says the trigger is
healthy — `last_triggered_at` advances on a coalesced fire exactly as on a delivered one. On
2026-08-29 the nightly backlog groomer had not run for six days for precisely this reason, and the
first anyone heard of it was an unrelated self-archive
[stranding the backlog](/sessions/lifecycle/) on the way out.

### A coalesced fire is a miss, and says so

Coalescing stops the pile-up but does not make the work happen, so the trigger counts consecutive
coalesced fires in `missed_fire_count` (stamped from `first_missed_fire_at`). The count resets the
moment a fire genuinely lands.

It is shown wherever a trigger is: a badge in the trigger list and on the trigger page, a
`missed_fire_count` field on the REST API, and a warning line in `search_triggers`. **Zimmer alerts**
once two conditions hold together — at least `MISSED_FIRE_ALERT_THRESHOLD` (2) consecutive fires
coalesced, *and* the undelivered prompt has been sitting for at least `MISSED_FIRE_MIN_QUEUE_AGE`
(1 hour). Either alone is noisy: one skip is an ordinary mid-turn session, and a fast-firing trigger
can rack up skips inside a single long turn without anything being wrong. Together they mean two
scheduled runs did not happen and the session genuinely is not consuming.

A session held for quota headroom is **budget pacing, not a failure** — the alert says so, and such a
session re-checks on its own, so the schedule resumes once it gets through.

The alert also asks the operator to confirm that something *will* make the session take a turn,
because for a `waiting` session that is not spot-held, nothing necessarily will —
see [the limitation](/limitations/#a-waiting-sessions-queue-has-no-sweep-so-coalescing-can-wait-on-a-turn-that-never-comes).

## Firing a trigger by hand

A trigger does not have to wait for a condition. All three surfaces can fire one now:

- **Web UI** — the **Run Now** button on the trigger page, which opens a panel with an input per
  `{{variable}}` the template names.
- **REST** — `POST /api/v1/triggers/:id/invoke`, with an optional `variables` object.
- **MCP** — `action_trigger` with `action: "invoke"`, taking the same `variables` object.

All three go through `Triggers::ManualFire` into `Trigger#create_session!`, the same chokepoint a
poller-driven fire uses. So a manual fire is a real fire: the session is linked to the trigger,
counts toward its fire counter, heals stale catalog references (the [agent root only where it is
actually used](#the-agent-root-is-resolved-only-where-it-is-used)), reuses the target session if the
trigger is a reuse trigger, and is subject to the [burst cap](#burst-control) — over it, you get a
burst-notice session or nothing at all, and each surface says which.

A **disabled** trigger can still be invoked by hand, from any of the three. `status` governs whether
the trigger's own conditions fire it, not whether a person or an agent may; invoking one is how you
test a trigger before enabling it, and it does not re-arm it.

The one thing that differs is the session's [genesis](/sessions/spot-and-priority/#genesis): the
button stamps `web_ui`, because a human clicked it, and the REST and MCP paths stamp `api`, because
an agent called them. Neither takes the genesis the trigger's conditions would derive — no condition
matched.

## Scheduling class

A trigger can say whether its sessions are **spot** or **priority**
(`Trigger#scheduling_class`, on the triggers form, the REST API, and the `action_trigger` MCP tool).
Leave it unset — the default — and the class comes from the trigger's condition type: `slack` is
priority, because a human is waiting on the answer; `github_issue`, `github_label`, `schedule` and
`ao_event` are spot.

The selector is on the **trigger**, not on the condition, because a trigger carries several
conditions with OR semantics and one shared session template — a mixed trigger already collapses to
one genesis via a precedence order, so a per-condition class would have to collapse the same way.

It is read once, when the trigger fires, and stamped on the session it creates. **Changing it also
carries onto this trigger's own sessions that are still `waiting`** — the backlog a spot-to-priority
flip is usually trying to release. It reaches only this trigger's sessions, only ones still in
`waiting`, and only ones still carrying the class the trigger stamped, so a session an operator moved
by hand stays where they put it. Every surface that changes the class reports how many sessions
moved. To move a session it does not reach — one that has already started, say — move that session:
the button on its hold banner, the selector on its detail page, or `action_session`'s
`change_scheduling_class`. See
[Spot and priority](/sessions/spot-and-priority/#stored-only-when-someone-chose-it) for the full rule.

A trigger can also predefine the **precedence** its sessions get (`Trigger#precedence`, same three
surfaces). Higher is worked first, on an absolute scale — 100000 comes before 50 — and it orders the
spot queue. Leave it blank to predefine nothing. Unlike the class it is *not* withheld from a
hand-fired Invoke: a precedence describes how this trigger's work ranks against everything else
queued, which is as true of a hand-fired run as of a scheduled one.

Full detail in [Spot and priority](/sessions/spot-and-priority/).

## Skip while a session is still pending

A trigger can refuse to spawn a second session while one it already spawned has yet to do the work:
**skip while a session is still pending** (`Trigger#skip_if_pending_session`, on the triggers form,
the trigger detail page, the REST API, and the `action_trigger` / `search_triggers` MCP tools). It is
**opt-in** and defaults to off, so no existing trigger changes behavior.

It bounds the **backlog**, where [burst control](#burst-control) bounds the **rate**, and neither
substitutes for the other. A trigger that fires every fifteen minutes never trips a rate cap and can
still pile up a dozen sessions all carrying the same prompt.

That is exactly what the seeded `quota_available` wake trigger did. It fires on every pool recovery
and spawns a fleet-maintenance session to decide who runs — but that session is itself parked by the
quota exhaustion it exists to answer, so recovery after recovery it sat in `waiting` while the
trigger spawned fresh siblings with an identical prompt. The migration that adds the column turns the
setting on for that trigger.

**Pending means `waiting` or `running`**, and deliberately nothing else:

- `waiting` is "queued, has not had its turn" — including a session parked on an exhausted pool.
  This is the case the setting exists for.
- `running` counts too: a session mid-work has not delivered its outcome, and a sibling doing the
  same job concurrently is the same duplication one tick earlier.
- `needs_input`, `archived` and `failed` do **not** count. Each has had its turn — finished, died, or
  waiting on a human — and none may block a legitimate future fire. Counting `needs_input` would let
  one session parked for a human silently disable the trigger for as long as nobody looked at it.

A burst-notice session never counts as pending: it carries "investigate this burst", not the
trigger's own intent.

The gate sits at `Trigger#create_session!`, in front of burst control, so it covers every condition
type at once, and the check and the spawn share one row lock — two jobs firing the same trigger at
once cannot both read "nothing pending" and both spawn.

:::caution[This setting does nothing on a fire into a reused session]
It guards the **spawn** path only. A trigger holding a live, reusable `last_session_id` returns out of
`Trigger#create_session!` through `#follow_up_session!` long before the gate is consulted, so on those
fires the checkbox is stored and never read.

It is **not** dead on such a trigger, though: the same trigger reaches the spawn path on a fire where
it has no reusable target — it has never fired, or the target was archived or failed and a recurring
trigger spawns a replacement — and the setting applies in full there. The trigger page, the REST API
and `search_triggers` all say exactly that where the setting is rendered, rather than implying it is
either in force or dead.

A reused session does still accumulate duplicates — not as sibling sessions, but as queued prompts.
[Coalescing a repeated fire](#coalescing-a-repeated-fire) is the control that bounds *that* backlog,
and it needs no opt-in.
:::

A skipped fire consumes no burst budget, does not advance `last_triggered_at`, and does not increment
the trigger's session counter — nothing happened. What it *does* mean varies by caller, because a
skip is "the work is already in hand", not "the event was dropped":

- `SystemEventTriggerJob` counts it as **handled** and does **not** re-arm the quota edge. Re-arming
  would put the edge back, so the next sweep would read the level as `false` against an available
  pool, call it a fresh recovery, fire, skip, and re-arm again — one wasted fire every sweep for as
  long as the pending session stays pending. This is the opposite of the burst-suppressed path, which
  *is* an undelivered event and *does* re-arm.
- `GithubTriggerPollerJob` leaves the item unseen, so a label or an open issue fires for real on a
  later tick once the pending session is done. A GitHub item is durable state; a broadcast event is
  not.
- `ScheduleTriggerJob` and `AoEventTriggerJob` consume the condition: the next occurrence is a fresh
  chance, and re-running this one would only ask the same question again.
- `SlackTriggerPollerJob` drops the message, exactly as burst suppression does and for the same
  reason — the poller's cursor has already moved past it.
- A hand-fired **Invoke** reports the skip and links the pending session: the web UI redirects to it,
  the REST API answers `409 Conflict` naming it, and `action_trigger` returns "Trigger Not Fired".

The trigger detail page and `search_triggers` both say when a trigger is *currently* skipping and
which session it is deferring to — without that, a trigger spawning nothing looks dead.

## Burst control

A trigger can cap how many sessions it spawns per minute: **max sessions per minute**
(`Trigger#max_sessions_per_minute`, on the triggers form, the REST API, and the `action_trigger` MCP
tool). It is **opt-in** — unset means unbounded, which is how every trigger behaved before the
setting existed.

It exists because nothing bounded a trigger before. A burst of messages in a watched Slack channel
spawned one session per message — 50 of them, trashed by hand — and a sustained outage generating
alerts could have spawned sessions until the fleet was overwhelmed. A single Slack poll tick can
carry many messages, so the cap has to bound spawns *within* a tick, not just across ticks.

The cap is enforced at `Trigger#create_session!` — the one chokepoint every condition type funnels
through — so it covers `slack`, `schedule`, and `ao_event` triggers at once.

```mermaid
flowchart TD
    F["trigger fires"] --> C["count this fire<br/>against the current minute"]
    C --> O{"minute over cap?"}
    O -->|yes| X["hold the burst open:<br/>burst_active_until = now + 5 min"]
    O -->|no| B
    X --> B{"burst already open<br/>before this fire?"}
    B -->|yes| S["spawn nothing —<br/>the event is dropped"]
    B -->|"no, and over cap"| BN["spawn ONE burst-notice session,<br/>linking the sessions spawned this minute"]
    B -->|"no, and under cap"| N["spawn the session as usual"]
```

What each state means:

- **Under the cap:** the trigger spawns exactly as it does today.
- **Over the cap:** the trigger spawns **one** burst-notice session instead of the session the event
  asked for. Its prompt links the sessions the trigger already spawned in that window (so you can
  jump straight to them), quotes the event that tipped the cap, and asks the agent to investigate the
  burst rather than work the events. That session carries no goal — the trigger's goal describes the
  work the *event* asked for, not investigating a burst — and it never becomes the `reuse_session`
  target.
- **During the burst:** the trigger spawns **nothing at all**, and sends **no further notices**. An
  outage that alerts for an hour keeps the trigger quiet for that hour and still produces exactly one
  notice.

A burst ends **five minutes** (`Trigger::BURST_COOLDOWN`) after the last minute in which the trigger
**exceeded its cap**. That "exceeded its cap" is load-bearing: the cooldown is pushed forward only by
a window that is itself over the cap, never by the individual dropped events. Extending it on every
dropped event — the obvious implementation — means a channel with any baseline chatter can never
leave a burst, because each ordinary message renews the suppression: one 50-message spike would
silently disable the trigger forever.

The cooldown is also deliberately several times the one-minute poll cadence. At one minute it would
expire exactly as the next tick's events arrive, refilling the cap and producing a fresh notice every
minute — the stream this control exists to prevent.

**Escape hatch:** re-saving a trigger's cap clears any burst in progress, so a trigger that is still
suppressing (because events really are still pouring in) can be brought back immediately rather than
waited out. Clearing the cap entirely does the same and returns the trigger to unbounded.

:::caution[Suppressed events are dropped, not queued]
The Slack poller advances its cursor past every message it fetched, whatever each message produced.
Messages suppressed during a burst are therefore **dropped** — not replayed when the burst ends.
That's deliberate: replaying them would spawn the very sessions the cap just prevented. The
burst-notice session is your record that they happened.
:::

Follow-ups into a **reused** session are not capped: they spawn nothing, and a `reuse_session`
trigger tops out at one session by construction. The cap counts *new session spawns*.

The state lives on the trigger row (`burst_window_started_at`, `burst_window_count` — fires
*attempted* in the window, not sessions spawned — `burst_window_session_ids`, and
`burst_active_until`). The check-and-reserve happens under a row lock, so two jobs firing the same
trigger concurrently can neither both take the last slot nor both open the burst. The window is
anchored at the first fire and tumbles, rather than sliding.

A fire that is burst-suppressed delivered nothing, so it does not count as a fire for the trigger's
own bookkeeping either: `ScheduleTriggerJob` leaves the schedule due (it fires for real once the
burst ends), and `AoEventTriggerJob` leaves a session-scoped condition's one-shot guard unspent.
Neither hands a one-time trigger's wake group to a requester on a suppressed fire.

## Wake-up semantics

Triggers are the backing store for two MCP tools Zimmer gives its own agents: "wake me up later"
and "wake me up when that other session changes state." Four mechanisms make this reliable:

**Auto-sleep.** `Trigger#sleep_target_session_if_applicable` runs on trigger creation. If the
target session is `needs_input`, it sleeps immediately (`needs_input → waiting`). If it's
`running`, it sets `metadata["pending_sleep"] = true` and the sleep happens on the next `pause`.
So an agent can say "wake me in an hour" mid-turn without stranding itself.

It also clears a stale `paused_by: "user"` from a session it is arming a wake on. That marker means
"a human has taken this session over", and `reusable_session?` refuses to deliver into a session
carrying it — so a session that was paused by hand and then given a wake-up would have had that
very wake-up dropped on arrival. Arming a wake is the moment the marker stops being true.

Two details decide where it applies. It runs on all three reachable statuses, not just the one that
sleeps immediately — a `running` session reaches `waiting` later and an already-`waiting` one is
dormant now, and both would otherwise hold an undeliverable wake. And it runs *after* the status
work rather than before: `sleep!` can raise, and a session left in `needs_input` with the marker
already gone is one the bulk refresh auto-continues, resuming work a human deliberately stopped.
Only `"user"` is cleared, and only on a status `reusable_session?` would accept; `recovery` and
`spot_quota` name sweeps still responsible for the session, and on a `failed` or `archived` session
the wake is undeliverable for reasons the marker has nothing to do with.

**Immediate fire on already-matched state.** `Trigger#fire_ao_event_immediately_if_state_matches`
row-locks each watched session *inside the creation transaction* and enqueues the job immediately
if the watched session is already in the target state. This closes the footgun where you
register a watcher after the transition already happened and then sleep forever. One state does not
count as a match: a session in a recovery pause is on its way back to `running`, and firing there
would deliver the wake [the pause itself
declined](/sessions/lifecycle/#which-pauses-announce-themselves). The watcher is left armed for the
announcement that follows the sweep.

**Sibling cleanup is deferred to the end of the woken turn.** After a successful one-time fire,
`Trigger#hold_wake_group!` marks the firing trigger and every other one-time wake pointing at the
same requester with `wake_held_at`. They stay `enabled`, stay unfired and can still fire; what the
mark records is that the requester's *current turn* owes them a retirement. The requester's state
machine performs it — `SessionStateMachine#retire_held_wake_triggers`, on `pause` and on `archive` —
and deliberately not when that pause is one Zimmer entered on the turn's behalf: a [recovery
pause](/sessions/lifecycle/#which-pauses-announce-themselves), an undelivered-turn park, or an
auth-outage park (`Session#turn_stood_down_before_it_ran?`). Unless the follow-up was *dropped*,
in which case the group is not touched at all.

The deferral is [#569](https://github.com/tadasant/zimmer/issues/569). These wakes used to be
destroyed at fire time, which is *before* the woken turn has run — and re-arming is that turn's job,
at the end of it. So between the fire and a successful re-arm the session held nothing, and a turn
interrupted anywhere in that window left it asleep with no wake, indistinguishable from a session
sleeping correctly. One production instance lost a 04:52 deadline backstop to a 04:18 fire and sat
inert for 4.5 hours until the orphan sweep found it.

Retiring is as load-bearing as holding. A wake that outlived its wait and fires into a later,
unrelated one is silent in exactly the same way, so the group is gone by the end of any turn that
actually ran and came to rest — which is where the old destroy amounted to, one turn later. Wakes
the woken turn arms *for itself* carry no `wake_held_at` and are untouched by the retirement, which
is what lets it run at every pause. Only a trigger that is nothing but one-shot wakes is held at
all: holding hands the whole row to the retirement, and a trigger mixing an unfired one-shot with a
recurring condition does other work, so its one-shot is consumed the old way instead.

**A wake that lapses unfired is parked, not deleted.** `CleanupStaleTriggersJob` also collects
one-time schedules whose moment passed more than an hour ago, on the reasoning that
`ScheduleTriggerJob` should have fired and destroyed them on its next tick. What happens to one
depends on whether it ever *delivered*. A lapsed schedule that fired is residue and is destroyed. A
lapsed schedule that never fired is the opposite — it is a wake somebody may still be asleep on — and
deleting it erases the only record that a wake was owed. Those are marked `failed` and left in place:
visible on `/triggers` with the reason, re-armable, and alerting once. Production trigger 13671 was a
02:05Z deadline backstop that never fired and was gone without trace by 03:15Z, which is why nothing
afterwards could say a wake had been lost at all
([#855](https://github.com/tadasant/zimmer/issues/855)). A trigger the user *disabled* is not parked —
it did not fire because they switched it off — and neither is one that fired and only lost its
retirement; both are destroyed as before.

Parking is about the record, not about the sleeper. A lapsed unfired schedule already fails
`Session#awaiting_scheduled_wake?` — that predicate reads `schedule_due?`, which stays true for it — so
the stranded requester was always visible to [`StrandedSleepSweepJob`](/operate/background-jobs/)
whether or not the row survived. What deleting it destroyed was the evidence.

**A wake is only armed while it can still fire.** `Session#awaiting_scheduled_wake?` — the predicate
the refresh nudge, the start guards and the repair sweeps all read — asks whether a wake *can* fire,
not whether an unfired row exists. A one-time schedule stops counting once its moment passes; a
session-scoped `ao_event` watcher stops counting once the session it watches is archived or gone,
because the firing path keys on *transitions* into the watched state and an archived session makes no
more of them. This is deliberately narrow and fails safe in every direction it is unsure about: a
watched session that merely `failed` still counts (it can be restarted, and it can still be
archived), and a watched row that cannot be read counts too. Before it, an `ao_event` condition that
had missed its only chance kept reporting itself as an armed wake forever.

**A deliberate resume consumes a pending wake, and the dead row is collected on sight.** A user
follow-up, a restart, `force_immediate` — anything where somebody decided the session should be
awake — runs `cancel_pending_one_time_wake_triggers`, which stamps `last_triggered_at` on every
pending one-time wake aimed at that session so none of them fires later into live work. That stamp
is permanent: `schedule_due?` is false forever afterwards, so the trigger never fires and never runs
the cleanup that normally removes a spent one-time trigger.

A resume caused by the **wake itself firing** is the exception. It leaves the group armed and takes
the hold branch above instead, because the requester has been resumed but has not yet *done*
anything — until its turn ends, the wait it set up is still the only thing that will wake it again.

What is left is a row that can never fire again, sitting in `/triggers` and in `search_triggers` as
`enabled` with 0 sessions — indistinguishable from an armed wake. `Trigger#dead_one_time_wake?` is
the predicate for it: every condition is a one-shot, every one of them is consumed, and the trigger
created no session. `CleanupStaleTriggersJob` collects a trigger matching it on the next tick, so a
consumed `wake_me_up_later` clears within the hour. The *lapsed* ground alone would not reach it for
much longer — `scheduled_at` more than an hour in the past is a function of when the wake was
scheduled rather than of when it died, so a wake set 12 hours out and consumed five minutes later
would sit there for another thirteen hours.

**The sweep asks this of every one-time wake, not only of those carrying a schedule.** A wake built
purely from session-scoped `ao_event` conditions — what `wake_me_up_when_session_changes_state`
creates — is consumed by the same resume and satisfies `dead_one_time_wake?` just as squarely. It has
no `scheduled_at` to lapse, so for a long time nothing reached it and it survived as `enabled` with 0
sessions until its target session was archived; in the recommended two-row pattern below, that meant
the deadline backstop cleared within the hour and the watcher beside it did not
([#793](https://github.com/tadasant/zimmer/issues/793)). Both are now collected on the same tick.

Widening the ground is safe because `dead_one_time_wake?` is the narrow part: it demands that
**every** one-shot condition on the trigger be consumed. The multi-condition watcher
`wake_me_up_when_session_changes_state` builds fails that the moment one of its three events is still
unfired, and so does the trigger `AoEventTriggerJob` deliberately preserves behind a *dropped*
follow-up — unless that trigger's only condition is the one already consumed, in which case it can
never fire again and collecting it is the whole point.

The predicate is deliberately narrow, because destroying an armed wake fails silently: the symptom
is a session that simply never wakes up. A wake whose condition has *not* been consumed is never
touched, however far out its `scheduled_at` is; nor is one whose trigger also carries a live
condition (a recurring schedule, a Slack feed, an `ao_event` watcher that has not fired); nor is a
`failed` trigger, which is a tombstone you clear.

A **system-recovery** resume is the exception to all of it. It takes the preserve branch instead:
the session did not choose to wake, so its wakes stay armed and unconsumed, and nothing collects
them.

**One trigger, several events.** A Trigger ORs its conditions, so
`wake_me_up_when_session_changes_state` takes `event_names` (an array) and builds **one** trigger
carrying one `ao_event` condition per event, all scoped to the same watched session.
`one_time_reuse_trigger?` already asks `all?` of the conditions and `AoEventTriggerJob` fires per
condition before destroying the trigger, so the multi-condition shape needed nothing new from
either.

That is what makes sibling-destroy cheap. The recommended pattern is now **two** rows for a whole
wait — one `event_names` watcher plus a `wake_me_up_later` deadline backstop — where it used to be
four, and a woken turn that decides to keep waiting re-registers two things rather than four. The
singular `event_name` is still accepted and still builds a single-condition trigger.

**A sleep with no trigger at all.** `action_session`'s `pause_into_spot_queue` creates nothing: it
sleeps the session and leaves it for the spot scheduler (`Sessions::PauseIntoSpotQueue`), which is
the right shape whenever the honest answer to "when should this come back" is "whenever there is
quota headroom for it" rather than a wall-clock time. It is also what stops the trigger table filling up with guesses — the same reasoning that
replaced the per-session auth-outage retry triggers with a `quota_available` event. See
[Spot and priority](/sessions/spot-and-priority/).

**Loop prevention.** A session whose `metadata["trigger_id"]` equals the trigger will never
re-fire that trigger.

**An armed wake makes the session unstartable.** Auto-sleep puts the session in `waiting`, which is
also where every queued session sits, so nothing about the row says "leave this alone" — and the
sweeps that start `waiting` sessions used to read it as runnable. They no longer do: while a one-time
wake is still ahead of the session, `AgentSessionJob` refuses a first start and both quota sweeps skip
it, whatever its precedence or scheduling class. Without that, the ranked spot queue and
`AuthOutageParkService` would each start a paused session early — and the second would consume the
pause on the way past, since `resume!` cancels pending one-time wakes. See
[A pause outranks precedence](/sessions/spot-and-priority/#a-pause-outranks-precedence).

### Parking a session that is still running

A park normally waits for the turn to end. Passing `"halt": true` to `action_session`'s
`pause_into_spot_queue` **stops** it instead: `Sessions::HaltRunningTurn` terminates the CLI process
and pauses the session, and the `pending_sleep` the park just wrote is what carries it
`needs_input → waiting` on the way through. All of it lands before the tool call returns.

The deferral is still the fallback rather than the behaviour. The park is written *first* and the
halt attempted second, which buys two things: a rejected park costs no turn, and a halt that cannot
land (no process, a turn that ended during SIGTERM grace) leaves the session running with its
`pending_sleep` intact — degraded to the end-of-turn sleep, never awake with nothing armed. The tool
returns `halted_turn` and `pending_sleep` so the caller can say which happened.

Halting costs a turn: work already written to disk survives, the tool call in flight does not. The
tool description says so before the call, not after it.

The deferral is the default, and that asymmetry is deliberate. `pause_into_spot_queue` is most often
a session parking **itself** — and a session that halted itself would terminate the process waiting
for the tool call to return. A caller driving somebody *else's* running session passes `"halt": true`.
`SelfSessionActionSession` both omits the option from its schema and strips it from the arguments, so
passing it anyway is a refusal rather than a loophole.

Stopping a turn skips the queue drain that a turn allowed to end performs, so a message queued behind
the session waits with it. On the timed path a wake bounds that wait; **the spot queue arms nothing,
so nothing bounds it** — drain the queue first if that matters.

### One scheduler, one front door

`Sessions::ScheduleWakeUp` is the whole of it: validate the time, create the trigger, and let
`Trigger`'s `after_create` do the sleeping. `Mcp::Tools::WakeMeUpLater` is a thin wrapper over it,
adding a rendered description and a markdown receipt.

That matters because of what the validation prevents. A `wake_at` in the past, or inside the
30-second grace window, is not merely ignored: `TriggerCondition#schedule_due?` sees it as due on
the next tick, the fire consumes the one-shot, and the session it just put to sleep is never woken.
The check lives in the service rather than the tool so a second surface cannot drift from it.

Wakes are **additive**: a second `wake_me_up_later` leaves the first armed, whichever fires first
wins, and `Trigger#hold_wake_group!` hands the rest to the woken turn, which retires them when it
comes to rest. The one gesture that replaces rather
than adds is a park into the spot queue, which runs `Sessions::SupersedePendingWakes` because it
arms nothing itself — a leftover wake would pull the session straight back out of the queue.

There is **no human-facing control that sleeps a session until a chosen time**. Scheduling a wake is
an MCP capability.

A human's levers on a sleeping session are narrower than they look, and worth stating exactly. **Start now** (the Ranked view's ⋮) resumes a session parked in the **spot queue**, which arms nothing — but it *refuses* one asleep on a wall-clock wake, because `Sessions::StartNow` treats an armed wake as outranking the queue. For that session a human has two routes, both of which consume the pause because both mean *I am taking this session over*: send it a **follow-up** from its session page, or cancel the wake at **/triggers**, where it is listed as `Wake session #<id> at <time>`. The **Restart** button is not one of them — it refuses anything that is not `failed`.

## Everything is polled

Everything external is polled. There are no webhooks anywhere in Zimmer — including the GitHub
trigger types, which poll the search API rather than receiving `issues`/`pull_request` webhook
deliveries. Webhooks would need a public ingress that Zimmer's tailnet posture does not currently
offer; polling needs nothing but the outbound `gh` credential that is already there.

| Job | Cadence |
| --- | --- |
| `SlackTriggerPollerJob` | every minute |
| `ScheduleTriggerJob` | every minute |
| `GithubTriggerPollerJob` | every minute |
| `GitHubPullRequestPollerJob` | every 30 seconds |
| `GithubCommentPollerJob` | every 30 seconds |
| `GitHubMergeConflictPollerJob` | every 2 minutes |
| `SlackTriggerHealthCheckJob` | hourly at :45 |
| `CleanupStaleTriggersJob` | hourly at :15 — reaps leftovers, parks undelivered wakes |
| `StrandedSleepSweepJob` | every 5 minutes — resumes a session asleep on a wake that can never fire |

:::caution[While Slack is rate-limiting you, Slack triggers fire late]
`SlackTriggerPollerJob` is confined to a `pollers` queue with `total_limit: 1`, so while it runs it
is Slack polling for the whole instance.

It does not wait a throttle out on that slot. `SlackService` absorbs a short blip in process (three
retries, backing off 1s, 2s, 4s) and hands anything longer back; the job then reschedules itself —
30s, 60s, 120s, 240s, 480s, or Slack's own `retry_after` if that is longer — and frees the worker
thread. The cron ticks in between are still no-ops, but they are no longer landing on a run parked
in a `sleep`.

Nothing is lost — `last_message_ts` is a cursor, so the next successful poll still sees the messages
— but a trigger can fire minutes after the message that should have fired it. A throttle absorbed
this way logs at WARN, precisely because nothing was lost. After five deferrals the job logs at
ERROR, alerts, and the ordinary once-a-minute cadence takes over.
:::

:::note[Triggers have no input validation — this is a known design gap]
[Issue #18](https://github.com/tadasant/zimmer/issues/18) argues there is nothing between "event
arrived" and "agent running" except a `gsub` on a `prompt_template`. Untrusted Slack text is
interpolated straight into the prompt, and the agent is then trusted to act on identifiers it
read out of that text — making it a *trusted courier* for untrusted input. The proposal is a
third primitive (`Workflow`) between Trigger and Session.
Tracked in [#50](https://github.com/tadasant/zimmer/issues/50).
:::
