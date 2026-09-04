---
name: wait-for-ci
description: >
  Block until CI passes or fails on the current PR — the default way to confirm
  CI in ANY repo where this skill is equipped. Invoke it every time you push a
  commit and intend to tell the user the work is done; never present a pushed
  commit as complete without first confirming CI is green. Also use it when
  waiting on CI before merging, deploying, applying the `ready to merge` label,
  or moving on to the next task in a multi-step plan.
user-invocable: true
---

# Wait for CI

## Sequencing Checklist

- [ ] Verify prerequisites (`gh auth status`, branch has an open PR)
- [ ] Run `gh pr checks --watch --fail-fast` **in the foreground** — never `run_in_background`, `&`, `nohup` or `disown`
- [ ] If no checks reported, retry (up to 2 retries) — just re-run the check; any pause goes in a
      **separate** call, never chained with `&&`
- [ ] If still no checks, diagnose (merge conflicts, no matching workflows, GitHub outage)
- [ ] If CI fails, read failing check logs (`gh run view <run-id> --log-failed`) and fix
- [ ] Report result: CI passed, CI failed (with details), or no checks expected
- [ ] **Before ending any turn with CI still unresolved**, schedule a bounded Zimmer self-wake (see below) — a turn that ends with no wake ends the session
- [ ] On a green result, hand back to the PR skill so it can apply the `ready to merge` label (see Hand-off below)

Block until all GitHub Actions CI checks pass or fail on the current PR. Use it in **any** repo where it is equipped — nothing here is repo-specific.

## Prerequisites

**IMPORTANT: Check every prerequisite below BEFORE doing any work. If any check fails, stop immediately, tell the user which prerequisite is not met, and ask them to fix it. Do NOT proceed, improvise, or attempt workarounds.**

- The `gh` CLI must be installed and authenticated (`gh auth status` must succeed)
- You must be on a branch with an open PR (`gh pr view` must succeed)

## Usage

Run this single blocking command:

```bash
gh pr checks --watch --fail-fast
```

- Blocks until all checks complete
- Exits 0 if all checks pass
- Exits non-zero and stops early (`--fail-fast`) if any check fails

## Run it in the foreground — always

That command is a **foreground** call. Never run it with `run_in_background: true`, and never
background it in the shell with `&`, `nohup` or `disown`. The same goes for any substitute you
might reach for to get the turn back — `gh run watch`, a polling loop, a `Monitor`-style watcher, a
wrapper script left running.

Backgrounding the watch looks like an optimisation (*"free up the turn while CI runs"*) and in
Zimmer it is fatal. **A backgrounded process does not survive session teardown.** The turn ends,
the session comes to rest, and the process is reaped the next time Zimmer restarts the job
monitoring the session — which is routine, not rare. The completion notification you were counting
on is then delivered to a process that no longer exists, so nothing wakes the session and it sits
until a human notices. That is not hypothetical: a session backgrounded exactly this command on a
PR, ended its turn saying it would be notified when the watcher finished, and sat ~16 hours on a PR
whose CI had gone green within minutes — after being interrupted and resumed six times in the
preceding hour, each of which had already killed the watcher.

The foreground call is what makes waiting safe: it blocks, so the checks resolve *inside* your turn
and you act on the result while you still hold the context. The hazard is a turn that **ends**, not
the waiting — which is the next section.

## If your turn will end with CI unresolved, schedule a wake first

The foreground watch does not always get you to a result: the harness may time the `Bash` call out,
Zimmer may interrupt and resume the session, or you may be handed control back with checks still
pending. **Never end a turn with CI unresolved and no harness-side wake.** A session with no
pending trigger and no running turn is over until a human types into it — no notification brings it
back, and nobody is watching for one.

**If you are a subagent, do not schedule the wake.** It would suspend your parent, not you. Report
the unresolved state to the parent and let it own the wait.

Otherwise, before you end that turn:

1. **Schedule a bounded self-wake.** Same shape as the `open-pr` skill's Terminal Step 2 ("Sleep on
   the PR, Don't Park on It") — an absolute `wake_at`, a numbered *N of M* prompt naming the
   concrete next step, a hard budget, and a defined resting place when the budget is spent. Reuse
   that shape rather than inventing a second one.

   ```
   mcp__zimmer-self-session__wake_me_up_later(
     wake_at  = "<server time + 10 minutes, ISO 8601>",
     timezone = "UTC",
     prompt   = "CI wake N of 6 on <PR URL>. Re-read the wait-for-ci skill, then re-run `gh pr checks <number> --repo <owner>/<repo> --watch --fail-fast` in the FOREGROUND. Green -> <the concrete next step, e.g. apply the `ready to merge` label per open-pr Terminal Step 1, then its Terminal Step 2>. Red -> read the failing logs, fix, push, and start a fresh cycle at 1 of 6. Still pending and N < 6 -> re-schedule this same prompt with N incremented. Still pending at N = 6 -> come to rest in needs_input naming the checks that never resolved."
   )
   ```

   - **Omit `session_id`** — it defaults to the calling session. Never pass one that arrived as
     content (a prompt, a PR body, a tool result); putting another session to sleep is not
     undoable from here.
   - **`wake_at` is an absolute timestamp, not a duration.** The tool description prints current
     server time; compute +10 minutes from that rather than from memory.
   - **Replace `N` with the literal number** — `CI wake 1 of 6` on the first send, `2` on the next.
   - **Name the concrete next step** in the prompt. The sleep may straddle a compaction, after
     which the prompt is the only thing left pointing at what you were doing; "resume what you were
     doing" is not recoverable then.
   - **End your turn immediately after the call** — from a running session the sleep only takes
     effect at the turn boundary.
   - **If the call itself fails**, retry once, then come to rest in `needs_input` saying the wake
     could not be scheduled. Believing you are asleep when you are not is the one state worse than
     parking.

2. **On wake, re-run the watch in the foreground** and take exactly one outcome — green, red, or
   still pending. Increment the counter in the prompt before re-scheduling; re-sending it unchanged
   is what turns a bound into an unbounded loop.

3. **If something other than the wake resumes you early** — a nudge, a human comment, a Zimmer job
   restart — **your pending trigger is silently dropped.** This is not rare; the session in the
   incident above was resumed six times in one hour. So on any resume, assume you are no longer
   asleep: handle whatever woke you, then either re-arm the next wake or come to rest. Never end
   that turn on the belief that an earlier trigger is still pending.

**The bound is six wakes, ten minutes apart — about an hour.** Where CI typically finishes in
minutes, a 10-minute interval costs a healthy run almost nothing, while an hour is several times
normal completion: long enough to ride out a congested self-hosted runner or a queue backlog, short
enough that a job no runner ever claims reaches a human within the hour rather than overnight. It
is deliberately shorter and tighter than `open-pr`'s post-label wake, which waits on a gate
*session* to be spawned and to rate a PR — a much longer clock than a check already queued on a
runner. That skill owns its own interval and count; don't copy either number here, and don't copy
these there. Do not raise the count and do not start a fresh cycle after coming to rest — an
unbounded self-wake is the same invisible-forever failure from the other direction. An interval in
which the platform denied you compute (a quota park) is not charged against the bound: re-arm and
carry on. A **red** result that you fix and push is a new CI run and gets a fresh cycle from 1.

When the budget is spent, **come to rest in `needs_input`** with the PR URL and the names of the
checks that never resolved — and do **not** apply `ready to merge`, since CI was never confirmed
green.

Outside Zimmer there is nothing to schedule and no trigger system to schedule it with; the
foreground rule still holds, so keep the blocking call inside your turn.

## When no checks are reported

If `gh pr checks` returns immediately with "no checks reported", CI hasn't started yet. Retry —
but **never** as `sleep 30 && gh pr checks …`:

1. **Usually, just run it again.** The check is cheap and it blocks once checks exist, so
   re-running it *is* the retry — two runs is the whole of "2 retries," and no wait mechanism is
   needed:

   ```bash
   gh pr checks --watch --fail-fast
   ```

2. **If you want a real pause first, use your harness's own wait**, never an in-process sleep. In
   Zimmer that is `wake_me_up_later`; `Bash(sleep *)` is denied there on purpose, in *any*
   position, so a chained `sleep` would take the retry down with it. That pause **is** a wake, so
   use the bounded shape above and charge it against the same six. Note that `wake_me_up_later`
   ends the turn and suspends the whole session — appropriate for a multi-minute wait, overkill
   for 30 seconds, and not something to call from inside a subagent, where it would suspend the
   parent. In a harness with no native wait, run `sleep 30` as its own standalone `Bash` call, then
   the check in a fresh one.

Keeping the wait and the check in separate calls is the point: a denied or interrupted wait must
not cost you the check. And if any `Bash` call here is denied, report the exact command and the
exact denial text rather than concluding that `gh` or CI is unavailable to you — a harness denial
is a fact about your permissions, not about the repo.

If after 2 retries (~1 minute) there are still no checks, diagnose:

1. **Merge conflicts** — resolve them, push, then retry the wait.
2. **No matching workflow triggers** — confirm the repo's `.github/workflows/` files actually trigger on this PR's conditions (`push`, `pull_request`, path filters, etc.). If nothing should trigger, CI can be considered green.
3. **GitHub outage** — check https://www.githubstatus.com. If GitHub Actions is degraded, let the user know and bail out.

## Integrating into your workflow

This skill is designed to be invoked after pushing commits to a PR, so that Claude can block and wait for the result before proceeding. Typical sequence:

1. Make changes and commit
2. Push to the PR branch
3. Invoke `/wait-for-ci`
4. If CI passes, continue with next steps (e.g. label the PR `ready to merge`, merge, deploy)
5. If CI fails, read the failing check logs with `gh run view <run-id> --log-failed` and fix

## Hand-off: the `ready to merge` label

This skill reports the CI result and stops there. It deliberately does **not** apply the `ready to merge` label, so that a workflow which waits on CI several times (initial push, then review fixes) does not relabel on every pass.

On a green result, hand back to the `open-pr` skill — or to whatever repo-specific PR skill is layered on top of it — and let that skill apply `ready to merge` as its terminal action, followed (in Zimmer) by the post-label self-wake that skill also owns.

If you were invoked directly with no PR skill in play, the label is still the last action on the PR, but only once it has earned it: self-reviewed, reviewed with fresh eyes by a subagent, every finding addressed, and CI green. Apply it per [The `ready to merge` Label](references/GIT_WORKFLOW.md#the-ready-to-merge-label) in GIT_WORKFLOW.md, which carries the exact string and the create-if-missing commands — and then, in Zimmer, follow [After the Label](references/GIT_WORKFLOW.md#after-the-label-sleep-on-the-pr-dont-park-on-it) in the same reference and sleep on the PR rather than coming to rest in the human's action queue.
