---
title: Background jobs
description: Every cron job, what it does, and what breaks when the worker isn't running.
sidebar:
  order: 3
---

Zimmer runs on GoodJob. In development it's `:async` (in-process with Puma); in production and staging
it's `:external`, requiring a separate `bundle exec good_job start`.

:::note[Jobs run on the `worker` role]
The Kamal deploy runs `bundle exec good_job start` as a dedicated `worker` role
(`config/deploy.staging.yml`), so everything on this page runs on the deployed droplet. Locally you
need `bin/dev` (or a `good_job start` process) for jobs to fire.
:::

## The cron schedule

From `config.good_job.cron`:

| Cadence | Job | What it does |
| --- | --- | --- |
| 30s | `HeartbeatSweepJob` | Nudge `needs_input` sessions with a heartbeat enabled |
| 30s | `GitHubPullRequestPollerJob` | Poll PR state and CI status on sessions with a PR URL; tell a session when its PR merges |
| 30s | `GithubCommentPollerJob` | Poll PR review comments |
| 1m | `SlackTriggerPollerJob` | Poll Slack channels for trigger conditions |
| 1m | `QueueRecoveryModeExpiryJob` | Lift queue recovery mode once its TTL has elapsed |
| 1m | `ScheduleTriggerJob` | Fire due schedule triggers |
| 1m | `GithubTriggerPollerJob` | Poll GitHub for label-added and new-issue trigger conditions |
| 2m | `GitHubMergeConflictPollerJob` | Detect merge conflicts on open PRs |
| 2m | `CliStatusRefreshJob` | Refresh the `gh` / `claude` / `codex` version cache |
| 5m | `GithubTriggerHealthCheckJob` | Alert when GitHub trigger polling has silently stopped succeeding |
| 5m | `CleanupOrphanedSessionsJob` | Sessions marked `running` whose process is gone |
| 5m | `RefreshRuntimeAuthTokensJob` | Refresh Anthropic/OpenAI OAuth tokens |
| 5m | `CleanupExpiredElicitationsJob` | Expire elicitations + clear stranded blocks (leaving a banner that says the round-trip was lost) |
| 5m | `ElicitationEndpointHealthCheckJob` | Alert when MCP servers cannot reach the approval endpoint (production and staging only — see below) |
| 5m | `CleanupRuntimeLoginAttemptsJob` | Reap abandoned login attempts |
| 10m | `TranscriptArchiveJob` | Rebuild `latest.zip` |
| 15m | `CatalogRefreshJob` | `air update` + reload the catalog |
| 15m | `QuotaResetCheckerJob` | Restore `quota_exceeded` Claude accounts, then resume the sessions parked on them |
| 15m | `ClaudeUsageSamplerJob` | Read the serving Claude account's quota, so the spot gate decides on a fresh number — `QuotaResetCheckerJob` samples only *exceeded* accounts, and a healthy one is otherwise read only when somebody opens /quotas. See [Spot and priority](/sessions/spot-and-priority/). |
| 15m | `RefreshXOauthTokensJob` | Refresh X/Twitter tokens |
| 30m | `RefreshMcpOauthTokensJob` | Refresh MCP OAuth tokens expiring within the hour |
| hourly | `StaleCloneCleanupJob` | Reap clones from archived sessions, and sweep the scratch/attachment directories of sessions whose row is gone |
| hourly :45 | `SlackTriggerHealthCheckJob` | Detect Slack feeds that silently stopped firing |
| daily 08:00 | `MangledCloneReportJob` | One line saying how many clones the archive-side mass-deletion guard defused in the last day — see below |
| — | `ZombieReaperJob`, `DeferredCloneCleanupJob`, `EmptyTrashJob`, `DockerCleanupJob`, `OrphanCloneFilesystemCleanupJob`, `SystemHealthMonitorJob`, `CertExpiryMonitorJob`, `EgressHealthCheckJob` | cleanup and monitoring |

:::note[Sub-minute cron works]
The `*/30 * * * * *` entries are six-field cron, with a leading seconds field, and they do what they
look like: fugit parses the field, and `GoodJob::CronEntry#next_at` hands straight through to
`Fugit::Cron#next_time` with no minute floor, so those three jobs fire every 30 seconds.

A five-field expression is the same thing with the seconds field pinned to `0`. So a one-minute
cadence anywhere in the table is a choice about how often the job should run, not a limit on how
often it could. `test/config/cron_schedule_test.rb` pins this: it scans every expression in the
three environment files, and for each six-field one it asserts fugit still fires it more than once
a minute — 30 seconds apart, for the `*/30 * * * * *` the whole config uses. A fugit upgrade that
stopped reading the seconds field fails CI instead of silently slowing three pollers to a crawl.
:::

## A deleted session takes its directories with it

Archiving a session runs it through the trash pipeline, which reaps its clone, its scratch
directory and its prompt attachments on a timer. **Deleting** one (`DELETE /api/v1/sessions/:id`)
is a different door: the row goes immediately, and with it the only handle anything had on those
bytes. Every reaper in the pipeline — `EmptyTrashJob`, `DeferredCloneCleanupJob`,
`StaleCloneCleanupJob`'s DB-driven scopes — starts from a `Session` query and cleans up by id, so
once the row is gone there is no query left that can find the directories.

Two things close that, at different speeds:

- **`Session#reclaim_session_directories`** (`after_destroy_commit`) removes the session's scratch
  directory and its two prompt-attachment directories as soon as the delete commits. After commit,
  not before: a destroy that rolls back must not take a live session's state with it. The clone is
  deliberately left to its own reapers — tearing one down means Docker Compose teardown, which does
  not belong in a `DELETE` request.
- **`StaleCloneCleanupJob#sweep_orphaned_session_directories`** (hourly) is the safety net, for rows
  deleted before this existed and for any delete path that skips callbacks. It is the same shape as
  the clone orphan sweep: the directory name under each root *is* the session id, so an orphan is a
  set difference.

That sweep deletes directories on the live data volume from a computed set difference, so it is
fenced:

| Guard | Effect |
| --- | --- |
| `SESSION_ID_DIR` (`/\A[1-9]\d{0,17}\z/`) | Only directories named like a session id are candidates. Excludes the `temp_<uuid>` pre-session upload dirs and anything too long for a bigint |
| `Session.unscoped.where(id: candidates)` | Asks "which of *these* ids exist?", never "list every id" — a directory goes only when Postgres said that primary key is gone. `unscoped` because this query decides deletions, so a `default_scope` added later must not be able to hide a live row from it |
| Listing before querying | A session created between the two is in the answer; the ordering that could miss one is impossible |
| `ORPHAN_AGE_THRESHOLD` (1 hour) | A directory younger than an hour survives regardless, so a scratch dir created before its row committed is safe |
| Empty `sessions` table | Aborts the whole sweep. This catches only the *completely* empty case — a restore from a stale snapshot still has rows and passes it, and `ORPHAN_SWEEP_LIMIT` is the real backstop there |
| `ORPHAN_SWEEP_LIMIT` (200 per root) | Caps one run's blast radius; the overflow is logged and picked up next hour |
| Only the deployment that owns the volume | A root inside the durable volume (the parent of `ClonesDirectory.base`) is swept only in production and staging. Anywhere else it is swept only if it has been relocated clear of that volume — see below |

Every removal is logged with its path and mtime before the bytes go.

That last row is the one worth understanding, because it is not about environment names being tidy.
The hazard is a process whose database does not describe the volume it is looking at. `bin/rails
test` runs against `zimmer_test`; `bin/dev` runs against `zimmer_development` **and runs this job on
an hourly cron in-process**. Both resolve the default roots to `~/.zimmer` — which, on a machine
that also hosts a real Zimmer, is the volume holding live sessions' scratch. Unfenced, either would
compute every one of those as an orphan. Scratch and prompt attachments have no remote to be
re-fetched from, so that is unrecoverable, which is why the fence is on the *path* rather than on
whether some `AGENT_*_DIR` happens to be set.

## Clone pruning has a second, urgent gear

`OrphanCloneFilesystemCleanupJob` is on the hourly cleanup cron, and on that schedule it is
patient: `AGE_THRESHOLD` is 48 hours and `BATCH_LIMIT` is 20 directories per run. That is the right
posture for a background sweep and the wrong one for a disk filling up in an afternoon, so the same
job has a second entry point.

`OrphanCloneFilesystemCleanupJob.reclaim_space(target_free_bytes:)` is called synchronously by
[`CloneDiskGuard`](/sessions/spawning/#the-pre-clone-disk-guard) when a session is about to clone
into a volume that cannot hold it. It lowers **only** the age bar (`PRESSURE_AGE_THRESHOLD`, 2
hours), and it stops the moment the volume reports enough free space.

It takes a *requirement*, never a directory: it resolves `ClonesDirectory.base` itself, so no
caller can point recursive deletion at a path that is not the clones root.

Because it runs on the launch path — inside `AgentSessionJob`, before the session reaches
`running` — it is bounded in wall-clock time, not just in count. `cleanup_orphan` tears down Docker
Compose resources first, which is capped at `DockerComposeCleanupService::COMPOSE_DOWN_TIMEOUT`
(120s) **per directory**, so an unbounded loop would wedge the session in `waiting` for hours while
still holding its GoodJob lock and still looking alive to orphan detection. `RECLAIM_BUDGET_SECONDS`
(60) is checked before each removal and `PRESSURE_BATCH_LIMIT` is 20, making the true bound the
budget plus one directory's teardown.

Everything else is shared with the scheduled sweep, deliberately — a pruner that deletes a live
session's working directory is a far worse outcome than the disk pressure it was relieving:

| Guard | Effect |
| --- | --- |
| Tracked-path check | A directory whose basename matches **any** session row's `metadata->>'clone_path'` is never a candidate, whatever that session's status. Only directories with no owning row at all are eligible |
| `Session.live_clone_paths` | A second, age-independent check: a clone owned by a non-terminal session is never touched |
| `PRESSURE_AGE_THRESHOLD` (2 hours) | Covers the startup race where a clone exists but its session has not yet persisted `clone_path`. That window is bounded by `GIT_CLONE_TIMEOUT_SECONDS` (300s) plus bounded retries — under ten minutes at worst — so two hours is more than an order of magnitude of headroom, and still more conservative than `StaleCloneCleanupJob`'s equivalent sweep at one hour |
| Stop-at-target | Space is re-probed after every removal, so a run under pressure deletes the fewest directories that clear the requirement, oldest first |
| Only the deployment that owns the volume | A clones base inside the durable volume is reaped only in production and staging. This is the fence `StaleCloneCleanupJob` already applies to its per-session sweep, and it exists because orphan-hood is a set difference against the **connected** database: `bin/rails test` (`zimmer_test`) and `bin/dev` (`zimmer_development`) both resolve the clones base to `~/.zimmer/clones`, so on a machine that also hosts a real Zimmer, either would compute every live clone as an orphan. A relocated base (`AGENT_CLONES_DIR` pointed clear of the volume) is reapable anywhere |

A removal that raises is logged and skipped; the run continues with the next candidate.

## Counting mangled clones without paging for each one

An interrupted `rm -rf` on a live clone leaves a working tree that is nothing but deletions of
tracked files. `CloneArtifactService` refuses to preserve such a tree on archive — see
[the archive path](/sessions/lifecycle/) — and that refusal is fully self-healing: the corruption is
dropped, the session's real work still travels in the bundle and the filtered patch, and the deleted
files come back from `HEAD`.

It used to log at `.error`, which meant `StructuredLogger` reported it to GlitchTip and tripped the
"backend logging errors" alert rule for every clone the guard *successfully* handled. Nine pages in
one afternoon, for nine sessions that all archived fine. It logs at `.warn` now, so the
per-occurrence line still reaches VictoriaLogs and nobody is woken up for it.

The rate still matters — it is the live signal for
[#412](https://github.com/tadasant/zimmer/issues/412), the non-atomic clone delete that mangles the
trees in the first place — so the count is kept in two durable places rather than in the alert:

- `DeferredCloneCleanupJob` stamps `mangled_clone_dropped_deletions` and `mangled_clone_defused_at`
  on the session, which makes the history countable in SQL long after the log line has aged out.
- `MangledCloneReportJob` runs daily at 08:00 UTC and emits **one** `.warn` line for the window: how
  many sessions had a clone defused, how many tracked-file deletions were dropped, and which
  sessions. `REPORT_WINDOW` is 25 hours — an hour wider than the cron interval on purpose. The
  window is measured from when the run *starts*, not from when cron fired, so a run that starts late
  (a deploy, a busy scheduler, a retry) would otherwise drop everything in the gap. The overlap
  trades that for the opposite error: a defusal inside it can appear in two consecutive reports. A
  double-count is visible in the lines themselves; a gap is invisible. A day with nothing to report
  writes only an `INFO` line, which is below the [export threshold](/operate/observability/) and
  therefore silence in VictoriaLogs.

The unarchive-side refusals stay at `.error`. Those are the paths that can still leave a session
broken, and they should page.

## The zombie reaper only takes what nobody is waiting for

`ZombieReaperJob` runs every 5 minutes in the same process as `AgentSessionJob`'s monitoring loop
and the pollers. That matters: reaping a child consumes its exit status, and in a shared process
the wrong reaper wins the race. When the reaper collected a pid the monitoring loop was waiting
on, `wait_nonblock` got `ECHILD`, the loop fell through to signal-based detection, and the session
was paused into `needs_input` — skipping the SIGTERM retry, `/compact` retry and API-error backoff
that `handle_exit` owns.

So the job reaps named pids, not "whatever `waitpid(-1)` hands back". A pid is collected only if
all three hold:

1. it is defunct and a direct child of this process;
2. it is *still* defunct a couple of seconds later — anything with a thread blocked in `waitpid`
   (every `Open3.capture3` wait thread) is reaped by that thread within microseconds, so surviving
   the second look means no such waiter exists;
3. `ChildWaiterRegistry` has no live waiter for it. `SystemProcessManager` claims a pid when it
   spawns it and heartbeats the claim on every `wait` call, so a claim that has gone quiet for
   five minutes belongs to a waiter that died and no longer protects its pid.

Rule 3's heartbeat is what keeps the job honest in both directions. Without it, a claim left by a
dead waiter would shield its zombie forever and they would pile up again — which is what the job
was built for after 6,032 of them accumulated under the worker over two days.

An orphaned claim is logged at warn level with the command that was spawned. That line means a
real upstream leak: something started a child and stopped waiting on it.

:::note[tini does not cover this]
`init: true` in `deploy*.yml` reaps processes *reparented to PID 1* — grandchildren orphaned when
a `gh`, `air` or `claude` process exits. A direct child of the Ruby worker is never reparented
while the worker is alive, so tini can never collect it. Any child Zimmer spawns and does not wait
on is this job's problem, permanently.
:::

## What the PR comment poller acts on

`GithubCommentPollerJob` records every new comment on a tracked PR in the session's
`custom_metadata`, but only some of them wake the session. A comment produces a follow-up prompt
when all of these hold:

- the author is in `WHITELISTED_USERS` (`tadasant`, `macoughl`);
- the body carries no `[CC Says]` marker — that's how the agent's own comments are attributed;
- **no Zimmer session is on record as having posted it** (see below);
- the body is not a bot command (`BLACKLISTED_PATTERNS`, currently just `/deploy staging`);
- the body is not a Zimmer automation report (`AUTOMATION_REPORT_HEADINGS`, currently the
  pr-merge-gate rating, recognized by its `## 🚀 Merge gate` heading);
- the comment was created after this session started tracking the PR — sessions predating
  `github_pr_tracking_started_at` have no such timestamp, and for those every comment qualifies;
- the comment is at least `ATTRIBUTION_GRACE_SECONDS` (60s) old, so authorship has had time to
  settle.

Every comment carries the outcome in its `dispatch_state` field in `custom_metadata`:
`dispatched`, `deferred` (too new to attribute; re-examined next poll), or `skipped:<reason>`
(terminal). A comment that never woke a session says why it didn't.

### How Zimmer knows which comments its own agents posted

`gh` inside every session authenticates as the human, so an agent's comment carries
`user.login: tadasant` exactly like a real one. Author-based filtering cannot separate them, and
the `[CC Says]` convention only works when the agent remembers it. When it didn't, the poller
dispatched an agent's comment as a "GitHub Comment Response Required" turn — and because routing is
by tracked PR URL rather than by authorship, it went to *every* session tracking that PR, not just
the one that wrote it. Each reply would be another comment by `tadasant`, so the cycle has no
natural end.

What GitHub can't answer, Zimmer can: it watched the tool call.
`TranscriptHooks::GithubCommentAuthorshipHook` scans each transcript for shell commands that post a
comment (`gh pr comment`, `gh issue comment`, `gh pr review`, and `gh api` writes to a comments
endpoint), reads the comment id out of the permalink those commands print
(`#issuecomment-<id>` / `#discussion_r<id>`), and records an `AgentPostedGithubComment` row. The
table is keyed by comment, not by session, so one session's post is suppressed for every session
polling that PR.

Only the output of *posting* commands is scanned. An agent that merely reads a comment
(`gh api repos/…/issues/comments/<id>`) gets that comment's own `html_url` back, and treating that
as a post would suppress a human comment the agent just looked at.

The hook runs when the posting session's transcript is next polled — a second or two, not
instantly. `ATTRIBUTION_GRACE_SECONDS` covers that window: a comment younger than 60 seconds is
marked `deferred` and re-examined on the next poll instead of being dispatched on the strength of
an authorship record that may not exist yet.

The automation filter lives in Zimmer rather than in the automations themselves because the merge
gate posts through `gh` as `tadasant` and carries no marker — to the poller it looks exactly like
the owner leaving a comment. Matching the report heading is what keeps a rating from waking the
session it rates, and it means a new automation doesn't have to remember to opt in. Add its heading
to `AUTOMATION_REPORT_HEADINGS`; the comparison ignores heading level and leading emoji.

The 👀 reaction follows the same decision, and follows it *after* the fact rather than before:
Zimmer adds the reaction only once a follow-up is actually going out — the comment cleared every
filter above, `GithubCommentPromptBuilder#actionable?` returned true, and the prompt came back
non-blank. On a public repo owned by someone outside `TRUSTED_OWNERS`, `actionable?` is false and
nothing happens at all: no prompt, no reaction, just an info log line. A 👀 is a promise to
respond, and on a repo we don't control the agent isn't allowed to keep it. The reaction itself
stays best-effort — a failed reaction API call is logged and the follow-up proceeds.

`actionable?` is also false when the visibility lookup *fails*, because "public" is the safe
assumption when `gh` can't answer — see [Limitations](/limitations/#a-failed-repo-visibility-lookup-drops-the-comment).
That case logs at `warn` rather than `info`, since the comment it drops may well have been a real
one on a private repo.

## What a merged PR tells the session

`GitHubPullRequestPollerJob` writes each tracked PR's state into
`custom_metadata["github_pull_request_statuses"]` on every tick it is allowed to poll — every 30
seconds for a session the user has touched recently, less often as `PollBackoff` stretches the
interval out. When one of them goes from `open` to `merged`, the session that owns it gets
`AutomatedPrompts::PR_MERGED_TEMPLATE` through the same delivery path the merge conflict poller
uses (`AutomatedSessionMessage`): sent immediately if the session is parked in `needs_input`, queued
behind the current turn if it is running or waiting.

The message names two outcomes and lets the agent pick. Either the merge was the end of the work,
in which case the session archives itself and stops sitting in your queue. Or the session was parked
*waiting* for that merge, to rebase onto it or to start the next piece, in which case it carries on.
It also says that an unanswered human message outranks archiving, because a session that closes
itself on top of a question you asked is the expensive failure here.

Three rules keep it quiet:

- **Only the `open` → `merged` transition.** A PR that was already merged the first time the poller
  saw it is not this session's merge event, and wakes nobody.
- **Once per PR.** `custom_metadata["github_pull_request_merged_notified"]` records which PRs have
  been announced. A session with three PRs is told about each one as it lands, and only then.
- **No debounce, unlike merge conflicts.** The two-poll confirmation in
  `GitHubMergeConflictPollerJob` exists because GitHub's `mergeable` field returns transient
  `false` readings. `mergedAt` has no such failure mode: a PR with a merge timestamp is merged, and
  stays merged.

The message is delivered before the metadata marker is written, so a crash in between costs one
duplicate on the next poll rather than a notification that silently never arrives.

## Queues

Most jobs run on `default`. Two are deliberately isolated:

- **`:triggers`** — `AoEventTriggerJob` and `ScheduleTriggerJob`. They were previously starved on
  `default`; `AoEventTriggerJob::DISPATCH_LATENCY_WARN_THRESHOLD = 120s` exists because of it.
- **`:pollers`** with `total_limit: 1` — `SlackTriggerPollerJob` and `GithubTriggerPollerJob`, and
  since then the rest of the periodic work that must not queue behind session jobs:
  `GithubCommentPollerJob`, `GitHubPullRequestPollerJob`, `GitHubMergeConflictPollerJob`,
  `CatalogRefreshJob`, `CliStatusRefreshJob`, `WarmSkillsCacheJob`, `EgressHealthCheckJob`,
  `ElicitationEndpointHealthCheckJob`, `SystemHealthMonitorJob` and `MangledCloneReportJob`.
  The trigger pollers make slow external calls once per condition, and a slow tick must not stack against itself.
  Their polling is idempotent — state only advances for items that produced a session — so a skipped
  tick is simply picked up by the next run.

`total_limit: 1` has a corollary that matters for failure handling: a run that blocks *is* polling
for the whole instance, and every cron tick that lands meanwhile is rejected rather than queued. So
`SlackTriggerPollerJob` does not wait out a Slack outage on its slot. `SlackService` absorbs a short
blip in process (`MAX_RETRIES = 3`, backing off 1s, 2s, 4s; a 429's `retry_after` is honored verbatim
when Slack gives one, but only ridden out in process when it is 8s or under), and raises
`SlackService::TransientError` for anything longer. The job answers that by calling `retry_job` with
an exponential wait (30s, 60s, 120s, 240s, 480s — or Slack's `retry_after` if longer, capped at 10
minutes) and returning, freeing the thread.

Rescheduling rather than re-enqueuing is deliberate. `retry_job` reuses the same job id, which
GoodJob's concurrency control lets through, and the row stays unfinished — so the singleton key is
still held, the cron ticks in between stay no-ops, and the deferred run is the *next* poll rather
than an extra one. The deferral count rides in the job's serialized params, not in `executions`,
which also counts retries the poller knows nothing about. After `MAX_DEFERRALS` (5) the job stops
deferring, logs at ERROR, and raises an alert.

A transient failure deep in the sweep does not abort it. Each unit — channel, thread, DM — owns a
cursor that only advances for units that finished, and those writes are batched at the end, so
unwinding mid-sweep would skip them and replay finished units as duplicate sessions. The unit
rescues record the failure instead, the sweep completes its bookkeeping, and the deferral happens
once at the end.

Those unit rescues log a `TransientError` at **WARN**, and that is load-bearing. The deferral
re-reads the unit from a cursor that never moved, so the work is not lost — while an ERROR line
pages the on-call. Logging a recovered 429 at ERROR meant a 111-second rate-limit burst across nine
threads paged a human about an incident in which nothing broke, twice
([#509](https://github.com/tadasant/zimmer/issues/509)). ERROR is reserved for the failures that
earn it: the give-up line above, the rescues where a transient failure loses work the deferral
cannot bring back (`#process_message`, whose caller advances the cursor past that message either
way, and `#fetch_recent_history`, which degrades to an empty slice its callers finish the sweep
trusting), and anything that is not transient in the first place. See
[observability](/operate/observability/#a-failure-the-code-recovered-from-is-logged-at-warn-not-error).

## Queue recovery mode

The escape hatch for a queue that has run away from you. `QueueRecoveryMode` halts job **execution**
on the demand-side queues — `pollers`, `triggers` and `default` — and deliberately leaves `agents`
running.

That asymmetry is the whole design. Pausing every queue would also pause `agents`, which is where
`AgentSessionJob` lives, so the mode would halt the very investigation it exists to enable. `agents`
is not a source of queue demand either: it holds one long-running job per session, and sessions are
started by a human or by an already-running agent, never by the backlog. So while recovery mode is
on you can still start a session, and that session can still run, look at `/jobs`, disable a
stampeding trigger, and archive runaway sessions — with nothing new arriving behind it.

:::caution[Not session recovery]
"Recovery" elsewhere in Zimmer means recovering *sessions* after a deploy or a crash
(`DeploymentRecoveryJob`, `CleanupOrphanedSessionsJob`, `metadata["paused_by"] = "recovery"`). Queue
recovery mode is unrelated and never touches session state. The noun is qualified everywhere —
class, column, route, MCP action, UI copy — so the two do not read as the same thing.
:::

**The halt is GoodJob's own.** `GoodJob.pause(queue:)` writes to `good_job_settings` and
`GoodJob::Job.exclude_paused` applies it inside the dequeue query. It requires
`config.good_job.enable_pauses`, which `config/application.rb` turns on — without it GoodJob accepts
the pause rows and ignores them, so `QueueRecoveryMode.enter!` refuses rather than reporting a halt
that isn't happening. Zimmer's own metadata (who, why, when it auto-exits) lives in
`app_settings.queue_recovery_mode`.

**Jobs are frozen, not discarded.** Enqueue keeps working and cron keeps ticking; only execution
stops. Everything waiting drains when the mode is lifted. The periodic jobs that would otherwise
pile up are already singletons (`total_limit: 1`), so at most one of each poller can be waiting.

**It always ends.** Every entry carries a TTL — 60 minutes by default, clamped to 5 minutes–4 hours;
re-entering extends it. Two independent paths act on that TTL, because each covers the other's
failure mode:

| Path | Where it runs | What kills it |
| --- | --- | --- |
| `QueueRecoveryModeExpiryJob` (1m cron) | the `agents` queue — the one queue the mode does not pause | all 16 `agents` threads busy with long sessions, which is exactly the runaway-session incident |
| `ApplicationController#reconcile_queue_recovery_mode` | the web process, throttled to one check per 30s | no web traffic at all |

On top of both, `QueueRecoveryMode.status` computes `active` from the clock, so no surface can report
a halt for a window that has already elapsed even if neither path has run yet.

**It is loud.** A Slack alert on enter, extend and exit (the auto-exit says it was the TTL and not a
person), an amber banner on every page, and a panel on `/health`. Note that halting `pollers` also
halts `SystemHealthMonitorJob`, so the "Queue backlog critical" page stops firing while the mode is
on — deliberate, since that backlog is now the operator's own doing.

**Surfaces.** `/health` (enter, extend, resume), `POST /api/v1/health/enter_queue_recovery_mode` and
`exit_queue_recovery_mode`, and the MCP `action_health` actions `enter_queue_recovery_mode` /
`exit_queue_recovery_mode`. None of them are behind the shared `HealthActionCooldown`: that throttle
fails closed when the cache is unavailable, and an overloaded instance is exactly when the cache is
least trustworthy — a lock on the escape hatch is worse than an unthrottled two-row write.

## Trigger-poll liveness

Both trigger pollers alert `#eng-alerts` (via `AlertService`) from a per-condition `rescue` when a
poll **raises**. That only covers failures noisy enough to throw. It does not cover a poller that
stops running at all — and with `total_limit: 1`, one wedged tick is enough: while it holds the only
slot, every subsequent minute's enqueue is a silent no-op.

`GithubSearchService` shells out to `gh`, and during a GitHub REST incident a request can stall with
the connection half-open — no response, no reset. An unbounded `Open3.capture3` blocks on that
forever, so nothing raises, nothing alerts, and label/issue triggers (including the `ready to merge`
merge gate) quietly stop firing. Two mechanisms close that:

- **A bound on every `gh` call.** `GithubSearchService::REQUEST_TIMEOUT` (15s) and
  `AUTH_STATUS_TIMEOUT` (10s) run each invocation under `BoundedSubprocess`, which kills the process
  group on deadline. A hang becomes a `SearchError` — an ordinary, alerting failure the next tick
  retries — instead of a wedge. Every non-success gh outcome is normalized the same way: a non-zero
  exit, and a **nil `Process::Status`** (`BoundedSubprocess` returns Open3's `wait_thr.value`, which is
  `nil` when the child was reaped elsewhere before its own `waitpid` — a race in the multi-threaded
  worker) both raise `SearchError` rather than crashing the tick with `undefined method 'success?' for nil`.
  A failure that reads as *GitHub's* rather than Zimmer's — a 5xx, a 401, a body that arrived cut
  short, an exit code we never got to read — is re-run twice first
  (`TRANSIENT_REQUEST_RETRY_DELAYS`, 1s then 3s, logged at INFO), so a blip that clears within the
  tick never reaches the alerting rescue at all. A hang and a rate limit are the exceptions: the
  first has already spent `REQUEST_TIMEOUT`, the second cannot clear inside the budget and would
  spend the quota that caused it, so both raise on the first attempt. What survives three attempts
  raises and pages exactly as one failure used to, with the attempt count in the message.
- **A liveness check.** `GithubTriggerPollerJob` stamps a Redis heartbeat
  (`HEARTBEAT_CACHE_KEY`) on every sweep that processes at least one condition successfully.
  `GithubTriggerHealthCheckJob` reads it every 5 minutes and pages `#eng-alerts` when it is older
  than `STALE_THRESHOLD` (15m), under one stable dedup key so a long outage notifies about once an
  hour rather than every run. This is the GitHub counterpart to `SlackTriggerHealthCheckJob`.

The heartbeat's bar is *"at least one condition came back clean"*, not *"`perform` returned"*: the
per-condition `rescue` swallows errors so one bad condition can't abort the sweep, which means
`perform` returns normally even in a total outage where nothing was polled. Requiring a real success
is what separates a live poller (some condition worked — a failing one pages on its own) from a
wedged or downed one.

That bar does double duty for the one GitHub failure that is *refused but not an incident*. A search
GitHub reports as `incomplete_results` is never accepted as complete (it would corrupt the label
poller's seen-set), but it is transient: `GithubSearchService` re-runs the search twice, and if it is
still short the poller skips that condition with a WARN instead of paging, because the next tick
re-derives the whole seen-set anyway. A skipped condition does not stamp the heartbeat — so a broad
search-index degradation that hits *every* condition still ages the heartbeat out and pages here,
with no separate alarm needed. A single condition stuck on it pages on its own consecutive-skip
streak (`GithubTriggerPollerJob::CONSECUTIVE_INCOMPLETE_SEARCHES_TO_ALERT`, 5 ticks).

Two placement details are load-bearing, and both are easy to get backwards:

- **The health check tests the `gh` credential only when there is no heartbeat yet.**
  `GithubSearchService.configured?` shells out to `gh auth status`, which is a *live API call*, so a
  GitHub outage makes it return `false`. Guarding the whole check on it would reproduce the original
  silence exactly: the poller stalls, the preflight fails, and nobody is paged. Once a heartbeat
  exists the host has demonstrably polled GitHub, so a stale one is an incident whatever the
  preflight now says — including when polling stopped *because* the credential was revoked. The
  credential only decides whether a host with no baseline (staging) gets seeded.
- **A tick that finds no GitHub triggers still heartbeats.** Otherwise the key rots while there is
  legitimately nothing to poll, and enabling a trigger flips the health check on against that stale
  value — paging for a healthy poller. A tick skipped for a *missing credential* must not stamp,
  though, or an outage would keep the heartbeat artificially fresh.

`GithubTriggerHealthCheckJob` runs on `default`, deliberately not `pollers`: a monitor must not run
on the queue it watches, or the outage it exists to report would starve it into silence too.
`SystemHealthMonitorJob` documents the same rule inverted — it watches `default`, so it runs on
`pollers`.

### What "queue backlog" counts

The backlog is **ready work only** — rows in `good_jobs` that are unfinished, due now, and not yet
claimed by a worker. `HealthMonitorService#queue_statistics` splits the unfinished rows into three
populations, and only the first is waiting on anything:

| Population | Meaning | Backlog? |
| --- | --- | --- |
| `ready_count` | due now, unclaimed — waiting on a worker | **yes** |
| `claimed_count` | `locked_by_id` set — a worker is executing it right now | no |
| `scheduled_count` | `scheduled_at` in the future — wake-up triggers, scheduled polls, retry backoffs, waiting on the clock | no |

`pending_count` is the sum of all unfinished rows and is still reported, but nothing alerts on it.
Alerting on the sum is what made the "Queue backlog critical" page fire four times in three days on
the Tadasant production deployment in August 2026 — the firing on 2026-08-16 counted 106 jobs, of
which 23 were scheduled for later and 15 were mid-execution, leaving 68 actually waiting.

Depth alone is not enough either. Zimmer's workers clear on the order of a thousand jobs an hour, so
a hundred ready jobs is about five minutes of work on a healthy instance and an outage in front of a
wedged one. `critical` therefore requires **both** conditions:

- `ready_count` ≥ `QUEUE_DEPTH_CRITICAL_THRESHOLD` (100), **and**
- `oldest_ready_age_seconds` ≥ `QUEUE_STALL_CRITICAL_AGE` (10 minutes)

A deep queue that is still draining is a `warning`: visible on `/health`, silent in Slack. The two
conditions are ANDed rather than ORed because age alone says nothing about scale — three jobs that
have sat for twenty minutes on an otherwise idle instance is not something to wake anyone for, and
paging on it would rebuild the noise this threshold exists to remove.

The three populations partition `pending_count` exactly: `scheduled_count` counts only *unclaimed*
future-dated rows, so a locked row dated in the future is counted once, as claimed.

`oldest_ready_age_seconds` dates a job from `scheduled_at` when it had one and `created_at`
otherwise, so a wake-up trigger enqueued yesterday starts accruing wait when it comes due rather
than looking like a day-old stall the moment it becomes runnable.

### "N active / M registered" workers

The worker line in the queue-backlog alert (and on `/health`) comes from
`HealthMonitorService#worker_statistics`, which counts a `GoodJob::Process` row as active when its
heartbeat is newer than `HealthMonitorService::WORKER_ACTIVE_INTERVAL` — aliased to GoodJob's own
`GoodJob::Process::EXPIRED_INTERVAL`, 5 minutes.

The same registry answers a different question elsewhere: `JobLiveness` uses
`GoodJob::Process.active` to decide whether the job driving a session is still being executed, which
is what `CleanupOrphanedSessionsJob` above consults before treating a locked job as orphaned. See
[Stale job supersession](/sessions/spawning/#stale-job-supersession).

That has to clear the renew cadence, not match it. A capsule refreshes its row every
`STALE_INTERVAL + jitter` — 30 to 33 seconds — and the refresh is gated on the capsule holding a
lock and runs on the shared 2-thread executor, so it slips further under load. A threshold at or
below the cadence reports a perfectly healthy worker as down a meaningful fraction of the time,
which is what made a real backlog alert read "Workers: 1 active / 2 registered" during the
2026-08-02 incident. `EXPIRED_INTERVAL` is the point at which GoodJob itself gives up: it deletes
the row and releases the jobs it had locked. A worker inactive by this measure is one GoodJob is
about to reap.

## Retry and recovery machinery

| Service | What it handles |
| --- | --- |
| `SigtermRetryService` | Deploys and OOM kills. `MAX_RETRIES = 3` |
| `ApiErrorRetryService` | Vendor API errors; classifies quota vs transient |
| `ContextLengthRetryService` | Context overflow. `MAX_RETRIES = 2` — "after 2 attempts we assume compaction isn't helping" |
| `AuthRecoveryService` | Mid-run auth loss |
| `SessionRecoveryService` | Hung processes. Explicitly "best-effort" |
| `NpxCacheHealService` | A corrupted `_npx` cache — detected by regexing npm's stderr |
| `GlobalRateLimitTracker` | SIGTERM/529 pressure counter driving adaptive backoff |

:::caution[`GlobalRateLimitTracker` is only global with Redis]
Its own header admits the read-modify-write is not atomic, and that with a `memory_store` cache
each worker tracks independently. It needs Redis to be truly global. Zimmer *does* use Redis for the
cache in production — but nothing enforces that, and in development it silently degrades.
:::

## The circuit breaker on the UI

`BroadcastService` wraps Turbo broadcasts in a hand-rolled circuit breaker: `THRESHOLD = 5` failures,
`RESET_TIME = 60` seconds, `MAX_RETRIES = 3`.

When it trips, live UI updates stop for 60 seconds. The session keeps running; you can't see it.

The UI says so while that lasts: a "Live updates paused" banner sits under the network-egress banner
in the layout, on every page. It reports that broadcasts are failing, that your sessions are still
running, and roughly when updates resume.

Two details make it work, and both are load-bearing:

- **It is polled, not broadcast.** `live_updates_status_controller.js` re-fetches
  `GET /live_updates/status` every 15 seconds and swaps the fragment in. Announcing "broadcasting is
  broken" over broadcasting would be self-defeating, and rendering the banner only at page load would
  miss the case the issue is about — a page that freezes while the user sits and watches it.
- **The breaker's state crosses processes through the shared cache.** `@circuit_breaker_opened_at` is
  a class ivar in whichever process broadcast. In production that is the GoodJob worker
  (`execution_mode = :external`), not the web process that renders the page. So opening the breaker
  also writes `broadcast_service:circuit_open_until` to Redis with a 60-second TTL, and
  `BroadcastService.paused_until` reads the cache *and* the local ivar — right under `:external`,
  `:async` and `:inline` alike. A banner wired to the ivar alone would be correct in development and
  never appear in production.

The banner is display only. It does not raise an alert or change the breaker's behavior.

## Alerts

`AlertService` has a `DEDUP_WINDOW = 1.hour` — a genuinely new instance of the same alert inside an
hour is swallowed. `AlertBatcher` truncates aggregated bodies at `MAX_AGGREGATED_DETAILS_CHARS =
2700`.

### The log snippet

Pass the rescued exception as `error:` and the alert carries an excerpt of the real failure into
Slack, rendered as a fenced code block:

```ruby
AlertService.raise_alert(
  "Slack trigger poller error",
  details: "Condition 42 on trigger 'anomaly-review' (ID: 7) failed.",
  source: "SlackTriggerPollerJob",
  dedup_key: "slack_trigger_condition_42",
  error: e
)
```

`AlertSnippet` builds it. `details:` is for the prose a human needs on top of the failure — not for
a hand-copied `e.message`, which carries strictly less than the backtrace sitting right there at the
rescue site. A raw log or stderr blob works too (`error: stored["detail"]`).

What it does with the exception:

- **Keeps the frames worth reading.** The first `APP_FRAME_LIMIT` (8) app-owned frames, plus the top
  `TOP_FRAME_LIMIT` (2) frames — usually vendored, and where the raise actually happened. Everything
  skipped is marked (`… 6 frames elided …`) so nothing looks complete when it isn't. Rails root is
  stripped from paths.
- **Follows the cause chain**, up to `CAUSE_LIMIT` (2) — an adapter error wrapping a connection
  error is frequently the whole story.
- **Bounds the result** at `MAX_CHARS` (1200), well inside Slack's 3000-character section limit. A
  blob that overruns keeps its head *and* its tail, with the elided character count between them —
  the end of a log is often where the failure is.
- **Redacts secret shapes** — Slack (bot and app-level), GitHub, Anthropic, OpenAI and Google keys,
  AWS key ids, JWTs, PEM private-key blocks, `Authorization` headers, URL passwords, and
  `token=`/`secret=` assignments — before anything is posted.
- **Never raises.** Raw stderr can end mid-multibyte-character (`BoundedSubprocess` kills the process
  group on deadline), and `raise_alert` wraps everything in a blanket rescue — so a snippet that
  raised would not degrade the alert, it would delete it. Input is scrubbed to valid UTF-8, and a
  render that fails anyway degrades to `(log snippet unavailable: <class>)`.

Inside an `AlertBatcher` aggregate the occurrence list wins over the snippets. Each occurrence gets
`MAX_AGGREGATED_DETAILS_CHARS / N` minus a reserve for its own prose, capped at `MAX_BATCHED_CHARS`
(500); past roughly fifteen occurrences the share is worth less than the line it would displace and
snippets drop out entirely. Naming *which* triggers were affected is the reason the batcher exists,
so a snippet must never push the tail of that list off the end of a truncated message.

The snippet reaches the `text:` field as well as the blocks, because block-blind consumers (push
notifications, the `slack-workspace` MCP server) only ever see `text:`. When both must be trimmed,
the prose is trimmed and the snippet is kept whole.

:::caution[Snippets must never reach a dedup key]
Snippet content varies per occurrence — line numbers, timestamps, object addresses. The dedup key is
derived from title + source only (and, for an aggregate, from the set of per-event dedup keys). If
snippet text leaked into either, the hourly throttle would stop throttling and one wedged poller
would fill `#eng-alerts` once per tick.
:::

### Who is allowed to page

**`AlertService::ALERTING_ENVIRONMENTS` is `production` and `staging`.** Zimmer's two deployed
environments page; a process running as anything else does not, however completely it is credentialed
— the same boundary `config/initializers/sentry.rb` draws for the production error DSN. The check
happens twice: at `raise_alert`, so a gated alert is never accumulated into an `AlertBatcher` flush
that would drop it, and at `post_to_slack`, the one place every path into Slack passes through
(`AlertBatcher`'s flush calls `emit` directly and never sees the first check). Either way the caller
gets `false`, and the alert is logged at `warn` with its title, source, environment, and a truncated
body — so a developer exercising alerting sees what would have been sent and why it wasn't, rather
than silence.

`ALERTS_ENABLED` overrides in both directions: `true` on an instance that should page anyway, `false`
to mute one that otherwise would. Anything unrecognized is treated as unset — garbage must not read as
*yes, page production*. Set it as deploy environment configuration, never in `mcp_secrets`: secret-store
values are copied into every agent clone's `.env`, so an opt-in stored there would travel with the
clones. `CliSpawnEnv#clear_inherited_env_vars` strips it from spawned agents for the same reason, so
the opt-in stays with the instance it was declared on.

The gate reads the environment and nothing else — deliberately not the dedup cache, which is
best-effort by construction. `suppressed?` and `mark_sent` swallow their own failures, as does
`ElicitationEndpoint.record`; when the cache is unreachable, every suppressor falls open at once and
one incident becomes a message per tick. A throttle that fails open is not a containment boundary. See
[the credential-scope limitation](/limitations/#every-agent-session-clone-carries-the-slack-bot-token-and-the-alert-channel-id)
for the part of this that a code change cannot close.

Every message is tagged with its environment — header, context block, and the `text:` fallback —
production included, so that a channel of tagged messages has no ambiguous member. Tagging only the
non-production ones would make an untagged message mean either "from production" or "from a build that
predates the tag". The tag is applied at render time, so dedup keys and `AlertBatcher`'s
`(title, source)` grouping stay keyed on the alert itself.

### When an alert is a DM instead of a channel post

`AlertService.dm_operator` sends to one person rather than to `#eng-alerts`. It shares the
environment gate, the Block Kit rendering and the cache-backed suppression with `raise_alert` — what
differs is the destination (`OPERATOR_SLACK_USER_ID`, opened with `conversations.open`, which needs
the bot's `im:write` scope) and the clock.

Reach for it only where a channel post would be the wrong shape: a condition that stays broken until
one specific human acts, that no amount of retrying will clear. Today that is exactly one caller —
[an account falling into `needs_reauth`](/auth/harness/#a-dead-account-tells-you-so). A channel alert
is a feed entry you scroll past; a DM is a nag, and nags spend attention.

Two consequences of being a nag:

- **A much longer window.** `OPERATOR_DM_DEDUP_WINDOW` is 12 hours against `DEDUP_WINDOW`'s 1, and
  the dedup key is caller-owned and required rather than derived from title + source — so two dead
  accounts are two DMs, not one collapsed one. The caller may call `clear_dm_suppression` when the
  condition resolves so a recurrence is not swallowed by the suppression its first occurrence wrote
  — but it should clear on the *narrowest* signal that the problem is actually fixed, not on any
  signal that it currently looks fixed. See
  [the needs_reauth case](/auth/harness/#a-dead-account-tells-you-so) for why clearing too eagerly
  turns the throttle into a flood.
- **No `AlertBatcher`.** The batcher collapses same-thread bursts of the same alert, which is a
  channel concern. A DM is already throttled per subject.

Unset `OPERATOR_SLACK_USER_ID` means the DM is logged and dropped, exactly like an unconfigured
channel. And `dm_operator` swallows every error it can raise and returns `false` — its callers are
auth and status-transition paths whose job is to keep the account pool running, and a Slack outage
must not strand one of them.

### Why the elicitation probe doesn't run in development

`ElicitationEndpointHealthCheckJob` is registered in `production.rb` and `staging.rb`, not
`development.rb`. Locally `AppUrl.base_url` falls back to `http://localhost:PORT` (unless you set
`ZIMMER_LOCAL_BASE_URL`), so the probe measures whether this particular process also happens to be
serving HTTP — a console, a bare worker, or a test harness fails it on every tick, forever. And the
recorded `unreachable` status is what `OrchestratorSystemPromptBuilder` reads, so every locally
spawned agent would be told the approval gate is down when it isn't. Never-probed reads as healthy,
which is the honest default here; run `ElicitationEndpointHealthCheckJob.new.perform` by hand to
exercise it.
