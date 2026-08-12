---
title: Spot and priority sessions
description: Every session is spot or priority — whether it always starts, or waits for Claude Code quota headroom first. The class is chosen per session, per trigger, or derived from where the work came from.
sidebar:
  order: 9
---

Quota is finite and the work is not. On a busy afternoon a merge gate, three scheduled sweeps and a
label poller can be spending the same 5-hour window that the thing you actually asked for needs.

Zimmer's answer is to classify sessions by where they came from, and to let the automated ones wait.

| Class | Behavior |
| --- | --- |
| **priority** | Starts whenever it is ready. Never consulted about quota. |
| **spot** | Starts only while both Claude Code quota windows are forecast to stay under their ceilings. Otherwise it waits and starts later. |

A held spot session is **deferred, never cancelled**. Nothing is lost.

## Where the class comes from

Three things can decide a session's class. The first one that speaks wins:

| Order | Source | Set it | Scope |
| --- | --- | --- | --- |
| 1 | **The session itself** — `sessions.scheduling_class` | `scheduling_class` on `start_session` / `POST /api/v1/sessions`; afterwards `action_session` (`change_scheduling_class`), `PATCH /api/v1/sessions/:id`, or the button on the hold banner | That one session, and anything it spawns |
| 2 | **The trigger that fired it** — `triggers.scheduling_class` | The trigger's edit form, or `action_trigger` | Every session that trigger spawns from now on |
| 3 | **Its genesis** — the default for where the work came from | `/settings` (only for the origins no trigger produces) | Every deriving session of that genesis, past and future |

Most sessions never touch 1 or 2: both columns are NULL, and the class is derived. That is what keeps
the defaults live rather than frozen into history.

```mermaid
graph TD
  A["Session needs a class"] --> B{"scheduling_class<br/>on the session?"}
  B -- yes --> C["Use it"]
  B -- no --> D{"Was it spawned by a<br/>trigger with one?"}
  D -- yes --> E["Stamped on the session<br/>when the trigger fired"]
  D -- no --> F["Derive from genesis,<br/>on every read"]
```

## Genesis

A session's **genesis** is where its line of work ultimately came from — not who physically inserted
the row. It is a column on `sessions`, assigned once at creation.

| Genesis | Means | Default class | Class set on |
| --- | --- | --- | --- |
| `web_ui` | A human typed it into the Zimmer web app: the new-session form, the dashboard quick prompt, the chat bubble, or the **Invoke** button on a trigger. | priority | `/settings` |
| `slack` | A Slack trigger fired on a DM or a channel message. | priority | the trigger |
| `github_issue` | A `github_issue` trigger fired — the feed the issue-work gate reads. | spot | the trigger |
| `github_label` | A `github_label` trigger fired — the `ready to merge` feed the PR merge gate reads. | spot | the trigger |
| `schedule` | A cron-scheduled trigger fired. | spot | the trigger |
| `ao_event` | A session-state trigger fired because another session changed state. | spot | the trigger |
| `api` | Created over `POST /api/v1/sessions` or MCP `start_session` **with no parent session**. | spot | `/settings` |
| `unknown` | Origin could not be established — chiefly rows created before genesis was recorded. | priority | `/settings` |

Five of the eight kinds restate a trigger condition type, so their class lives on the **trigger**, not
in a global per-kind setting: one noisy Slack trigger can be spot without demoting the eleven other
Slack triggers that have a human waiting on the answer. The three that no trigger produces keep a
per-kind setting on `/settings`.

Two of the defaults are policy calls worth stating plainly:

- **`unknown` is priority on purpose.** A session Zimmer cannot explain is never one it throttles.
  The failure mode of the classifier is "runs anyway", not "silently held".
- **`schedule` and `ao_event` are spot** because recurring automation runs again by definition, so a
  deferred run costs little. Set the trigger to priority if that is wrong for a particular one.

### Genesis is inherited

A session created *with a parent* takes its parent's genesis verbatim. That single rule is what makes
the classification safe to act on:

```mermaid
graph TD
  A["#101 web_ui<br/>Tadas types a request"] --> B["#102 inherits web_ui<br/>router spawns the work"]
  B --> C["#103 inherits web_ui<br/>agent spawns a sub-task"]
  D["#201 github_issue<br/>issue trigger fires"] --> E["#202 inherits github_issue<br/>gate spawns a router session"]
  E --> F["#203 inherits github_issue<br/>router spawns the work"]
```

Holding `#103` would strand a request Tadas is waiting on. Holding `#203` is exactly the intent. Both
fall out of the same rule, with no special-casing of agent roots — which matters, because the gate
roots (`issue-work-gate`, `pr-merge-gate`) live in a deployment's own catalog, not in Zimmer.

An **explicitly declared** genesis outranks inheritance. The chat bubble is the case that needs it: it
carries a parent so the conversation threads, but a human typed the message, so it declares `web_ui`
rather than inheriting spot from whatever session was on screen.

Forks inherit through `metadata["forked_from_session_id"]`, the only lineage edge a fork has.

An explicit `scheduling_class` is inherited the same way. A router told to run one long batch as spot
spawns children that are also spot, without every spawn call having to repeat it — and without moving
any other session that shares the genesis.

### Where you see it

Genesis appears on every node of the **Session hierarchy** panel, as a `genesis · class` pill beside
the agent-root pill — so "this whole branch is spot" is readable at a glance, and an outlier stands
out. It is also on every dashboard card, in `get_session`, and in `quick_search_sessions`.

## Stored only when someone chose it

`sessions.scheduling_class` is NULL on most sessions. When it is, `Session#priority_class` resolves
from the stored genesis on every read, through the per-genesis override map in
`AppSetting#genesis_class_overrides`.

That sparseness is the design. Promoting `web_ui` to spot reclassifies **every deriving session of
that genesis, including ones that already exist** — which is what changing a default has to mean. A
class denormalized onto every row at creation would only ever apply to sessions created after the
click, and would freeze today's defaults into all of history.

The flip side, stated plainly: **changing a trigger's class does not move sessions it already
spawned.** The trigger's selector is read once, when it fires, and stamped on the session. Sessions
already created — including ones still `waiting` behind the gate — keep the class they started with.
To move one of those, move that session: the **Make this session priority** button on its hold banner,
`action_session` with `change_scheduling_class`, or `PATCH /api/v1/sessions/:id`.

## The usage rate

**Claude Code usage rate per active session** is the fraction of a quota window one running session
consumes per hour:

```
rate = Σ(utilization consumed) / Σ(active sessions × hours elapsed)
```

Both sums run over consecutive pairs of `ClaudeAccountQuotaSnapshot` rows inside a rolling 6-hour
lookback. The numerator is the *rise* in `utilization_5h` (or `utilization_7d`) between two readings.
The denominator is session-hours: the mean of the two readings' `active_session_count` times the
hours between them. A rate of `0.02` means one session running for one hour consumes 2% of the
5-hour window.

`active_session_count` is recorded on the snapshot row at capture time, because session status is
mutable and keeps no history — a reading taken today cannot be attributed to a session count
tomorrow.

A pair is **skipped** rather than guessed at when:

- the window reset between the readings, or utilization fell (Anthropic's counters are sliding
  windows; they go down on their own, and differencing across that boundary measures nothing);
- either reading predates `active_session_count`, so the pair has no denominator;
- nothing was running, so there is no one to attribute the usage to.

`ClaudeUsageSamplerJob` runs every 15 minutes and takes a reading of the account that is actually
serving. Before it existed, the only *scheduled* readings were of `quota_exceeded` accounts — whose
utilization is pinned at the cap and therefore useless as a rate signal.

## The gate

With gating on, a spot session starts only while **both** forecasts stay under their ceilings:

```
forecast = utilization now + (rate × sessions × hours left in window)
```

`sessions` is the running fleet **plus the session being decided about**. A gate answers "if I start
this, where does the window land", and the fleet does not include it yet — with an idle fleet, a
forecast built on the running count alone is flat and could never breach. The reading on `/settings`
deliberately uses the fleet as it stands (and says so), and shows the start decision beside it.

`hours left` is the time to that window's own reset, capped at 24 hours — a weekly window can have six
days left, and multiplying a per-hour rate out that far produces a number with no predictive content.

Thresholds are set on `/settings` (5-hour and weekly, both default 80%).

### Fail-open

Every uncertain condition **allows** the session, and the reason is named so the UI can say which:

| Reason | Meaning |
| --- | --- |
| `gating_disabled` | The toggle is off. |
| `insufficient_data` | Fewer than 3 usable sample pairs — the rate is not measurable yet. |
| `no_snapshot` | No Claude Code quota reading to forecast from. |
| `unavailable` | The gate could not be evaluated at all. |
| `within_forecast` | Both windows have headroom. |
| `forecast_breached` | **Held.** One or both windows are forecast past their ceiling. |

A monitoring gap must not become an outage of all automated work.

### What "hold" does

A held session stays in `waiting` — the status Zimmer already uses for "created, not started" — and
`AgentSessionJob` re-enqueues itself with a 10-minute delay. GoodJob persists the delayed job in
Postgres, so the retry survives a worker restart or a deploy. When headroom returns, or simply when
the 5-hour window resets, the same job starts the session normally.

Refusing instead would mean the gate silently deletes work: a `github_issue` trigger that fires once
during a busy afternoon would never run at all.

**Only a session's first start is gated.** Follow-ups, monitoring resumes and clone-only setups pass
straight through. Interrupting a conversation already underway strands it half-done and wastes the
tokens already spent on it — the decision point that means something is "should this work begin".

The session detail page shows a **Held for quota headroom** banner naming the reason, the next check
time, and how to start it now.

## MCP parity

| Capability | Web UI | MCP |
| --- | --- | --- |
| Read a session's genesis and class | Hierarchy panel, dashboard card | `get_session` |
| Filter by class or genesis | Dashboard segmented control | `quick_search_sessions` (`priority_class`, `genesis`) |
| Read the usage rate and forecast | `/settings` spot gate card | `get_spot_policy` |
| Toggle gating, set thresholds | `/settings` | `action_spot_policy` (`set_gating`) |
| One-click promote a genesis (non-trigger kinds only) | `/settings` | `action_spot_policy` (`promote_genesis` / `demote_genesis`) |
| Reset all genesis classes | `/settings` | `action_spot_policy` (`reset_genesis_classes`) |
| Set a trigger's class | Trigger edit form | `action_trigger` (`scheduling_class`) |
| Read a trigger's class | Trigger page, `/triggers` badge | `search_triggers`, `get_spot_policy` |
| Choose a class when spawning | **Scheduling class** on the new-session form | `start_session` (`scheduling_class`) |
| Change one session's class | **Make this session priority** on the hold banner | `action_session` (`change_scheduling_class`) |

Both MCP tools are in the **`health`** group, not `sessions`: they are about the deployment's quota
posture rather than about one session, and a `self_session` connection has no business rewriting the
global policy from inside a session it is being throttled by.
