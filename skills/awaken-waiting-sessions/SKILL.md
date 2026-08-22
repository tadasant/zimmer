---
name: awaken-waiting-sessions
title: Awaken Waiting Sessions
description: >
  Hand out compute that has just become available. Fires when a quota outage
  clears: decide which `waiting` sessions to start now and start them, highest
  precedence first, within the spot utilization thresholds and the
  max-concurrency ceiling set on /quotas. This is the wake policy for
  quota-parked spot work — one fleet-maintenance session runs it per recovery.
  Not a general session-management skill.
user-invocable: false
---

# Awaken Waiting Sessions

The Claude Code account pool has capacity again after being exhausted. Sessions
that were parked while it was empty are sitting in `waiting`, and **nothing else
will start them** — the timers that used to do it are gone. You are the wake.

Your job is a decision, not a sweep: start the work that matters most, up to what
the deployment can actually carry, and leave the rest parked for the next
recovery.

## What you are looking at

A parked session is `waiting` with `auth_outage_reason` in its metadata. Priority
sessions parked that way are resumed directly by Zimmer's own sweep, so the ones
left for you are **spot**.

`precedence` is the order. It is an absolute scale — higher is handled sooner,
100000 comes before 50 — and it is the operator's statement of what matters.
Honour it. Do not reorder, do not "fix" a value, and do not promote a session to
priority to get it past the gate; changing the queue to suit the wake is exactly
the failure this skill exists to prevent.

## Procedure

1. **Read the policy.** `get_spot_policy` reports the current decision: the two
   window utilizations against their targets, the concurrency ceiling, how many
   sessions are running, and whether spot work is allowed at all right now. If it
   says spot is held, stop — say why and archive. The pool recovering does not
   mean the thresholds are clear.
2. **Read the queue.** `quick_search_sessions` with `status: "waiting"`,
   `priority_class: "spot"` and `order: "precedence"` lists it in the order it
   should be worked, each row carrying its precedence.
3. **Work out how many slots there are.** The ceiling counts *every* running
   session, priority included. Slots = ceiling − running. If that is zero or
   negative, stop.
4. **Start that many, from the top of the list.** `action_session` with
   `restart`. Confirm each one moved to `running` before starting the next, and
   stop early if the policy stops allowing spot work — a batch that drains the
   window it was admitted under is worse than a short batch.
5. **Say what you did and what you left.** Name the sessions you started, the
   number still parked, and the reason you stopped (slots exhausted, threshold
   reached, queue empty). Then archive yourself.

## Things that are not your job

- **Do not touch precedence or scheduling class.** You read the queue; you do not
  write it.
- **Do not start priority sessions.** Zimmer's own sweep does that, and racing it
  double-starts work.
- **Do not raise the ceiling or the thresholds** to fit more in. They are the
  operator's budget, and /quotas is where a human changes them.
- **Do not retry a session that fails to start.** Report it and move on; a
  session that cannot start is a separate problem from a queue that needs
  draining.
