---
title: The session lifecycle
description: Every state, event, guard, and side effect in Zimmer's AASM session state machine — including the transitions the old docs never mentioned.
sidebar:
  order: 1
---

Every session is in exactly one of five states. The transitions between them are enforced by
AASM in `app/models/concerns/session_state_machine.rb`, and each one carries side effects that
are as important as the state change itself.

## The states

| State | DB value | Meaning |
| --- | --- | --- |
| `waiting` | 1 | Queued, or dormant awaiting a scheduled wake-up. The initial state. |
| `running` | 0 | An agent process is alive and a monitoring job owns it. |
| `needs_input` | 2 | The agent's turn ended, or it's blocked on an elicitation. This is your to-do list: agents archive themselves on completion, and a session waiting on its own PR archives when that PR merges, so what stays here is meant to need you. See [goals](/sessions/goals/). |
| `failed` | 4 | Terminal error. Resumable. |
| `archived` | 3 | In the trash. Restorable until the clone is reaped. |

The integer values are load-bearing (they're the existing ActiveRecord enum). A sixth state,
`corrupted` (5), was removed — sessions now go to `failed` instead.

## The full machine

```mermaid
stateDiagram-v2
    [*] --> waiting

    waiting --> running: start<br/>(guard: git_root present)
    running --> needs_input: pause
    needs_input --> running: resume
    waiting --> running: resume
    failed --> running: resume
    needs_input --> waiting: sleep

    running --> needs_input: block_on_elicitation
    needs_input --> running: unblock_from_elicitation<br/>(guard: blocked_on_elicitation?)

    waiting --> failed: fail
    running --> failed: fail
    needs_input --> failed: fail

    waiting --> archived: archive
    running --> archived: archive
    needs_input --> archived: archive
    failed --> archived: archive

    archived --> waiting: unarchive_to_waiting
    archived --> needs_input: unarchive_to_needs_input
    archived --> failed: unarchive_to_failed
```

:::note[The old `docs/SESSION_STATE_MACHINE.md` was missing five of these]
It documented `start`, `sleep`, `pause`, `resume`, `fail`, and `archive`. It did not
document `block_on_elicitation`, `unblock_from_elicitation`, or the three `unarchive_to_*`
events. It also claimed you cannot archive a running session — you can; `archive` transitions
from `waiting`, `running`, `needs_input`, *and* `failed` (the UI exposes this as force-archiving
a stuck session).
:::

## The events, and what they actually do

### `start` — `waiting → running`

Guarded on `git_root` being present. Resets the elapsed-time counter, records the session's
experimental-setting flags, and logs.

#### Experimental-setting flags

`start` and `resume` — **and no other transition** — call `record_experimental_setting_flags`,
which writes one row per experimental setting into `session_experimental_flags`. The first call
fixes the session's start-of-life value; every later one moves its end-of-life value. So a setting
toggled between two turns shows up as a disagreement between the two rather than silently landing
in one cohort.

Those two are the transitions at which an agent process is about to spawn, and a setting like MCP
tool search takes effect in the spawn environment — so observing there records what the session
actually ran with. The terminal transitions look like the natural home for the end-of-life value
and are the wrong one: `archive` and `fail` fire at bookkeeping moments that can land arbitrarily
long after the session last ran. `HealthMonitorService#archive_old_sessions` archives everything
untouched for seven days in a loop, so recording there would re-stamp each old session's end value
with today's setting, flip it to `mixed`, and quietly drain the control cohort of the comparison
the labels exist to support.

It is bookkeeping and behaves like it: the write is a single upsert, it swallows its own errors,
and the caller rescues again around it, so a cohort label can never be the reason a session fails
to start. Both of those rescues make the same exception the side-effect reporter does — they do
not swallow on a transaction Postgres has already aborted, because a transition that is going to
roll back either way is not one a swallow can save. See
[Experimental settings](/operate/costs/#experimental-settings) for what the labels are for.

`AgentSessionJob` adds a second guard ahead of the transition, and it is the one that makes a pause
mean something: **a session with a one-time wake-up still ahead of it does not get a first start.**
`waiting` is both "queued to spawn" and "deliberately asleep", and precedence says nothing about
which — so without this, every automated starter reads a paused session as a runnable one. The job
stands down, logs why on the session, and does *not* re-enqueue itself; the armed wake is the next
event in that session's life.

Only a first start is refused. A wake firing on time arrives as a follow-up prompt, `resume_monitoring`
re-attaches to a live process, and `clone_only` spends no turn — none of those is an early start, and
refusing them would strand the wake this guard exists to protect. See
[A pause outranks precedence](/sessions/spot-and-priority/#a-pause-outranks-precedence) for the other
three callers that decline, and why the guard lives here rather than in a prompt.

#### Entering `running` re-arms the fleet-idle event

An `after_commit` on the status column — not a hook on `start` and `resume` — calls
`FleetIdleMonitor.record_busy!` whenever a commit lands a session in `running`. The fact
[`no_sessions_in_progress`](/sessions/triggers/#no_sessions_in_progress) needs is "a session is
running", and every path that produces it has to count: both AASM events, an elicitation unblocking,
a session created directly in `running`. Missing one would leave that event's latch spent against a
fleet that had gone back to work, because a session that starts and finishes inside one cron tick is
invisible to the sweep that samples for it.

It does not cover `update_column` / `update_all`, which skip callbacks — no caller writes `status`
that way, and the sweep re-arms on its next tick regardless, so this is the fast path rather than
the only one.

The re-arm is **unconditional**: it does not ask whether the fleet is now over the event's ceiling.
Since that ceiling defaults to 3, a fleet is routinely still "idle enough" while a session runs — but
a ceiling-aware re-arm would leave the clock frozen behind the last fire on a fleet that never climbs
above the ceiling, and the event would fire exactly once in the deployment's life. Ending the stretch
is what hands the cadence to the cooldown. See
[The latch is not enough on its own](/sessions/triggers/#the-latch-is-not-enough-on-its-own).

After the commit, and best-effort: a transition is never slowed or rolled back by this bookkeeping.

### `pause` — `running → needs_input`

Fired when the agent's turn ends (the process exits normally). This is the workhorse
transition, and it does nine things beyond changing status:

1. `warn_if_pr_goal_captured_no_url` — if the session's goal mentions a pull request and
   `custom_metadata["github_pull_request_urls"]` is still empty, write one `warning` log to the
   timeline. `GithubPrUrlHook` only records a PR it can see the session open, and an empty list is
   otherwise indistinguishable from "no PR to record" — see
   [transcript hooks](/extend/transcript-hooks/). Never raises, and once per **session**, not once
   per event: `fail` and `archive` call it too, and the dedup is on the warning log itself, so a
   session that pauses, warns, and later archives says it once.
2. `cleanup_running_job` — clears `running_job_id`.
3. `bump_needs_input_transition_counter` — one increment of
   `custom_metadata["needs_input_count"]`, handed to both of the next two steps as their debounce
   marker. Bumped here rather than inside either consumer, because two bumps would make each one's
   marker stale to the other and suppress both. It has its own rescue for the same reason every
   other side effect does: a raise here must not wedge the transition.
4. `fire_settled_needs_input_ao_event(marker)` — wakes anything watching this session, *if the
   session is still at rest when the settle window closes*. See
   [a turn boundary is not a rest](#a-turn-boundary-is-not-a-rest). Skipped entirely for a
   recovery pause; see [which pauses announce themselves](#which-pauses-announce-themselves).
5. `enqueue_debounced_needs_input_push_notification(marker)` — see below. Skipped for a recovery
   pause, for the same reason. Steps 4 and 5 are the pause's *announcement* and travel together.
6. `enqueue_session_inference_if_needed` — LLM-generates a title and category if still pending.
   Skipped when a `SessionTitleJob` for this session is already queued and not yet claimed: it
   reads the transcript when it runs, so a second one behind it would only find the work done. The
   job `Session` schedules two minutes after creation counts, so a session that comes to rest inside
   those two minutes is titled when that job fires rather than at the pause. Without a transcript
   the title is deterministic, from
   [the human's own prompt](/sessions/hierarchy-and-human-messages/#what-is-captured-and-what-is-not)
   rather than the composed one the runtime received.
7. `enqueue_status_summary_refresh` — the **only** automatic trigger for the
   [Status summary](/sessions/status-summary/). The generator still refuses when the session has
   not moved since the last one, so a transition that added no transcript costs nothing. Skipped
   the same way when a `SessionStatusSummaryJob` for this session is queued and not yet claimed —
   see [one generation at a time](/sessions/status-summary/#one-generation-at-a-time).

   Both checks are `PendingSessionJob`, a read on the job table. A job already running does not
   count: it took its snapshot when it started, and the fresh enqueue is answered cheaply by its
   claim. The checks exist because a session sleeping and waking on a short self-wake pauses once
   per wake, and without them each pause stacks one more of each job behind the ones already waiting.
8. `execute_pending_sleep` — if a wake-up was scheduled while the session was *running*, the
   sleep was deferred to here; now it fires.
9. `drain_enqueued_messages_after_pause` — if the session is coming to rest with a message still
   queued for it, schedule the delivery. See [below](#a-session-does-not-idle-on-its-own-queue).
   Runs last, and after `execute_pending_sleep`, so it reads the state the sleep left behind: a
   session that just went dormant is asleep with a wake armed, not idling.

Steps 3–7 are skipped for one kind of session: a **status-summary fork**, which is Zimmer's own
throwaway (marked in metadata by `SessionStatusSummaryGenerator::FORK_MARKER`). Its pause means its
one turn is finished, so it is harvested and archived instead of notifying anyone or landing in the
action queue.

#### A turn boundary is not a rest

`pause` runs at the end of **every** turn, and plenty of those turns end with the session on its way
somewhere else rather than waiting for anyone. Steps 8 and 9 above are the two routine cases, and
both are decided *inside this same callback*: a session holding a `pending_sleep` goes straight back
to `waiting`, and a session with a queued message is resumed by `EnqueuedMessageDrainJob` seconds
later.

That made `session_needs_input` a much noisier signal than its name suggests. Router session #9964
was woken four times in 25 minutes by child #9966 — a completely healthy session that had opened a
PR and was cycling through the open-pr skill's bounded self-wake, crossing `needs_input` for
microseconds on each pass back to `waiting`. Every one of those wakes cost the router a full agent
turn and four trigger writes, because a fired one-time wake destroys its siblings and they all had
to be re-registered.

So the event is now **settled** rather than emitted on the edge. The job is enqueued with a
`wait:` of `SessionStateMachine::NEEDS_INPUT_SETTLE_WINDOW` (30 seconds) and the marker from step 3;
when it runs, it is dropped unless `Session#resting_in_needs_input?` still holds — the session is
still in `needs_input` — and unless the marker still matches, which is how a later transition
supersedes an earlier one's event.

`fail` and `archive` emit through the unchanged `fire_ao_event_triggers`, immediately: a terminal
state cannot flap, and delaying the event that ends a wait would be pure latency.

`resting_in_needs_input?` asks about **status and nothing else**, which is deliberate and is the
part worth reading the reasoning for — it is in
[Triggers](/sessions/triggers/#resting_in_needs_input-asks-about-status-and-only-status). The short
version: every richer test considered can only still be true when the window closes if the thing
that was going to move the session has failed, and those sessions are precisely the ones a watcher
must hear about. Nothing re-emits this event, so suppressing them would lose the wake rather than
delay it.

`block_on_elicitation` emits through the same settled path, and bumps the same counter. That is a
change: it never bumped before. It matters only in the narrow case where a `pause` and an
elicitation land inside the 60-second push debounce, where the elicitation now invalidates the
in-flight `needs_input` push — which is the right outcome, since that path already sends its own
`elicitation_pending` push and the transition's comment says avoiding a double-notify is the point.

The debounce is worth understanding. Sessions sometimes flap `running → needs_input →
running` between turns, and without debouncing every flap would push a notification. So the
push job is enqueued with a 60-second delay (`NEEDS_INPUT_DEBOUNCE`) carrying a monotonic
marker from `custom_metadata["needs_input_count"]`. If the session churns during the window,
the marker won't match and the deferred job no-ops.

#### Which pauses announce themselves

Steps 4 and 5 are the pause's **announcement**: the settled `session_needs_input` wake that reaches every watcher, and the push notification that reaches the human. `running → needs_input` is one transition covering several unrelated situations, and only some of them mean "a person is now needed here".

| Pause | Announced? | Why |
| --- | --- | --- |
| The agent's turn ended | **yes** | The session is at rest waiting on a human. This is what the transition is for, and it is the hot path. |
| A human hit Pause (`paused_by: "user"`), an interrupt, an API/MCP/web pause | **yes** | Also at rest, and a watcher wants to know the session stopped. |
| Zimmer recovering its own interrupted process (`paused_by: "recovery"`) | **no** | The session is not waiting on anybody. It is on its way back to `running` under a continuation that owes it a restart. |
| Zimmer giving up on a session that never wrote a line (`unstarted_turn_restart_abandoned`) | **yes** | Writes no recovery marker, because no sweep can restart it. See [A session that never wrote a line](#a-session-that-never-wrote-a-line-is-restarted-not-parked). |
| A status-summary fork | **no** | Zimmer's own bookkeeping, harvested rather than queued. Skips steps 3–7, not just the announcement. |
| Parked on an auth or quota outage (`AuthOutageParkService`) | **yes** | Deliberately writes *no* recovery marker, precisely so it is not swept back into an exhausted pool. A parked session is a real stop and is announced as one. |

The settle window above does not cover the recovery case, and the arithmetic is why the carve-out exists. The boundaries the window suppresses leave `needs_input` within microseconds (a self-wake) or ten seconds (a queued-message drain). A recovery pause does not: the fastest thing that moves the session is `RecoveryContinuationJob`'s 30-second delay, and behind that `CleanupOrphanedSessionsJob`'s five-minute cron, so at settle time it is still sitting in `needs_input` and `resting_in_needs_input?` — status and nothing else, by design — says yes. It would fire.

So the marker is read at the source instead. Every recovery path writes `metadata["paused_by"] = "recovery"` immediately before `pause!` — `AgentSessionJob`'s dead-process branch and its `GoodJob::InterruptError` handler, and `SessionRecoveryService#transition_to_needs_input` — and `SessionStateMachine#recovery_pause?` reads it in the `pause` callback. **The state transition still happens.** The session really is in `needs_input`, really is in the homepage action queue, and the timeline still says so. Only the two outward signals are withheld.

That matters because a fired one-time wake destroys its siblings. The pattern [`wake_me_up_when_session_changes_state`](/sessions/triggers/) documents for watching a child is a wake set plus a `wake_me_up_later` deadline, so a single spurious `session_needs_input` costs the watcher the whole set — including the backstop that was supposed to catch a genuinely hung child.

**The pause transition is not the only door into that wake.** `Trigger#fire_ao_event_immediately_if_state_matches` exists so that a watcher registered *after* the transition already happened does not sleep forever: it row-locks the watched session at trigger-creation time and fires at once if it is already in the target state. A status-only test there would deliver the same spurious wake a few seconds later, through the other door — and a router that spawns a child and immediately watches it is the common shape, with a freshly-spawned session whose process died being exactly the case this carve-out is about. So the immediate-fire path asks `announcement_deferred_to_recovery_sweep?` too, and leaves the watcher armed rather than firing. The armed watcher is reached by whichever announcement eventually happens: both enqueue the same `AoEventTriggerJob`, and that job re-queries the enabled conditions when it runs, so a condition created mid-pause is picked up rather than missed.

**The suppression is a deferral, not a deletion, and that is what makes it safe.** `RecoveryContinuationJob` (asked for by the parking code itself, on a 30-second delay), `CleanupOrphanedSessionsJob` (every five minutes) and `DeploymentRecoveryJob` (once at boot) all select on `paused_by = 'recovery'` and auto-continue what they find. `SessionContinuation` bounds that at `MAX_CONTINUE_ATTEMPTS` — roughly an hour — and when it gives up it drops the marker, writes an `error`-level "will not be retried again" line, **and makes the announcement the pause skipped**, via `Session#announce_deferred_needs_input!`. So a recovery-paused session that is never continued still wakes its watchers and still pushes, exactly once, at the moment it stopped being Zimmer's problem and became a human's.

Which is why the carve-out asks whether a sweep is actually coming, not merely whether the marker is set. A session parked in a **frozen category** is excluded from every query in both sweeps (`Session.not_in_frozen_category`), so there is no deferral to make — nothing continues it, and `SessionContinuation` never runs to announce it later either. That pause is announced at the time, like any other stop. `AgentSessionJob`'s recovery-pause writers do not check the category, because they run inside the session's own job rather than in a bulk recovery flow; `SessionRecoveryService` bails on a frozen category before it ever pauses.

Two edges the deferred announcement deliberately does not cover. A session abandoned in `failed` already fired `session_failed` and an unconditional failure push when it failed. A session bounced to `waiting` by `execute_pending_sleep` is dormant, and telling a watcher it "needs input" would be a claim about a state it is not in — the settled event would drop it anyway.

#### A session does not idle on its own queue

`needs_input` and `archived` are the two states in which a session stops draining its queue, and
the same invariant covers both: **a session must not come to rest with a message still queued for
it.** What differs is what can be done about it. Archiving ends every delivery path, so the honest
answers there are to refuse the transition and to record the discard —
[below](#archiving-retires-the-message-queue). `needs_input` ends nothing. An idle session is
precisely the condition a queued message is waiting for, so the answer here is to deliver it and
keep running.

Most of that already happened before this transition. `AgentSessionJob` drains the queue at each
of its four turn-end paths and does it **before** calling `pause!`, so the session hands the turn
over while still `running` and never flaps through `needs_input` — no spurious
`session_needs_input` wake, no push notification. That is still the hot path. What that ordering
cannot cover is:

- **The race.** The drain reads the queue, finds it empty, and *then* `pause!` commits. A message
  enqueued in that window lands `pending` on a session that is already idle.
- **Every pause that isn't a turn ending.** The MCP `pause` action, `POST
  /api/v1/sessions/:id/pause`, the web pause button, `Sessions::InterruptService` and
  `SessionRecoveryService` all call `pause!` directly with no drain of their own.
- **A message queued onto a session that is already idle.** None of the three create surfaces —
  the web queue form, `POST /api/v1/sessions/:id/enqueued_messages`, MCP
  `manage_enqueued_messages` — checks the session's state, and all three answer that the message
  goes out *when the session becomes idle*. An `EnqueuedMessage` `after_create_commit` hook covers
  this one.

Nothing else would have picked any of them up. `HeartbeatSweepJob` is the only sweep that wakes an
idle session, and it deliberately skips one holding a pending message — on the assumption,
previously untrue, that something else was about to deliver it.

Both entry points schedule an `EnqueuedMessageDrainJob` rather than draining inline. AASM runs
`after` callbacks inside the transition's own transaction, and delivering means resuming the
session — a second AASM event nested in the first, plus an `AgentSessionJob` enqueue — from
whatever thread called `pause!`, including a web request. The job runs once the transition is
committed, after a 10-second delay that lets the callers which pause-then-immediately-deliver
(`Sessions::InterruptService`, `SessionContinuation`'s auto-continue) finish first.

The job itself opens **no** transaction and takes no advisory lock, which is load-bearing rather
than an omission. `EnqueuedMessageProcessorService#process_next_message` opens its own transaction
and rescues everything inside it, and a Rails `transaction` block *joins* an open one instead of
nesting under a savepoint — so wrapping the call would turn the service's rescue from "roll the
claim back and return false" into "swallow the error and let the outer transaction commit whatever
got written", which can mean a message claimed and destroyed with no `AgentSessionJob` behind it.
Unwrapped, the service's transaction is the outermost one and a mid-delivery failure rolls the
message back to `pending`. Concurrency is already the service's job: the claim is a `FOR UPDATE
SKIP LOCKED` on the row plus a `lock!` on the session, and `AgentSessionJob`'s end-of-turn drain
calls it bare for the same reason.

The job refuses to deliver in three states, because in each the session genuinely cannot take a
message and delivering would make things worse:

| State | Why not |
| --- | --- |
| Blocked on an MCP elicitation | The agent process is still alive. Resuming spawns a second process against one clone and orphans the round-trip. |
| Parked by `AuthOutageParkService` (`auth_outage_reason`) | A fresh turn hits the same quota or auth wall, burns the message, and parks again. `AgentSessionJob`'s own drain reads the same marker. |
| `paused_by: "mcp_retry"` | A retry carrying the original prompt is already scheduled; delivering now races it into the same failing MCP server. |

**The dead-process case.** A drain does not need the old agent process — it enqueues a fresh
`AgentSessionJob` that resumes the runtime session from `session_id` and the working directory,
exactly as a human follow-up does. So a session whose process died still takes its message. What
it cannot survive is a missing clone or `session_id`: there `AgentSessionJob` fails the session
with a `failure_reason`, and the message stays `pending` on a `failed` session, where the recovery
paths (`SessionContinuation#continue_with_queued_user_message`) already prefer a queued user
message over the automated recovery prompt when they auto-continue it.

**No spin loop.** Each successful delivery destroys a row, so the queue strictly shrinks. Failure
is what needs bounding: three attempts, 30 seconds apart, counted in
`metadata["enqueued_drain_attempts"]` and cleared by `resume` so each idle spell gets its own
budget. After that the job stops and raises an alert, deduped per session. It deliberately does
**not** retire the messages to `undelivered` the way an archive does: it could not deliver them, but
the next turn anybody gives the session drains the queue normally. Retiring here would destroy a
still-deliverable message in order to record that this job could not deliver it.

One consequence worth naming: a *user-initiated* pause on a session with a queued message resumes
within seconds. That is the invariant working as stated rather than an oversight — the queued
message is input the user was told would be delivered, and pausing the current turn is not the
same as withdrawing it. To stop it, delete the queued message.

### `resume` — `waiting | needs_input | failed → running`

Unguarded, deliberately. The preconditions for resuming — a clone on disk, a runtime
session id to resume into, a live process to reattach to — are established or validated by
`AgentSessionJob`, which recovers what it can and fails the session with a specific
`failure_reason` when it cannot. The state machine does not re-check them, so a resume you
ask for is a resume the job gets to attempt.
Clears a pile of stale state: MCP failure flags, the `paused_by` marker, the
`blocked_on_elicitation` and `lost_elicitation` markers, any `pending_sleep`, the
`enqueued_drain_attempts` counter (so each idle spell gets its own retry budget), and,
importantly, it cancels pending one-time wake-up triggers targeting this session, so a scheduled
wake doesn't fire on a session you already resumed by hand.

#### `mcp_servers_status` is reset on resume, not deleted

`clear_stale_mcp_failure_metadata` drops four keys outright — `should_fail_session`,
`mcp_connection_checked`, `mcp_failed_servers`, `mcp_failure_reason` — because each is a verdict
the *previous* run reached, and a resume that inherited `should_fail_session` would fail the new
run before its servers had any chance to connect.

`custom_metadata["mcp_servers_status"]` is treated differently: every entry is reset to
`{"status": "pending"}` for the servers in `Session#all_mcp_servers`, rather than the key being
deleted. Its entries do all have to go — a `connected` recorded by the process that just exited
says nothing about the one about to start — but deleting the key is what left it **missing
entirely** on sessions that plainly had MCP servers
([#465](https://github.com/tadasant/zimmer/issues/465)). It came back only once the next run got
far enough for `TranscriptPollerService` to reach `McpStatusPersisting`, and a run that died
before its transcript appeared never got there. The REST API and the `get_session` MCP tool hand
`custom_metadata` back verbatim, so an absent key reads as "this session has no MCP servers" —
and, in the triage that reported the defect, as "the servers never came up". `pending` says what
is actually true at a resume, and the detector upgrades each entry as its evidence arrives.

The reset spans the union of `all_mcp_servers` and the names already in the hash. `all_mcp_servers`
alone would hand the key's survival to a catalog read that fails soft — `plugin_mcp_servers` returns
`[]` when the AIR catalog cannot be resolved — so a blip at resume time would empty the reset for a
plugin-only session and delete the key, which is the defect itself.

An unchanged reset writes nothing, so an ordinary resume of an already-`pending` session issues no
extra `UPDATE`. `AgentSessionJob` then applies a related but weaker operation immediately before the
spawn: `Session#seed_mcp_servers_status_floor!`, which adds `pending` **only where no entry exists**
and so leaves a carried-over status alone. It runs there because that is the first point at which
`air prepare` has run and `all_mcp_servers` therefore includes whatever AIR auto-injected. The
[MCP server OAuth page](/auth/mcp-oauth/) has the detector-side half of the same floor, under *"A
server that fails before it connects is listed as `pending`, not omitted"*.

#### A live execution is not an interruption

"Interrupted" is one column. `GoodJob::Job#perform` raises `InterruptError` whenever it picks a
row that already has a `performed_at` — it never asks whether anything is still executing that
row, because in the case it was written for (a worker that died) there is nothing left to ask.

A row becomes re-pickable the moment its advisory lock goes away, and with GoodJob's default
`:advisory` strategy that lock is a **session-scoped lock on one pooled Postgres connection,
held for the whole execution**. For every other job in Zimmer that window is milliseconds. For
an agent session it is the length of an agent's turn — minutes to hours, and the worker's own
comment in `config/environments/production.rb` already says so. Lose that one connection
anywhere in that window and the lock is released while the agent is still working; the dequeue
scope is `finished_at IS NULL` and does not exclude rows that have a `performed_at`, so the
poller picks the live row straight back up.

That is a **phantom re-pick**, and it was the dominant source of recovery nudges. Over three
hours of production logs on 2026-08-29, ~38 interrupt events across ~19 sessions produced ~36
delivered nudges and **not one** stand-down by any existing guard. Every fire's embedded
`Interrupted after starting perform at '<time>'` was 30 seconds to 8 minutes older than the
fire itself; in every one the previously spawned CLI was still running and had never been
terminated, and a second CLI was spawned two to seven seconds later — two agents against one
clone. One session took **16 nudges in 71 minutes** in a self-feeding loop, each fire naming
the job the previous fire's nudge had just spawned. The fires arrived in fleet-wide clusters
(three different sessions inside the same second, seven such moments in three hours), which is
one worker losing many locks at once rather than per-session flakiness — the connection-layer
saturation of [#329](https://github.com/tadasant/zimmer/issues/329) is the mechanism that fits.

So the handler's **first** guard asks whether this job is still executing, here, right now.
`AgentSessionJob::LIVE_EXECUTIONS` is a process-local set of `job_id`s currently inside
`#perform`. A re-picked execution never registers in it: GoodJob's `InterruptErrors`
`around_perform` is declared on `ApplicationJob`, and a superclass's around callback wraps its
subclasses', so it raises before the inner one can add anything. A hit therefore means a
*different* thread in this same process is inside `#perform` for this same job — which is only
true when the lock was lost out from under a live execution. A worker that really died takes
its set with it, so the genuine case never sees a false hit.

Standing down there means standing down completely: no `running_job_id` cleared, no `paused_by`
written, no pause, no nudge. Each would be an act against a session whose agent is mid-turn.

**Suppressing the handler's own nudge is not enough on its own**, because the re-pick leaves the
row lying about itself. GoodJob stamps it with an `error` at re-pick time and a `finished_at`
when the raise is rescued, and `CleanupOrphanedSessionsJob#orphaned_running_session?` and
`DeploymentRecoveryJob#orphaned_running_session?` both return true on either of those *before*
they reach any liveness question. So a phantom re-pick the handler correctly ignored would still
be swept within five minutes, running the identical cascade under a different log line. Both
sweeps therefore ask `AgentSessionJob.executing?` first, and GoodJob's cron runs inside the
worker, so the set they read is the one the live execution registered in.

The set is deliberately not durable. A re-pick landing in a second worker process finds it
empty and falls through to the recovery path, which is the safe direction; Zimmer's `worker`
role is one container running one `good_job` process, so in practice every re-pick and every
sweep lands where the entry is. That gap is recorded in
[limitations](/limitations/#the-phantom-re-pick-guard-is-process-local).

#### A finished turn is not an interruption

The other way a row is re-picked when nothing was interrupted is after the turn already ended.
`AgentSessionJob#handle_interrupt_error` used to treat every re-pick as "the deploy killed us
mid-turn" and resume the session with `AutomatedPrompts::SYSTEM_RECOVERY`.

That is right when the session was still `running`. It is wrong when the turn had already
finished. A normal completion transitions `running → needs_input` and, in the same callback
chain, clears `running_job_id` — so the ownership check that would otherwise catch a stale
re-pick sees nothing to defer to, and the recovery path resumes a session that was correctly
waiting for its human. Over one representative production week that race accounted for 44% of
interrupt events and 39% of all recovery nudges sent.

So the handler stands down when the session is already at rest. The test is deliberately
**positive** — it names the states that are genuinely done being driven, and everything else
falls through and recovers as before. `metadata["paused_by"]` carries most of that:

| `paused_by` | Reached `needs_input` by | On `InterruptError` |
| --- | --- | --- |
| absent | the agent finishing its turn | stand down — nothing was interrupted |
| `"user"` | somebody pausing it by hand | stand down — the pause was deliberate |
| `"recovery"` | an earlier recovery pass parking it — or `degrade_mcp_servers!` resuming a session on the servers that did connect | recover, as before |
| `"mcp_retry"` | `schedule_mcp_retry` parking it for a delayed retry | recover, as before |

A negative test ("anything but `recovery`") would have been wrong: `mcp_retry`'s only route
back to `running` is its delayed retry job, and both recovery sweeps match `paused_by =
'recovery'` exactly — so standing down on it would strand the session where nothing looks.

`paused_by` is not the whole story either. **`blocked_on_elicitation` reaches `needs_input`
from `running` carrying no `paused_by` at all**, and keeps its `running_job_id`, because the
agent process is still alive mid-turn waiting on an approval. That is not a session at rest,
so it is excluded from the stand-down and still recovers.

A session still `running` when the interrupt lands is unaffected and recovers exactly as before.

#### `waiting` is three different situations, and none of them is a recovery

The handler used to push every `waiting` session through `waiting → running → needs_input` so a
sweep could pick it up. `waiting` is reached three unrelated ways, and that was wrong for each.

**No runtime session id yet.** `perform` did not reach the point where it issues one, so nothing
durable exists and there is nothing to resume. The repair is to **run the job again**, so the handler
re-enqueues this job's own arguments verbatim and leaves the session in `waiting`.

Pausing it instead is what stranded [spot-held](/sessions/spot-and-priority/) sessions. A spot hold
lives entirely in `waiting`, and the only thing that ever schedules the next re-check is the
re-check job itself — so severing that chain meant the session could never start again. One
`issue-work-gate` session was held correctly 120 times over 22 hours, then had one re-check job
re-picked and spent the next 20 hours in `needs_input` with an empty transcript on a human's action
queue.

The replay is bounded by `MAX_INTERRUPTED_START_REQUEUES`. Exhausting it fails the session with a
`failure_reason` naming the cause, which is loud and visible — the one thing a queued session must
never do is disappear quietly.

**Asleep on purpose.** `wake_me_up_later` runs a session `running → needs_input → waiting` inside a
single `pause` callback, via `execute_pending_sleep`. An interrupt landing in that window dragged the
sleeper back awake and spent a turn on a recovery nudge, cancelling the wake it had just scheduled.
Nothing was interrupted there either — the turn finished — so the handler stands down and lets the
wake fire.

The discriminator is `Session#awaiting_scheduled_wake?`, not a metadata flag, because a session that
slept successfully carries none: `execute_pending_sleep` clears `pending_sleep` once `sleep!`
succeeds, and writes no `paused_by`. The armed-wake query is the only signal there is.

**Parked on an outage.** `AuthOutageParkService` parks a session in `waiting` when every account
in the pool is out of quota, and it arms nothing at all — its own sweep over
`metadata->>'auth_outage_reason'` is what wakes it. So it matched neither of the signals above
and fell through to the recovery path, which stamps `paused_by: "recovery"` over the park. The
auto-continue then declines (the session is `waiting`, not `needs_input`) — but the marker is
the part that does the damage: `DeploymentRecoveryJob` and `CleanupOrphanedSessionsJob` both
match `[:needs_input, :waiting]` with `paused_by = 'recovery'`, so within a sweep or two they
resume a session into the outage that parked it. [Quota depletion is budget
pacing](/sessions/spot-and-priority/), not a failure signal; a park is a wait, and this was how
the wait got ended early. `AuthOutageParkService.parked?` is the discriminator, the row-level
sibling of `SpotSessionPause.paused?`.

**Anything else in `waiting` that has run.** Chiefly the window between the session id being issued
and `start!` firing, which spans the clone, the AIR prepare and the spawn — seconds to minutes, and a
deploy is exactly what lands in it. That session is stranded rather than resting, and unlike the
first case it has a session id and a clone, so it takes the ordinary recovery path. `pause` is
`running → needs_input`, so it stays in `waiting` carrying `paused_by: "recovery"` — which is swept,
because both continuation queries match `[:needs_input, :waiting]` on that marker and `resume`
accepts `waiting`.

#### A session that never wrote a line is restarted, not parked

`AgentSessionJob`'s `resume_monitoring` path has exactly one plan: re-attach to the pid recorded in
`metadata["process_pid"]`. When that pid is dead there is nothing to monitor, and the question that
decides what to do next is **whether there is a conversation to come back to.**

`metadata["runtime_started"]` does not answer it. That flag is written the moment Zimmer records a
spawned pid, before the runtime has produced a line, so a process killed in its first seconds leaves
it `true` over a conversation that was never persisted. `RuntimeConversationPresence` answers it
properly, and asks **both** transcript stores — Zimmer's polled copy and the runtime's own file — so a
merely lagging poller can never be enough to conclude that nothing was written.

| The runtime wrote… | What happens |
| --- | --- |
| a conversation | Park with `paused_by: "recovery"`, as before. The session is mid-turn; a resume picks up where it left off. |
| nothing | `Sessions::RestartUnstartedTurn` replays the session's own prompt into a fresh spawn. Nothing was consumed and no partial work exists, so the stored prompt is exactly what should run. |
| nothing, `RetryBudget::EMPTY_TURN.max` times | Come to rest in `needs_input` with `failure_reason: "unstarted_turn_not_recoverable"`, `metadata["unstarted_turn_restart_abandoned"]` naming the reason, and **no** recovery marker — no sweep can do anything a third restart would not. The pause announces itself. |

This is the same judgement [`ProcessLifecycleManager#handle_empty_turn`](/sessions/spawning/) makes
when a process exits under a live monitor, arriving from the other direction: there the turn ended in
front of us, here it ended while nobody was watching. They share both the budget and the
`empty_turn_recovery_count` key deliberately — it is one event seen from two vantage points, and a
session that has already burned its restarts in-process does not get a second allowance because the
next failure happened to be a worker interruption. It is one `RetryBudget` object
(`RetryBudget::EMPTY_TURN`), so it is also one reset: a stable stretch hands the restarts back to
whichever vantage point needs them next, rather than either one being a lifetime cap.

The restart takes a **new runtime session id** (or, for a runtime that mints its own, drops the
stored one) and turns `runtime_started` off, so the replacement spawn builds `--session-id` rather
than `--resume`. Re-asserting the old id would hit the #519 trap: a transcript holding only the
runtime's own bookkeeping is simultaneously too present to create against ("already in use") and too
empty to resume ("no conversation found").

The behaviour this replaced: on 2026-09-02 a worker interruption caught production sessions 12265 and
12267 at once. 12265 had made tool calls and resumed harmlessly. 12267 had produced nothing — zero assistant
turns, zero tool calls — and sat in the homepage action queue with a completely empty transcript,
indistinguishable from a session asking a question, for nine and a half minutes, until an unrelated
orphan sweep reached it.

#### The recovery pause asks for its own continuation

A recovery pause is a promise that a sweep will continue the session, and with only
`CleanupOrphanedSessionsJob`'s five-minute cron to keep it the wait is whatever is left of that
cron's period. The two mechanisms can also cancel out: the nudge `AgentSessionJob` enqueues after a
worker interruption is dropped when a recovery job is already queued ("Skipping job - session already
has a running job"), and when that recovery job then fails to adopt its dead pid it re-enqueues
nothing at all — leaving the session with no pending work of any kind.

So the dead-process branch asks for the continuation itself. `RecoveryContinuationJob` is scheduled
with a 30-second delay and delegates to the very same `SessionContinuation` the sweeps use, so there
is one implementation of "continue a recovery-paused session" and one attempt budget. Every guard the
sweeps apply is re-asked of the row at delivery time — still `paused_by: "recovery"`, still
`needs_input` or `waiting`, not in a frozen category — because all three can change inside the delay
window, and `Session#claim_system_recovery_turn!` re-reads the row `FOR UPDATE` so a cron tick
landing at the same moment cannot produce two turns. The cron stays the backstop rather than the
mechanism.

**This covers one of the six writers of `paused_by: "recovery"`, deliberately.** It is scheduled by
`AgentSessionJob`'s dead-process branch — the one the nine-and-a-half-minute stall came through.
`SessionRecoveryService#transition_to_needs_input`, `AgentSessionJob`'s `InterruptError` and
MCP-retry parks, and the two sweeps' own re-parks still rely on the cron.

#### Auto-continue gives up

`SessionContinuation#continue_recovered_session` needs a `session_id` and a clone on disk. For a
session paused before it ever started, neither will ever exist, and no amount of waiting produces
them. Both sweeps select on `metadata["paused_by"] = "recovery"`, so an unbounded retry meant the
5-minute orphan cron re-read the same session forever — 500+ identical "auto-continue skipped" log
lines for one session that never ran.

After `MAX_CONTINUE_ATTEMPTS` failures the sweep gives up: it drops the `paused_by` marker (which
is what both sweeps select on, so the session stops being swept), records
`metadata["recovery_continue_abandoned"]` with the reason, and logs it once at `error`. The session
comes to rest wherever it already was — `needs_input` or `waiting` on the ordinary path, still
`failed` when the caller was the InterruptError-failed branch — for a human to restart, which is the
honest state for one Zimmer cannot restart itself.

The budget is sized for the *other* thing the validation reports. A missing working directory can be
transient — a volume not yet mounted after a boot, a clone being restored — so the count is set to
roughly an hour against the 5-minute cron, long enough for a blip to clear and still bounded. The
writes go through `merge_metadata!` rather than `update!`: a read-modify-write would run Session's
validations, including the [globally coupled](/air/zimmer-integration/) agent-root and catalog-skill
checks, and a `RecordInvalid` swallowed by the caller's per-session rescue would stop the counter
advancing — restoring the unbounded loop for exactly the sessions least likely to be recoverable.

#### The nudge names the path that sent it

A dozen paths enqueue the same `SYSTEM_RECOVERY` constant — a deploy, an orphan sweep, a SIGTERM
retry, an API-error retry, a quota park lifting, a manual restart. Sending one undifferentiated
string means neither the agent nor the human reading over its shoulder can tell which fired, and
"this should only happen on a deploy" is the reasonable conclusion it invites — in that same
week, fewer than a third of these nudges were within ten minutes of a deploy.

`AutomatedPrompts.system_recovery(reason:)` appends one line naming the path, after the standing
instructions, so the prompt's meaning is unchanged for an agent that ignores it.
`AutomatedPrompts.system_recovery?` is the matching predicate — compare with it rather than `==`
against the constant, or a reasoned nudge will be mistaken for an ordinary follow-up and consume
the wake-ups the next section exists to preserve.

**Three producers name themselves today**, and between them they account for the large majority
of nudges by volume: the `InterruptError` auto-continue, `SessionContinuation` (which covers both
the orphan sweep and deployment recovery, via `continuation_source`), and `AuthOutageParkService`
resuming a session whose login pool refilled. The rest — the SIGTERM retry, the API-error retry,
the auth-recovery resume, the health monitor, the manual restarts from the web UI, the REST API
and the MCP tool, and the `ProcessLifecycleManager` continuations — still send the bare constant.
`system_recovery(reason: nil)` returns it unchanged, so converting one is a one-line change; the
gap is unfinished work, not a designed-in default.

#### A system-recovery resume keeps the wake-ups

That cancellation is right for a *deliberate* resume and wrong for a recovery one. When Zimmer
restarts a session's process after an interruption — a deployment restart, an orphaned process, a
hung process reaped, a health-monitor retry — the session did not choose to wake, so the wake-ups
it was sleeping on are still exactly what it is waiting for. Consuming them there is how an
orchestrator gets stranded: it comes back with nothing armed, ends its turn, and sits in
`needs_input` indefinitely with children it was supposed to be watching.

Recovery paths therefore call `Session#resume_for_system_recovery!` rather than `resume!`. It sets
the transient `system_recovery_resume` flag for the duration of the transition, and
`cancel_pending_one_time_wake_triggers` takes a preserve branch instead:

- The pending conditions are **left armed** — nothing is consumed.
- If one of them is a one-time *schedule* (a `wake_me_up_later` deadline backstop), `pending_sleep`
  is set so the session returns to `waiting` once the recovery turn ends. A wall-clock wake fires
  regardless of what else happens, so sleeping on it cannot strand the session.
- If the only pending wakes are session-scoped `ao_event` watchers, the session comes to rest in
  `needs_input` with those watchers still armed. A watched session may have reached the state being
  watched for *during* the outage, and that transition is not replayed — so sleeping would trade a
  long stall for an indefinite one. `Trigger#follow_up_session!` delivers to a `needs_input` session
  just as well, and the operator can see it in the meantime.

That re-sleep is conditional at execution time as well as at resume time. It is recorded as
`pending_sleep` plus a `pending_sleep_requires_wake` marker, and `execute_pending_sleep` drops it
rather than sleeping if nothing is armed by the time the turn ends. A backstop whose wall time
elapsed during the outage is due the moment recovery resumes the session, so it can fire mid-turn,
destroy its siblings and hand off to a new turn without ever pausing — and sleeping on that stale
intent would leave the session in `waiting` with nothing armed and no `paused_by`, invisible to both
recovery sweeps. A deliberate sleep (`POST /api/v1/sessions/:id/sleep` on a running session) carries
no marker and is always executed, because arming nothing is exactly what it means.

One recovery path deliberately does *not* preserve: when `continue_recovered_session` finds a queued
user message, it delivers that instead of the recovery prompt, via a normal `resume!`. A waiting
user message means someone has taken the session over, which is the case the cancelling semantics
are for.

The automatic recovery paths do not call `resume_for_system_recovery!` directly — not the two
sweeps, not the hung-process auto-restart, not the stranded-sleep rescue, not the failed-session
retry, not the auto-continue after a job interruption. They go through
`Session#claim_system_recovery_turn!`, which takes the row lock, refuses a session the trash
swallowed since the caller read it, and calls the preserving resume only on the way to `:claimed` —
see [Spawning and monitoring](/sessions/spawning/) for both halves of that guard and for the
resumers outside this family that lock by hand instead,
[#554](https://github.com/tadasant/zimmer/issues/554) for what it costs when it is missing, and
[#753](https://github.com/tadasant/zimmer/issues/753) for the tail of the family.

The invariant this restores: a session that was in `waiting` with wake-ups registered does not
silently end up in `needs_input` with none.

### `sleep` — `needs_input → waiting`

The "wake me up later" path. The session goes dormant and a one-time schedule trigger will
resume it. If the wake-up is scheduled while the session is *running*,
`metadata["pending_sleep"] = true` is set and the actual transition happens on the next `pause`.

A park that passes `"halt": true` does not wait for that next `pause` — it stops the turn itself
(`Sessions::HaltRunningTurn` terminates the process and pauses the session), so the session is
dormant in `waiting` before the tool call returns. The deferred sleep remains the fallback for a
halt that cannot land. See
[Parking a session that is still running](/sessions/triggers/#parking-a-session-that-is-still-running).

Agents reach this through the `wake_me_up_later` MCP tool, which goes through
`Sessions::ScheduleWakeUp` — a time in the past, or inside the 30-second grace window, would
fire-and-drop in the scheduler and leave the session asleep forever, so the service refuses it.
Only `needs_input`, `running` and `waiting` sessions can be scheduled; from `failed` or `archived`
the auto-sleep silently no-ops and the trigger would point at a session nothing can wake.

A wake is only a wake while it can still fire, and `Session#awaiting_scheduled_wake?` is where that
is decided — for the refresh nudge, for the start guards, and for the repair sweeps. A one-time
schedule stops counting once its moment passes unfired; a session-scoped `ao_event` watcher stops
counting once the session it watches is archived or deleted, because the firing path keys on
*transitions* into the watched state and an archived session makes no more of them. A watched session
that merely `failed` still counts, deliberately: it can be restarted, and it can still be archived.
See [A wake is only armed while it can still fire](/sessions/triggers/).

A human's levers on a sleeping session are narrower than they look, and worth stating exactly. **Start now** (the Ranked view's ⋮) resumes a session parked in the **spot queue**, which arms nothing — but it *refuses* one asleep on a wall-clock wake, because `Sessions::StartNow` treats an armed wake as outranking the queue. For that session a human has two routes, both of which consume the pause because both mean *I am taking this session over*: send it a **follow-up** from its session page, or cancel the wake at **/triggers**, where it is listed as `Wake session #<id> at <time>`. The **Restart** button is not one of them — it refuses anything that is not `failed`.

**The spot queue — the same sleep with no wake-up.** `action_session`'s `pause_into_spot_queue`
sleeps the session and hands it to the spot scheduler instead of arming anything:
`Sessions::PauseIntoSpotQueue` writes the same dormancy record a mid-run ceiling pause writes
(`SpotSessionPause`), so the sweep that already resumes spot work picks this session up on the
next pass where a Claude Code account is under both quota targets and a session slot is free —
highest precedence first. Two consequences worth knowing before calling it:

- **It makes the session spot**, if it was not already, because the sweep resumes a non-spot
  sleeper on its very next pass. That is reversible and it is the way back out: *Make this session
  priority* on the banner promotes it, and the next sweep resumes it.
- **It replaces any wake-up the session had already armed** — parking with no wake-up means "not
  then, this instead", and a leftover wake would pull the session straight back out of the queue.

Its queue position is whatever `precedence` the session is already carrying; the
[Ranked view](/sessions/spot-and-priority/) is where that is changed.

A sleep with a wall-clock wake armed outranks every automated reason to start the session *early* —
its precedence, its scheduling class, a recovered quota pool, a freed fleet slot. The places that
would otherwise have started it are listed in
[A pause outranks precedence](/sessions/spot-and-priority/#a-pause-outranks-precedence), along with
the limit of what a pause claims: it is a floor under when the session may run, not a promotion past
the spot queue when the moment arrives. A spot-queue park is the deliberate exception to the whole
thing — it arms nothing, so the spot sweep resuming it is the point.

Zimmer also uses this path on its own behalf: `AuthOutageParkService` parks a session here when the
login pool runs dry, which is what keeps a quota-blocked session out of the heartbeat sweep's reach.
See [Agent harness auth](/auth/harness/#when-the-pool-runs-dry).

A session can be in both states at once — parked on the pool *and* asleep on a wake somebody chose.
The pool recovering answers the first and says nothing about the second, so
`AuthOutageParkService.wake_parked_sessions!` skips it. That skip is load-bearing: its resume goes
through `resume!`, and `cancel_pending_one_time_wake_triggers` would have consumed the pause on the
way past, leaving no record that the session was ever paused.

The same service also guards the *exit* paths, not just the moment the wall is hit. A session whose
turn was never delivered — `active_follow_up_prompt` still set, because `AgentSessionJob` removes it
only on clean completion — stopping while its runtime's pool has no available account is the outage,
not a finished turn. `AuthOutageParkService.park_undelivered_turn!` parks it here rather than letting
the loop's "the process is gone" fallbacks pause it onto somebody's action queue. See
[The park has to survive the paths that do not know about it](/auth/harness/#the-park-has-to-survive-the-paths-that-do-not-know-about-it).

### `block_on_elicitation` / `unblock_from_elicitation` — `running ⇄ needs_input`

This pair exists because an elicitation is *not* a turn ending. An MCP server made a
synchronous request and is blocked waiting for the human; the agent process is still alive.
So `block_on_elicitation` surfaces the session as `needs_input` (to get it on your homepage and
into the notification path) but does not call `cleanup_running_job` — killing
the process would break the round-trip.

A metadata marker (`blocked_on_elicitation`) distinguishes this from a real pause, and guards
the flip back.

:::caution[Stranded elicitation blocks are a real failure mode]
If the reactive unblock is missed — a swallowed `AASM::InvalidTransition` from a state race, or
the MCP server crashing mid-round-trip — the marker is left set with nothing to clear it, and
the session sits in `needs_input` showing a phantom "blocked on elicitation".

`CleanupExpiredElicitationsJob` sweeps for this every 5 minutes and calls
`clear_stale_elicitation_block!`, which strips the marker and leaves the session
in `needs_input`; flipping it to `running` would create a phantom running session with no
monitoring job. A minutes-old stranded block has no live round-trip to resume into.

Leaving it there and saying nothing is its own lie, though — a session parked in `needs_input`
with no banner reads as merely idle. So a stranded `needs_input` session gets a
`lost_elicitation` marker naming what happened, which the session page renders as a banner. See
[Elicitation](/sessions/elicitation/#when-a-round-trip-ends-without-an-answer).
:::

### `fail` — `waiting | running | needs_input → failed`

Cleans up the running job, fires `session_failed` triggers, enqueues a push notification
that bypasses the per-session opt-in, and — like `pause` — enqueues a
[Status summary](/sessions/status-summary/) refresh. The reasoning behind the unconditional push:
by the time `fail!` fires, retries are already exhausted, so this is a final non-self-resolving
event. A silent status flip would be worse than an unwanted push.

A status-summary fork that fails is harvested (recording the failure on the source session's
summary) instead of notifying, exactly as on `pause`.

It also runs `warn_if_pr_goal_captured_no_url`, last in the callback so nothing above it can be
skipped. A session that dies mid-turn never reaches `pause`, so a PR it opened and never named
would be recorded nowhere at all ([#313](https://github.com/tadasant/zimmer/issues/313)).

### `archive` — any state → `archived`

Sets `archived_at`, retires any messages still queued for the session, dismisses notifications,
fires `session_archived` triggers, cleans up triggers watching this session, sets a trash expiry,
and — last, for the same reason as on `fail` — runs `warn_if_pr_goal_captured_no_url`. A session trashed straight from `needs_input`
is one nobody is coming back to, so this is where a PR opened and never recorded gets said out
loud.

Neither this nor `fail` is literally terminal — `resume` runs from `failed` and the three
`unarchive_to_*` events from `archived` — so the warning keeps `pause`'s point-in-time honesty:
it says what was true when it was written ("no PR URL **yet**") and, because the dedup is
once-per-session, it is not retracted if the session is later revived and does open one.

Status-summary forks are carved out inside the hook rather than at the call site. The generator
strips the goal a fork inherits, but only in `prepare_fork` — a fork abandoned before that point
still carries the source's "open a PR", so the goal check alone would not have covered it.

#### The archive line names who did it

Every other transition has one obvious cause. `archive` has six unrelated callers — the web UI,
the REST API, the MCP API, `HealthMonitorService`'s stale-session sweep, status-summary fork
cleanup, and a session archiving itself — and they all used to leave the same five words in the
timeline. So "why did my session get archived?" could not be answered from the session page:
a human clicking **Trash** and another agent archiving the session out from under its own
unfinished work looked identical, and telling them apart meant reading a different session's raw
transcript off disk.

Callers set `session.archive_actor` immediately before `archive!`, and the line names it:

```
[State Machine] Session moved to trash by session #5225 via the MCP API
[State Machine] Session moved to trash by a user in the web UI
[State Machine] Session moved to trash by Zimmer's stale-session sweep (untouched for 7 days)
```

The actor is transient, never persisted, and never inferred. An archive from a console or a test
says `by an unrecorded caller` rather than claiming an actor it does not have.

On the MCP API the actor is **self-declared**, through the same `acting_session_id` argument
`follow_up` uses and for the same reason: the API key is shared by the whole fleet, so nothing
about the request identifies the caller. An archive that declares nothing is logged as
`by an undeclared MCP API caller` — which still answers the question that matters, because a
human archiving a session does it from the web UI. The injected self-session server names itself
separately (`via the self-session MCP server`), since its tool group narrows the *actions* a
session may take, not the `session_id` it may aim them at.

#### Archiving retires the message queue

Archiving ends every path by which a queued message could still be delivered.
`EnqueuedMessageProcessorService` claims `pending` rows only, and for a live session the only
thing that calls it is `AgentSessionJob`'s end-of-turn drain — which an archived session never
reaches, because the monitoring loop sees `archived?` and terminates the process instead of
pausing.

Those rows used to stay `pending` anyway, and that is what made a dropped message silent. Every
reader of the queue — the panel on the session page, `GET /api/v1/sessions/:id/enqueued_messages`,
the MCP `manage_enqueued_messages` list — treats `pending` as *still going to be sent*. So did the
sender: `follow_up` without `force_immediate` auto-queues onto a running session and answers
*"Message queued (session is running). It will be sent when the agent completes its current
task"*, which is a promise rather than a receipt.

The window is not exotic. Goals routinely tell an agent to archive itself once its work is done,
so a session that is `running` when you queue a message may legitimately never become idle again:
it goes `running` → `archived` and the queue never drains. Any two messages arriving inside one
agent turn can hit it. Production session 6073 did — a user's second Slack message queued behind
their first, the session archived at the end of that same turn, and the message sat `pending` in a
queue nobody would ever drain.

So `archive` moves them to `undelivered`, a fourth, terminal status alongside
`pending`/`processing`/`sent`. An archive is the reason a row lands there but not the only one — the
delivery-time staleness check retires a poller notice whose state had already moved on, on a session
that is very much alive (see
[Background jobs](/operate/background-jobs/#a-conflict-notice-is-re-read-when-it-comes-off-the-queue-not-when-it-was-written)).
What the two have in common is that nothing is left worth delivering, which is what the status
records. Three things follow from that:

- The queue can no longer misreport itself. `undelivered` is not `pending`, so the claim query
  cannot take it — including after an `unarchive_to_*`, where a weeks-old message would otherwise
  arrive as if it had just been sent.
- The archive line names what was lost, next to the unresolved-PR clause and for the same reason:

  ```
  [State Machine] Session moved to trash by session #5225 via the MCP API — 1 queued message was
  never delivered and is now marked undelivered: "What do you mean I pulled yellow onion?..."
  ```

- An alert fires, deduped per session, **unless the caller forced past the archive guard**, or the
  archive stranded nothing but [a notice Zimmer had addressed to the session
  itself](#a-strand-nobody-was-waiting-on-records-it-does-not-page). Unlike the unresolved-PR clause
  an unforced strand *is* an anomaly: a message was accepted and never delivered, and the only reason
  to find that out from a user noticing is that nothing else said it.

The row itself is kept, not destroyed — its content is the thing the sender was promised delivery
of — and the session page lists it, marked as never delivered. That listing sits outside the
follow-up form rather than inside the live queue panel, because the form is hidden once a session
is archived, which is the state these rows exist in.

#### Archiving over a queued message is refused, and `force` is the way through

Retiring the messages records the loss; it does not undo it, and recording a discard is not the
same as intending one. So an archive over a non-empty queue is **refused**, on every surface — the
MCP `archive` and `bulk_archive` actions, `POST /api/v1/sessions/:id/archive`, and the web UI's
**Trash** button:

```
Cannot archive session 6073: 1 queued message has not been delivered. Archiving discards it.

  1. What do you mean I pulled yellow onion? I didn't do that, add it back

Do not archive. If you are this session, end your turn instead — the queued message is delivered
as your next turn, and archiving after that succeeds because the queue is empty. If you are
archiving another session, leave it alone and let it consume what you sent it.

Only if you have read the message above and are deliberately discarding it: re-call with
"force": true. That is not the recommended path — the message was accepted from someone who was
told it would be delivered, and forcing throws it away.
```

The refusal leads with what not to do, because for the caller that meets it most — a session
archiving itself at the end of a turn — not archiving is free and correct. An agent self-archives
because it believes its work is finished, and a message that landed mid-turn is exactly the
evidence that the belief is stale. It ends its turn instead, the pause drains the queue, the
message arrives as the next turn, and the archive succeeds after that because the queue is empty.

**`force` is the deliberate override**, off by default, for a caller that has read the message and
is choosing to discard it. It is named last in the error and hedged in its own schema description,
because it exists for the exception rather than the rule. Forcing does not make the discard
invisible: the messages are still retired to `undelivered`, the archive line still names them, and
the discard is [recorded on the log plane](#a-forced-archive-records-it-does-not-page) — so what was
thrown away stays readable afterwards. What it does not do is page.

#### A forced archive records, it does not page

The alert exists for a message that was **discarded without anyone reading it**. `force` is the
caller asserting that it did read it: `Sessions::ArchiveGuard` refuses first, prints every pending
message in the refusal, and the refusal says in as many words that force is only for a caller that
has read them. Paging a human about a discard a caller has already been talked through is paging
them about Zimmer working.

**It is an assertion, not a proof, and the gap is worth stating.** Every surface skips the guard
outright when `force` is set, so a caller that sends it on its *first* call is never refused and
never shown anything — and on a batch the one flag covers every session in it, including ones whose
queues the caller has not seen. Nothing at strand time can tell that caller from one that answered a
refusal. What makes this the right trade anyway is that the alternative was worse in practice, and
that the forced branch is not silent: `force` is off by default, named last in the refusal and hedged
in its own schema description, and every forced discard still leaves the row, the archive line, and
the ledger entry below.

So the branch is on the archive, not on the message:

| The archive | What happens |
| --- | --- |
| **Forced** past `Sessions::ArchiveGuard` | Rows retire, the archive line names them, and a `[StrandedQueue] forced=true` line goes to the log plane at WARN. No page. |
| **Unforced** — every system-initiated archive | Rows retire, the archive line names them, **and it pages** for every message somebody was waiting on. |

Production made the case on 2026-08-29. A spot-queue cleanup Tadas had asked for worked a list of
eleven sessions that had refused archive over undelivered queued messages, read each queue as the
refusal instructs, and forced. Seven pages landed in `#alerts` in three seconds, and because every
alert in that channel spawns a router session, one authorized cleanup burned seven of them. The
messages were stale recovery nudges and a router's own backstop wake — nothing anybody was waiting
on, and nothing the `origin` vocabulary could distinguish from a message somebody was.

Three things this is *not*:

- **Not a hole in the guard.** `Sessions::ArchiveGuard` still refuses, and that refusal is the
  load-bearing part: it is what puts the message in front of a caller that has not seen it. Only the
  page is dropped, and only once the caller has answered the refusal.
- **Not silence.** The row still retires to `undelivered`, the archive line still names it, and
  `SessionStateMachine#record_strand_ledger` writes a line the log plane can be queried on — session,
  actor, count, and each row's id and origin. That is the fleet-wide question the per-session archive
  line cannot answer: *what has been force-discarded, and by whom?* It is logged at **WARN** on
  purpose; `Zimmer backend logging errors (excludes staging)` pages on ERROR and FATAL, and writing
  it at ERROR would move the page rather than remove it.
- **Not "automated messages don't page".** The `origin` column records who wrote each message —
  `caller` for anything queued on someone's behalf, and `automated_pr_merged`,
  `automated_merge_conflict` and `automated_recovery_nudge` for the notices Zimmer addresses to a
  session on its own behalf — and it is emitted on the REST payload and in the MCP list, so a retired
  queue can be explained from outside the database. Exactly [one of those origins is exempt on the
  unforced path](#a-strand-nobody-was-waiting-on-records-it-does-not-page), and `automated_pr_merged`
  is deliberately not it. A system sweep that strands a PR-merged notice still pages, and that
  matters: a fork wrongly credited with its source's PR gets the merge notice queued onto it and is
  then archived by the harvest job, and this alert is how that bug was found.

#### A strand nobody was waiting on records, it does not page

`force` answers *"did the caller read this?"*. It does not answer the other question the alert
needs, which is *"was anybody waiting on it at all?"* — and there is one message in Zimmer's queue
where the answer is no.

On **2026-08-31 at 17:14:34Z**, `#alerts` paged over session
[8810](https://zimmer.tadasant.com/sessions/8810). Everything in the chain was working:

- 8810 was a **machine-created status-summary fork** of #7340 — a throwaway whose only job is to
  write a status blurb for its source. No human ever spoke to it; Zimmer's own record of
  human-authored messages reports **zero** anywhere in its hierarchy.
- It was spot-held, and its re-check stopped firing. `SpotSessionHold`'s sweep re-armed it with
  Zimmer's own **recovery nudge** — *"you may have been interrupted; continue if you were mid-task,
  otherwise keep waiting. No human sent it."* The gate refused that turn too, so the nudge went into
  the durable queue rather than onto a job.
- The fork then failed to boot at all (`Runtime session id … is already in use`) and the
  status-summary cleanup archived it. That cleanup does not consult `Sessions::ArchiveGuard` and
  does not set `force` — correctly, on both counts — so the strand took the loud branch.

The page said *"whoever queued them was told they would be sent"*. Nobody had queued it. Zimmer had
written it, to a session that no longer existed, and then paged a human about throwing it away —
burning a router session for a message with no author and no reader.

So the unforced branch subtracts one thing, on the message rather than on the archive:

| The retired queue | What happens |
| --- | --- |
| Anything somebody was waiting on | Rows retire, the archive line names them, **and it pages** — unchanged |
| **Only** notices Zimmer addressed to this session | Rows retire, the archive line names them, and a `[StrandedQueue] forced=false` line goes to the log plane at WARN. No page. |
| A mix of the two | It pages **about the caller's messages only**, the body names how many nudges it left out, and the suppressed rows still get their `forced=false` ledger line |

`EnqueuedMessage::SELF_ADDRESSED_ORIGINS` is that list and it has **one** entry,
`automated_recovery_nudge`. The bar for a second is that the message must carry nothing still true
once the session is archived. The recovery nudge clears it: its whole content is a question — *were
you interrupted?* — put to a session that is now terminal, so it has no answer, no author waiting on
one, and no reader left to discover the loss from.

`AutomatedPrompts::HEARTBEAT` is the near-miss, and it is left out on purpose. It reaches the same
queue by the same route and would meet the criterion — but every origin added here permanently
narrows the one alert that reports a message being thrown away, so the bar for widening it is a
firing this exemption would have prevented, not an argument that it would fit. The heartbeat goes on
the list when it pages, and not before.

**`automated_pr_merged` deliberately does not clear it, and that contrast is the design.** A merge is
a fact about the world that outlives the archive. An unforced strand of that notice is how the
mis-credited-PR bug behind #555 was found — a status-summary fork that inherited its source's PR, had
the merge notice queued onto it, and was archived by the harvest job. Keyed on "automated" this
exemption would have silenced its own smoke detector; keyed on this one origin it cannot.
`automated_merge_conflict` is out for the same reason: an unresolved conflict is still unresolved
afterwards, and nothing else reports it.

**Where the stamp comes from.** `SpotSessionHold#queue_behind_scheduled_turn` is the only place a
refused turn's prompt becomes a durable queue row, and it is a funnel: a trigger fire, a human's
follow-up and Zimmer's own nudge all reach it as the same opaque string. It stamps
`automated_recovery_nudge` when `AutomatedPrompts.system_recovery?` recognises the prompt — the same
predicate `AgentSessionJob` already keys `resume_for_system_recovery!` off — and `caller` otherwise,
`caller` being the default and the wider bucket. Reading the body is confined to that one write; every
reader afterwards asks the column. Getting it wrong is bounded in both directions and silent in
neither: a nudge mis-stamped `caller` pages exactly as it did before, and a caller's message could
only be mis-stamped by being byte-identical to the nudge template.

Three things this is *not*, mirroring the forced branch:

- **Not a hole in the guard.** `Sessions::ArchiveGuard` is untouched and still refuses an archive over
  a queue holding a recovery nudge. The refusal is what puts an unread message in front of a caller;
  only the page is dropped, and only for a message with no reader.
- **Not silence.** The row still retires to `undelivered`, the archive line still names it, and
  `record_strand_ledger` writes the `forced=false` ledger entry — so *"nothing was lost"* is a claim
  somebody can audit rather than an absence.
- **Not a fix for why the nudge was stranded.** A status-summary fork that cannot boot is a real
  defect and is tracked separately. This changes who finds out about it: the fleet's log plane rather
  than a 5pm page about a message nobody wrote.

##### One bulk archive is one page

The alert's dedup key is per session and deliberately does not collapse across sessions: a sweep that
strands queues on N sessions has discarded N distinct messages, and one alert standing in for all of
them is the summary that hides the other N−1. That is right for the count and wrong for the delivery,
which is what produced seven separate pages — and seven router sessions — from one call.

So the three archive paths that walk a list wrap themselves in `AlertBatcher`: MCP `bulk_archive`,
`POST /api/v1/sessions/bulk_archive`, and `HealthMonitorService`'s stale-session sweep. One
consolidated `… (×N)` message replaces N of them, and the `×N` in the title is always the true count.

**The body is bounded and the tail is cut.** `AlertBatcher` clamps an aggregate to 2,700 characters,
which is Slack's section limit with headroom, so somewhere around half a dozen stranded-queue
occurrences the later ones stop being spelled out. That is a real loss of the per-session detail this
alert exists to give, and it is the reason the batch is a delivery fix rather than a reporting one:
the complete record is the archive line on each session and the `undelivered` rows themselves, both
of which survive whatever the page has room for.

The sweep is the path this matters most on, because it is the only one of the three that can strand
*unforced* across many sessions at once — the two caller-facing bulk paths only strand when the
caller forced, and a forced strand no longer pages at all. On those two the batch is defensive: it
keeps the one-page-per-call property true of whatever per-session alert is added next. The web UI's
bulk action is not wrapped because it never strands: it skips any session with a queue and reports
the count.

Every state that can archive is covered, `needs_input` and `failed` included. Nothing drains their
queues, which makes the discard there certain rather than merely likely — and a refusal without an
override would leave those sessions permanently un-archivable, which is why `force` and the full
coverage are one design rather than two. The same reasoning puts `force` on the narrowed
`self_session` schema: a session archiving itself is the caller that meets the refusal most, and
would otherwise be the one caller with no way past it.

The surfaces differ only in how `force` is expressed, not in whether the discard is refused:

| Surface | Refusal | Override |
| --- | --- | --- |
| MCP `archive` | `ToolError` naming the messages | `"force": true` |
| MCP `bulk_archive` | per-session error, batch continues | `"force": true`, applied to the whole batch |
| `POST /api/v1/sessions/:id/archive` | 422 with the same text | `force: true` |
| `POST /api/v1/sessions/bulk_archive` | per-session entry in `errors`, batch continues | `force: true`, whole batch |
| Web **Trash** | flash naming what would be lost | an **Archive anyway** button that re-posts with `force` |
| Web bulk archive | skipped, and the count is reported | none — archive those individually to confirm |

The web bulk action deliberately has no force: a bulk selection is not a claim to have read each
session's queue, and there is no per-session confirmation to hang an override on. Every Trash
affordance — the session header, the session card, the mobile joystick — posts to the same
controller action, so the two-step covers all of them without touching any of them.

**System-initiated archives do not consult the guard at all.** `HealthMonitorService`'s stale
sweep, status-summary fork cleanup, and `SessionStatusSummaryHarvestJob` archive unconditionally.
That asymmetry is deliberate: a refusal those callers could hit would be a fleet-wide stuck state
with no human in the loop to clear it, and none of them is a caller that could reconsider and let
the message land. Their discards are still recorded, because the retirement runs on the transition
itself rather than at the call site.

#### …and what the archive cost

Archiving is what takes a session out of `GitHubPullRequestPollerJob`'s scope — `with_github_prs`
excludes archived sessions — so it also ends any chance of the merge message the PR goals in
`config/goals.json` promise the session: *"the pull-request poller sends this session a message
when the PR merges, and THAT MESSAGE IS YOUR SIGNAL TO ARCHIVE"*. A session archived before the
poller's next pass never receives it.

When the session still has tracked PRs that Zimmer never saw reach a terminal state (`merged` or
`closed`), the archive line says so and names them:

```
[State Machine] Session moved to trash by session #5225 via the MCP API — 1 tracked pull request
had not reached a terminal state, so no merge notification will be delivered for it:
https://github.com/tadasant/strad/pull/152
```

This rides on the archive line rather than raising a `warning` of its own, deliberately. A merge
gate archives the producing session within seconds of merging — well inside the poller's
30-second cadence — so an unresolved PR at archive time is the common case rather than an anomaly
worth alerting on. What it is worth is one sentence in the place someone asking where their
session went is already looking.

The clone is not deleted immediately. `DeferredCloneCleanupJob` runs after a short undo
window and then either deletes the clone (if it's clean) or preserves unpushed artifacts for
`TRASH_RETENTION_PERIOD`, which is `4.days`. `EmptyTrashJob` deletes them once that expires.

**That job is the only thing that deletes an archived session's clone.** `AgentSessionJob` kills the
agent process when it sees the archive and leaves the clone where it is, because a second deleter
beats the preservation by about ten seconds and there is nothing left to preserve from a tree that
is already being unlinked. [#653](https://github.com/tadasant/zimmer/issues/653) is what happens
when that ordering is not respected, and it costs two things: the session's uncommitted work is
destroyed rather than saved, and the preservation dies on `ENOENT` against a tree the other deleter
has already renamed out from under it (see
[`AtomicCloneRemoval`](/operate/background-jobs/#both-clone-sweeps-reap-deletion-tombstones)), which
pages. Nothing leaks by waiting: `StaleCloneCleanupJob` (archived with no trash deadline, one
hour) and `EmptyTrashJob` (at the deadline) are the backstops if the deferred job never runs.

Preservation is not instant on a large tree — a `git bundle create`, a `git add -A` and a
`git diff --binary` over the whole working tree — so the job re-reads the session's status
immediately before deleting, and stands down if it is no longer archived. An unarchive inside that
window puts a session back to work on this clone, and that is not something the undo window could
undo.

A clone that has vanished by the time preservation starts is not a failed preservation. There is
nothing to preserve and nothing to keep, so `CloneArtifactService` logs it at `.info` — the same
call `check_dirty_state` makes for the same race — and the job clears the trash deadline rather than
holding a session in the trash for four days over a clone that does not exist. "Vanished" is decided
by looking at the disk, not by reading the exception: `Errno::ENOENT` also comes back from a `git`
that is not on `PATH`, and that is a real failure on a clone that is still there. A clone still on
disk that cannot be read stays `.error` and is held for the full window, because it is then the only
copy of the session's work.

If artifact extraction fails outright, the clone is kept — it is then the only copy of that
session's unpushed work — and the job writes the same `4.days` deadline on the session and a
`warning` log the session's owner can see. Unarchive inside that window finds the clone on disk and
restores it as it stands; `EmptyTrashJob` reaps it, its Docker resources and its artifacts at the
deadline. The deadline is anchored to `archived_at` here rather than inherited from whatever is
already on the row: a retry that reaches this branch after an earlier run cleared `trash_after`
would otherwise leave the clone to `StaleCloneCleanupJob`, which reaps it — unpreserved, and without
tearing Docker down — an hour after archive. The cost of the hold is
[a limitation](/limitations/#a-failed-artifact-preservation-holds-a-whole-clone-for-four-days).

Preservation does not take the working tree entirely on faith. A tree that is 50 or more deleted
tracked files and almost nothing else is not uncommitted work — it is a clone that an interrupted
recursive delete mangled — so `CloneArtifactService` drops those deletions from `working_tree.patch`
(keeping the additions and modifications), logs at `.warn`, and records `dropped_deletions` in the
artifact metadata.

The deletions are filtered out of the diff already in memory, not by re-running `git` with
`--diff-filter=d`. The guard fires precisely when a concurrent recursive delete is gutting that
clone, so a second `chdir` into it raced the delete: the directory was gone 11 ms after the warning
and the whole preservation died on `ENOENT`
([#425](https://github.com/tadasant/zimmer/issues/425)). Nothing re-enters a clone the guard has
just proven is being deleted.

`.warn` rather than `.error` because this refusal is self-healing — the corruption is dropped, the
real work still travels in the bundle and the filtered patch, and the deleted files come back from
`HEAD` — and routing it through `StructuredLogger#error` paged on every clone the guard successfully
defused. `DeferredCloneCleanupJob` stamps the drop on the session as
`mangled_clone_dropped_deletions`, and `MangledCloneReportJob` sums a day of them into one line, so
the frequency stays [countable without paging](/operate/background-jobs/).

Unarchive applies the same test before it replays a patch, because patches captured before the guard
existed are still on disk. There it refuses the patch **whole** rather than filtering it: git can
re-take a filtered diff from a live clone, but nothing can cheaply split a patch file, so a legacy
patch's additions are declined along with its deletions. And after restoring artifacts,
`UnarchiveSessionService` checks the clone it produced: if the agent root's `subdirectory` is gone,
or the tree is now overwhelmingly deletions, it puts the clone back to the commit it was checked out
at before the restore (which unwinds a fast-forwarded bundle too, so damage carried by *commits* is
reverted rather than reset onto) and deletes what the restore added. A clone missing its root
subdirectory fails `air prepare` with `ENOENT` and takes the session down with it, so a pristine
clone is the better of the two losses.

The clone unarchive rebuilds is not required to have the path the session row remembers. A session
freezes its agent root's `subdirectory` at creation time, so renaming that root's directory in the
catalog leaves every pre-existing session naming a path `main` no longer has — and the refusal is
permanent, which stranded both halves of the population: archived sessions that could not be
unarchived and live ones that could not resume once the reaper took their clone
([#921](https://github.com/tadasant/zimmer/issues/921)). `UnarchiveSessionService` and
`AgentSessionJob` now hand `GitCloneService` the root's *current* path as well, resolved from the
catalog by `metadata["agent_root_key"]`, and the clone lands on it when the stored path is absent
and the current one is there. The row is corrected in the same breath, before the damage check
above reads `session.subdirectory` — see [the router root's two names](/air/agent-roots/#the-router-roots-two-names).
A root the catalog no longer carries — and a root that moved its tree to the repo root, which is
[a limitation](/limitations/#a-root-that-moves-to-the-repo-root-still-strands-its-existing-sessions) —
still fails the unarchive, and it fails as a warning
rather than an exception-tracker event: nobody on call can act on a missing directory that the
person clicking **Unarchive** is already reading in the flash message.

In both cases the artifacts stay on disk and the session log records where — unarchive clears
`trash_after`, so nothing else will ever reap them, and the path is the only way back to whatever
real work the patch held. See [issue #411](https://github.com/tadasant/zimmer/issues/411) and
[the limitation this does not close](/limitations/#a-clone-delete-that-cannot-rename-falls-back-to-a-non-atomic-in-place-delete).

The session's [scratch directory](/sessions/spawning/) and prompt attachments are on the trash
schedule too, not the undo-window one: nothing can rebuild them from a remote the way a clone is
rebuilt, so they are kept for the whole time archive is undoable and reaped by `EmptyTrashJob`.
That is why a clean-clone session can still hold a `trash_after` — it is the deadline for whatever
is still retained, which is not always the clone. See
[how long scratch lasts](/limitations/#a-sessions-scratch-directory-survives-archive-but-only-for-the-trash-window).

#### Restoring a session that never ran

Everything above assumes the session has a conversation to come back to. Some do not. A session
created by a trigger, held at the starting line by the spot gate for a whole quota window, and then
paused or archived has **no runtime `session_id` and no transcript** — its agent process never
launched. `Session#never_ran?` is that pair, and both halves have to be blank.

Restore and restart used to refuse those sessions outright with *"Session has no session_id"*
([#557](https://github.com/tadasant/zimmer/issues/557)). That precondition is about *resuming a
Claude Code conversation*, and applying it to a session that never had one made **Trash
irreversible** for exactly the class of session where starting over is cheapest and most obviously
correct — its prompt, agent root, skills, plugins and lineage are all intact and none of its work
has been done.

A never-run session now takes a separate, much shorter path on both doors:

| Action | What it does for a session that never ran |
| --- | --- |
| **Restore** (web **Restore**, `POST /api/v1/sessions/:id/unarchive`, MCP `unarchive`) | No clone, no transcript write, no `air prepare`. `UnarchiveSessionService` drops the half-written setup artifacts of the aborted spawn and returns the row to `needs_input`. |
| **Restart** (web **Restart**, `POST /api/v1/sessions/:id/restart`, MCP `restart`) | Takes the existing restart-from-scratch path — clear the setup artifacts and the spot-hold keys, null the `session_id`, and enqueue the full setup pipeline with the session's original prompt and its [first-turn attachments](/sessions/spawning/). |

Restore does not clone, on purpose: the fresh start clones for itself, and a clone built here would
be one the fresh start never uses and a reaper has to sweep. Whatever starts the session next lands
in `AgentSessionJob`, which already reclassifies a follow-up prompt to a session with no
`session_id` as a fresh start.

**The dangerous mistake is the inverse one**, so the branch is deliberately narrow. A session
holding a **transcript** with no `session_id` — what
`ProcessLifecycleManager#release_stale_runtime_session_id!` leaves behind on a runtime that mints
its own conversation id — has hours of work in it. Restarting that fresh would silently discard the
conversation, so it is *not* never-run: it stays on the resume path, and the failure to restore it
stays loud on every surface. Every other restore failure — a clone that would not rebuild, a DB
error, a row that cannot leave its state — is likewise still a failure, not a quiet reroute into a
fresh start.

`Trigger#resuscitatable_session?` is the same predicate, used for a different decision: a recurring
trigger will not *reuse* a never-run session even though the restore would now succeed, because a
follow-up into a session with no `session_id` runs that session's own prompt and silently drops the
one this fire carried. The trigger spawns instead. See [Triggers](/sessions/triggers/).

:::danger[The Undo button doesn't work]
[Issue #12](https://github.com/tadasant/zimmer/issues/12): the archive `turbo_stream` response
never renders the flash toast, so there is no toast and no Undo affordance — even though the
`undo_archive` endpoint still works. The undo window is unusable from the UI.
:::

## Side effects are swallowed by design — but no longer silently

Almost every callback in the state machine is wrapped in a bare `rescue` (`preserve_debug_info` is
the exception — it only logs). That part is deliberate and unchanged: a broken notification service should not be able to wedge a session in `running`,
so a failed side effect never aborts the transition. The consequence is still real — cleanup
can not happen while the state advances anyway.

What changed is that swallowing no longer means silence. All 22 callbacks route their rescue
through one helper:

```ruby
rescue => e
  report_swallowed_side_effect(__method__, e, alert: true)
end
```

`alert: true` logs **and** raises an operational alert via `AlertService` (the same
`#eng-alerts` seam the trigger pollers and `SystemHealthMonitorJob` use). `alert: false` logs
only. The split is by consequence, not by severity of the exception:

| | Callbacks | Why |
| --- | --- | --- |
| **Alerts** | `set_archived_at`, `cleanup_running_job`, `clear_stale_mcp_failure_metadata`, `clear_auth_recovery_budget`, `execute_pending_sleep`, `cancel_pending_one_time_wake_triggers`, `clear_pending_sleep`, `set_blocked_on_elicitation_marker`, `cleanup_watched_session_ao_event_triggers`, `fire_ao_event_triggers`, `clear_trash_expiry` | The failure leaves persistent state inconsistent and nothing reconciles it — a resumed session that re-fails on a stale MCP flag, an armed wake-up that fires into live work, a restored session still queued for deletion. |
| **Logs only** | `reset_elapsed_time_counter`, `log_state_change`, `clear_blocked_on_elicitation_marker`, `clear_paused_by_metadata`, `mark_notifications_stale`, `dismiss_notifications`, `enqueue_failure_push_notification`, `enqueue_debounced_needs_input_push_notification`, `enqueue_session_inference_if_needed`, `set_trash_expiry`, `enqueue_deferred_cleanup` | Cosmetic, best-effort by construction, or already covered by a reconciling sweep — `CleanupExpiredElicitationsJob` for a stranded elicitation marker, `StaleCloneCleanupJob` for a nil `trash_after`, `EmptyTrashJob` for a missed cleanup enqueue. A second alert path to an event that already self-heals is just noise. |

The alert's dedup key is the **callback name, not the session**. A sick database hits the same
callback for every session in flight; collapsing them into one page per
`AlertService::DEDUP_WINDOW` is the difference between a signal and a flood.

Note this covers reporting only, with one exception: **a failure that aborted the transaction is
not swallowed.** Swallowing exists so a transition can finish with one side effect missing, and once
Postgres has aborted the transaction the transition cannot finish at all — every later statement in
it raises `PG::InFailedSqlTransaction` and lands here in turn, and the transition's own
`requires_new:` transaction cannot commit either (an outermost one turns its `COMMIT` into a
rollback; a savepoint fails on `RELEASE`). So the state change is already lost. Swallowing there
only buries the cause under its consequences and pages once per callback.
`DatabaseTransactionState.aborted_by?` asks libpq directly — `PQTRANS_INERROR` on the pool the error
came from — and `report_swallowed_side_effect` logs the abort and re-raises, so the first failure
ends the transition and the caller sees the statement that actually failed.

That is [#924](https://github.com/tadasant/zimmer/issues/924). On 2026-09-04 a worker connection
held a cached plan across an `app_settings` migration; the `SELECT` behind
`record_experimental_setting_flags` failed, a silent rescue in `AppSetting.current` returned a
default, and the three callbacks after it each reported an `InFailedSqlTransaction` of their own.
`#alerts` got four ERROR records naming only consequences and no record at all of the statement
that failed.

**The blast radius is wider than that one path, deliberately.** Any callback whose failure aborts
the transaction now ends the transition — a check constraint on `logs.create!` in `log_state_change`
fails `pause!` outright, where before it cost one timeline line. That is the honest outcome rather
than a new one: the transition was never going to persist. It is narrow in the way that matters,
though — a failure a `requires_new:` savepoint absorbs (`Session#assign_slug`,
`GateDecisions::Record`) leaves the connection healthy, `aborted_by?` says so, and the swallow
contract applies unchanged. Everything else about that contract is untouched: an ordinary failed
side effect is still swallowed, and the transition still completes.

:::note
A failed one-time scheduled wake is still destroyed silently — that is a separate path from
these callbacks and is tracked in [Limitations](/limitations/#a-failed-one-time-wake-is-gone-forever).
:::

## Who else moves sessions around

The state machine is not the only actor:

- **`HeartbeatSweepJob`** (every 30s) re-nudges `needs_input` sessions with `heartbeat_enabled`
  by injecting a heartbeat prompt and resuming them. It skips sessions blocked on an
  elicitation or with pending enqueued messages — resuming those would spawn a second process.
- **`CleanupOrphanedSessionsJob`** (every 5 min) catches sessions marked `running` whose process
  is gone.
- **`StalledStartSweepJob`** (every 5 min) catches the opposite end: a session that never
  started. A first turn rides on exactly one `AgentSessionJob`, and — unlike a spot hold, a
  ceiling pause, an auth park or a recovery pause — a session that has never run carries no
  marker saying so, so a lost start job leaves a plain `waiting` row that looks exactly like a
  session created a second ago. `StalledSessionStart` re-enqueues it, and fails it after three
  attempts rather than re-queuing forever. See
  [Background jobs](/operate/background-jobs/#the-cron-schedule).
- **`StrandedSleepSweepJob`** (every 5 min) covers the other half of the same hole: a session
  that *did* run, went to sleep on a wake, and lost the wake. `waiting` is one word for two
  states — a session resting on a wake it will get, and a session resting on a wake it will not —
  and nothing distinguished them, because a legitimate sleep carries no marker either. The
  predicate is **no fireable wake**, not *no wake*: an `ao_event` watcher whose watched session
  is already archived is an `enabled` row that will never fire, so a sweep keyed on the absence
  of trigger rows would walk straight past it. `StrandedSleepRescue` resumes the session with a
  `SYSTEM_RECOVERY` nudge through the same `claim_system_recovery_turn!` door orphan cleanup
  uses, and stops after three rescues rather than resuming forever. Production session 6412 sat
  in `waiting` for 38.7 hours before this existed
  ([#855](https://github.com/tadasant/zimmer/issues/855)). See
  [Background jobs](/operate/background-jobs/#the-cron-schedule).
- **`ZombieReaperJob`** (every 5 min) reaps dead child processes that nothing is waiting on. It
  deliberately leaves alone any pid a live waiter has claimed — see
  [Background jobs](/operate/background-jobs/#the-zombie-reaper-only-takes-what-nobody-is-waiting-for).
  Reaping a pid the monitoring loop was waiting on costs the loop the exit status it would have
  routed through `handle_exit`; the loop's signal-0 fallback answers that case with
  `handle_unreaped_exit`, which runs every recovery that reads evidence rather than a status —
  see [Spawning](/sessions/spawning/#when-the-process-exits).
- **`SessionRecoveryService`** handles hung and interrupted sessions on a best-effort basis;
  `SigtermRetryService` covers gracefully SIGTERM'd sessions (deploys) with a bounded retry
  ladder (`RetryBudget::SIGTERM`, 3 attempts); an abnormal signal death (SIGKILL from an OOM
  kill, SIGSEGV, …) is instead resumed by `ProcessLifecycleManager#handle_signal_death`
  (`RetryBudget::SIGNAL_DEATH`, 3 attempts) — see
  [Retry budgets](/sessions/spawning/#retry-budgets).

## How a process actually gets terminated

Pausing, archiving, following up and recovery all end in the same place:
`ProcessTerminationService#terminate`, given the session's `process_pid`. It walks a ladder and
stops at the first rung that works.

1. **SIGTERM to the process group** (`-pid`). Agent children are spawned with `pgroup: true`, so
   this reaches the leader and every grandchild it started — MCP servers, `node`, `gh`.
2. **SIGTERM to the leader alone**, if the group could not be signalled (no such group, or not
   ours).
3. **SIGKILL**, group first and then the leader, if it is still alive after its SIGTERM grace.
4. **A group SIGKILL sweep**, once the leader is confirmed dead.

Two details are load-bearing.

**Liveness is answered by reaping, not by signal 0.** `Process.kill(0, pid)` succeeds for a child
of ours that has already exited — an unreaped child holds its pid as a zombie until someone waits
on it. So the service asks `waitpid(pid, WNOHANG)` instead: a status back means the child had
exited and is now collected, `nil` means it is genuinely still running, and `ECHILD` means it is
not our child, where signal 0 is the right answer and is used as the fallback. Once a pid is
reaped it is never probed again — it belongs to the OS and can be recycled.

Before this, every liveness check answered "still running" for a child that died on the first
SIGTERM: termination burned ~15–25s of `sleep` in a GoodJob thread, sent two redundant SIGTERMs
and two SIGKILLs, and then reported `:error` for a kill that had worked.

**The group SIGKILL sweep is deliberate.** Grandchildren are reparented to init when the leader
dies; nothing else cleans them up. They received the group SIGTERM in step 1, so the sweep gives
the group one more second to drain, then SIGKILLs it — and skips silently when the group is
already empty, which is the common case. A group we may not signal, or a sweep that fails, never
downgrades the result: the leader is dead either way, and that is what the caller acted on.

## What the dashboard shows you

The dashboard opens on the sessions that are waiting for you and nothing else: **`needs_input`
only**, out of the box. That is the point of the queue. Everything else — the run you started
five minutes ago, the failures you already read, the trash — is one tick away in the **Filters**
section in the sidebar.

Filters is a single form covering four things: the search box, the **status** multi-select, the
**scheduling class** narrowing, and an **Advanced** disclosure holding the agent-root, genesis and
transcript-contents controls. One form, one Apply, and the whole filter state travels together.

**Status is a multi-select over the five states, and selecting none means every status.** There is
no separate trash toggle: `archived` is simply one of the five, so trash visibility is answered by
the same control as everything else rather than by a second toggle arguing with it.

| You want | Tick |
| --- | --- |
| The queue (the default) | `Needs input` |
| Live work | `Waiting` + `Running` |
| The trash | `Archived` |
| Everything | nothing |

Two behaviours are worth knowing:

- **A selection persists.** Applying the form writes the statuses and the scheduling class to a
  `sessions_filters` cookie, so the choice survives a reload and a bare visit to `/` — the same
  shape of preference as the view-mode cookie. **Reset filters** deletes it and returns you to
  `needs_input` only.
- **The ticked boxes describe the result set in every view, search included.** Searching does not
  quietly widen the status filter. That means a search from the default view returns `needs_input`
  matches only — to search the trash, tick `Archived`; to search everything, tick nothing. The
  status summary sits directly above the search box so the narrowing is visible rather than
  surprising.

The **scheduling class** is a filter rather than a search: it narrows whichever view you are in
and leaves the category grid in place. A free-text query, an agent root, or a genesis *is* a
search, and replaces the grid with a flat result list.

The equivalent for an agent is `quick_search_sessions`, whose `status` argument takes one status
or an array of them.

## Manual refresh

The dashboard's refresh controls are the human counterpart to those background actors. There
are four of them, and they all end up in `SessionsController`:

| Control | Action | Scope |
| --- | --- | --- |
| The per-card icon next to a session's status badge | `#refresh` | that one session |
| "Refresh all" in the header | `#refresh_all` | every non-archived session outside a frozen category |
| The icon in a category section header | `#refresh_category` | that category's non-archived sessions |
| The icon in the **Starred** group header | `#refresh_starred` | every non-archived favorited session |

`#refresh_starred` deliberately does *not* skip frozen categories the way `#refresh_all` does.
The Starred group renders every favorited session regardless of its category, so the button acts
on exactly the cards sitting under it — starring is a per-session opt-in that outranks the
category's parked flag.

The per-card icon is hidden for a `running` session. A running session is already streaming into
its card; there is nothing a refresh would tell you that the card does not.

### How the dashboard answers

Every mutating dashboard control — the four refresh buttons plus Trash, Undo, Restore, bulk
trash, Pause and the category moves — responds to a Turbo request with a Turbo Stream, not a
redirect. The stream replaces one element: `#flash`, the layout's single toast container
(`app/views/shared/_flash.html.erb`). The cards themselves are not in the response, because they
re-render on their own over the `sessions_index_individual` and `session_<id>_status` broadcast
channels. The redirect existed only to carry the message.

Two actions stream a card as well, because a broadcast cannot reach one:

- **Trash** removes the card it just archived, and streams the "Session moved to trash." toast
  carrying the **Undo** button. The toast needs the `#flash` target to land in — before that id
  existed, the card vanished with no way to undo it.
- **Undo** prepends the card back into the grid it belongs to (`#sessions_grid` for
  Uncategorized, `#category_grid_<id>` for a category). Its own restore broadcast is a `replace`,
  and there is nothing left in the DOM to replace.

`#archive`, `#unarchive` and `#pause` stream one more thing: the session page's own status badge
and header actions. `Session#broadcast_status_change` already pushes both over the cable, but a
broadcast is fire-and-forget and this whole change exists because a cable can be silently dead.
The direct reply to the user's click cannot be lost, so a status-changing action carries its
chrome rather than trusting the socket. Both targets are absent when the click came from a
dashboard card, where those streams are a no-op.

That chrome is what makes trashing from the session page itself work: it leaves you on the page,
with the toast and its **Undo**, and the button you just clicked turns into **Restore**. Only the
dashboard card's Trash takes something out from under you, and all it takes is the card.

A stream only happens if the client asks for one, and that is a client-side property, not a
controller one. The card's Trash link carries `data-turbo-method`, so Turbo builds the request
and sends `Accept: text/vnd.turbo-stream.html`. The detail header's Trash button — the one the
session drawer puts in front of you — builds its own form in `archive_countdown_controller`
instead, and has to submit it with `requestSubmit()`. A native `form.submit()` fires no `submit`
event, so Turbo never sees the submission: the browser POSTs for real, `#archive` answers on its
`format.html` branch, and the redirect reloads the dashboard from the top, discarding the scroll
offset the drawer was opened over.

Every one of these actions keeps its `format.html` branch, which still redirects with a real
flash. That is what a non-Turbo client — and most of the controller test suite — gets.

The session detail page is on the same footing: it carries a `cable-reconnect` Stimulus
controller that watches each `<turbo-cable-stream-source>` for the `connected` attribute
turbo-rails sets and clears, and re-subscribes any source still dark after a grace window
(backing off up to 30s). It replaced a `<meta http-equiv="refresh">` that fired on a
five-second timing window whether or not the cable had actually dropped — and, being a
top-level navigation, dismissed the session drawer along with the user's place in it.
`Session#recently_recovered?` now only decides whether to *show* the recovery banner.

It does not replace `stream-visibility-recovery` — the two answer different failures. A socket
that dies while the page stays visible has missed nothing, so cable-reconnect re-subscribes that
source in place. A page that was hidden (backgrounded PWA, bfcache restore) and came back with a
dead socket has also *missed content*, and re-subscribing would not bring it back, so
`stream-visibility-recovery` handles that case in two steps: reopen the ActionCable consumer,
which re-subscribes every subscription on the connection and restores live updates without
rendering anything, then **backfill** the gap.

### The drawer loads its own URL

The dashboard's right-hand session drawer is a real Turbo Frame navigation, not an innerHTML
injection — that is what makes the detail view's `turbo_stream_from` subscriptions and Stimulus
controllers connect, so a transcript streams live inside the drawer and the follow-up and archive
controls work.

What it navigates to is a **separate path**: `/sessions/:id/drawer` renders the same detail body
wrapped in `<turbo-frame id="session_detail">` with no application layout, and `/sessions/:id`
renders the full page with no frame. Which body you get is decided by the URL and nothing else.

That separation is load-bearing, and it replaced an arrangement where one URL served both bodies
and a `Turbo-Frame` request header chose between them. Every cache between the view and the reader
keys on the URL, so a shared URL meant any of them could hand the drawer's frame request the
frameless body — and Turbo would render its `Content missing` placeholder in place of the session.
The one that actually did it is not an HTTP cache and no response header can reach it: Turbo 8's
link prefetching keeps a hover-prefetched request keyed **only** by URL, and splices it into any
later GET fetch for that URL — a frame's own `src` load included — discarding the `Turbo-Frame`
header that decided the body. It happens in browser memory and never touches the network, which is
why `Vary: Turbo-Frame` could not help and why disabling prefetch on one link never did either: the
key is the URL, so *any* other link to the same session seeded the entry just as well.

Four rules follow, and all of them are pinned by tests:

- **Nothing links to a drawer path.** Turbo's prefetch cache is only ever seeded by hovering an
  `<a>`, so as long as no anchor points at `/sessions/:id/drawer`, no entry for it can exist. A
  drawer trigger's `href` stays the full session page — so middle-click, ⌘-click and the no-JS
  path all do the obvious thing — and it hands the drawer the frame's URL in
  `data-session-drawer-url` instead. `SessionsHelper#session_drawer_link_data` builds that pair.
- **Nothing inside the drawer navigates the frame.** A plain same-origin link in there navigates
  *the frame*, and every page it could land on — `/triggers`, `/costs`, the dashboard, the session's
  own full page — has no `session_detail` frame, so the drawer shows `Content missing` again by a
  different door. Every link the drawer renders carries `data-turbo-frame="_top"`, including the
  ones that answer with a Turbo Stream and so never navigate anything: a rule with case-by-case
  exceptions is one nobody can check. The session-hierarchy links to other sessions carry the drawer
  url as well, so clicking one swaps the drawer in place; on the full page, where no drawer exists,
  they fall back to an ordinary navigation.
- **The log-level filter re-fetches the frame's own address.** Changing the log level is a server
  round trip — the server filters timeline items before paginating them — so the detail body has to
  be re-rendered with a `filter` param. `log_level_filter_controller` picks *which* address to
  re-fetch off the enclosing frame's `src`: a frame carrying one was lazy-loaded from that address
  into some other document, which is the drawer, so the frame's `src` is the session's address; no
  frame, or a frame without a `src`, was rendered as part of this document, so the document's own
  address is the body's — that covers the full session page and `/sessions/:id/drawer` opened
  directly. Using `window.location` unconditionally is what broke the drawer, where it is the
  **dashboard**: opening the drawer with a non-default level saved in `localStorage` navigated the
  dashboard to `/?filter=<level>`, a param that means nothing there, and dismissed the drawer along
  with the reader's place ([#666](https://github.com/tadasant/zimmer/issues/666)). What the frame
  navigates to is `/sessions/:id/drawer?filter=<level>` — a drawer url, so the rule above still
  holds, and no anchor points at it so the prefetch cache still cannot be seeded for it. A frame
  navigation has no browser loading UI behind it, so the drawer dims the frame for the round trip
  off Turbo's own `busy` attribute rather than leaving the previous filter's content looking live.
- **A redirect the frame follows lands on the drawer url.** A frame follows a 302 with its own
  `Turbo-Frame` header still attached, so `#follow_up`'s "queued instead" branch and `#refresh` —
  the two that redirect rather than answering with a Turbo Stream — pick their target through
  `SessionsController#session_redirect_target`. That reads the frame header to choose a *destination*,
  which is not the content negotiation that caused the bug: each URL still has exactly one body.

`test/contracts/session_drawer_frame_url_test.rb` pins the arrangement, and the controller tests
assert the invariants directly: each URL returns the same body whatever the `Turbo-Frame` header
says, no link on the dashboard points at a drawer path, and — asserted over the whole rendered
drawer body, so a link added later is caught without anyone remembering the rule — every same-origin
link inside the drawer escapes to `_top`. `test/system/session_drawer_log_filter_test.rb` drives the
log-level filter in both contexts and asserts the dashboard's URL is untouched when the drawer
re-filters. Opening `/sessions/:id/drawer` by hand is not a supported way to read a session — it
answers with a bare frame and no chrome — it is the drawer's own address.

### The reopen backfill

iOS suspends a backgrounded standalone PWA. The process stops and the WebSocket dies with it, so
on a real reopen the socket is *always* dead and the dead-socket branch runs every single time.
That branch used to be a full replacing `Turbo.visit`, which is exactly why the app appeared to
reload whenever the user switched back to it. Checking `consumer.connection.isOpen()` first did
not fix that — it only made the case that never happens (socket survived the hide) free.

The branch now fetches the page the server would render and reconciles it into the live document,
region by region, without navigating. `app/javascript/lib/live_region_backfill.js` does the
reconcile; the regions declare themselves in the markup with `data-live-region`, and the values
mirror what `BroadcastService` does to them:

| Value | Broadcasts do | Backfill does | Examples |
| --- | --- | --- | --- |
| `append` | append children | append children the page lacks, by id | the timeline |
| `replace` | replace the element | replace it when the server's copy differs | status badge, header actions, metadata, provenance, enqueued messages, the composer |
| `sync` | add, replace and remove children | reconcile children by id, in the server's order | the dashboard's session grids, elicitation banners |

The strategy has to match what the broadcasts actually do, and getting it wrong is silent in one
direction: elicitation banners are appended when raised *and removed when answered*, so marking
them `append` would leave a dead approval prompt on screen after a reopen.

Three rules keep the backfill from taking something away from the reader:

- **A region in use is never swapped.** Anything containing the focused element, or a field holding
  a value the server did not render — a half-typed follow-up, a staged attachment — is skipped.
- **An `append` region never removes.** Older pages pulled in by infinite scroll are not in the
  server's tail render, and are left where they are. The one exception is a child marked
  `data-live-transient` (the empty-state placeholder), which a broadcast would have removed too.
- **A `sync` region showing a different page is skipped.** The dashboard's category sections page
  inside their own `<turbo-frame>` without changing `window.location`, so re-fetching that URL
  returns page 1 — and syncing it would throw away the page the reader had paged to. Each grid
  records its page in `data-live-page`, and a mismatch means hands off.

Appending by id needs rows that *have* ids, and timeline rows are not records — a row is a `Log`,
an MCP log, or one of the several OpenTranscripts events a transcript line fans out into.
`SessionsHelper#timeline_item_dom_id` derives one from what the row is, and the derivation is
constrained by having to agree across both render paths. In particular it excludes
`transcript_index`: `BroadcastService` normalizes without one, so including it would give every
live-streamed row a different id from its own re-render — and the backfill would then append a
second copy of everything that had arrived over the socket. `test/helpers/sessions_helper_test.rb`
asserts the two paths agree, and `test/system/pwa_reopen_recovery_test.rb` asserts a live-arrived
row is not duplicated by a reopen.

Three exits are worth knowing about. A socket that reports itself open is left alone entirely and
the reopen costs nothing. A socket still mid-handshake is left to finish rather than torn down and
restarted. And a backfill that cannot run to completion — the fetch failed or timed out (10s), the
URL now redirects because you were signed out, or the reconcile itself threw part-way — falls back
to a replacing visit, because a page left half-recovered and quiet is worse than one that lost its
place.

`isOpen()` is a `readyState` read, which is its limit — see
[Limitations](/limitations/#a-zombie-websocket-is-not-detected-on-pwa-reopen).

A Turbo 8 morph was tried for this and rejected. Morphing reconciles the whole live DOM against the
server's HTML, and Stimulus controllers here keep state in value attributes the server does not
render — `log_level_filter_controller` writes its own `level-value` in `connect()`. Idiomorph
removes any attribute missing from the server's markup, so that state reverts to its default and
the controller then acts on it: in testing, a morph reverted the log filter to `minimal` and hid
every item in the timeline. A morph also closes a `<details>` the reader opened, for the same
reason. The region-scoped backfill avoids both by touching only what broadcasts touch.

What a refresh *does* depends on the session's state:

- `failed` → restart it (`#resume_failed_session`, or `restart_with_continue_prompt` in bulk).
- `needs_input` → in bulk, continue it, unless the user paused it by hand (`paused_by: "user"`).
- `waiting` → send the automated continue nudge (`AutomatedPrompts::SYSTEM_RECOVERY`), the same
  prompt every recovery path uses. See below.
- `running`, and any `waiting` session excluded below → re-read the transcript from disk.

### Refreshing a `waiting` session nudges it

A `waiting` session has no live process, so re-reading its transcript tells the user nothing.
What they want from "refresh" is for the session to get moving again, so `Session#continue_nudge_on_refresh?`
routes it through `restart_with_continue_prompt` instead.

Two kinds of `waiting` session are excluded, because for them a nudge would be wrong rather than
merely useless:

- **Never started** (`session_id` blank). There is no conversation to continue — the session is
  still queued and the spawn pipeline owns it.
- **Deliberately asleep** (`Session#awaiting_scheduled_wake?`). A one-time wake-up targeting this
  session that is still *ahead* of it — from `wake_me_up_later` or
  `wake_me_up_when_session_changes_state` — means the agent chose to sleep until a specific
  moment. Nudging it would fire the work early, and worse: `restart_with_continue_prompt` resumes
  the session, and `resume`'s `cancel_pending_one_time_wake_triggers` callback *consumes* the
  pending condition, so a premature refresh would delete the wake-up it was waiting on. If the
  trigger table can't be read, the session is treated as asleep, so a database error never wakes
  a sleeper.

Both excluded kinds fall through to the plain transcript refresh. The rule is identical for the
single-session icon and for all three bulk controls, so "refresh all starred" over a mix of
statuses does the right per-session thing.

:::note[An overdue wake-up is a stall, not sleep]
"Still ahead of it" is doing real work in that second bullet, and it is deliberately *narrower*
than what `cancel_pending_one_time_wake_triggers` consumes on resume.

A one-time schedule whose moment has already passed without firing — a stopped scheduler, a
GoodJob backlog, a crashed trigger job — describes a session that is **stuck**, which is exactly
the session refresh exists to rescue. Treating it as "asleep" would make refresh a no-op on the
one case that most needs it. So sleeping means *the scheduler has yet to reach it*, read through
the same `TriggerCondition#schedule_due?` the firing path uses. A session-scoped `ao_event` wake
has no time component — it fires whenever the watched session transitions — so an unfired one is
always still ahead.

The cancel-on-resume path keeps the broader reading, and should: once a session is resumed by
hand, an overdue wake-up firing later would land on an already-active session.
:::

Bulk refresh asks this about a whole set of candidates at once via
`Session.ids_awaiting_scheduled_wake`, which answers in one query rather than one per waiting
session.
