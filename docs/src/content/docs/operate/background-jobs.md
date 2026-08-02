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
| 1m | `ScheduleTriggerJob` | Fire due schedule triggers |
| 1m | `GithubTriggerPollerJob` | Poll GitHub for label-added and new-issue trigger conditions |
| 2m | `GitHubMergeConflictPollerJob` | Detect merge conflicts on open PRs |
| 2m | `CliStatusRefreshJob` | Refresh the `gh` / `claude` / `codex` version cache |
| 5m | `GithubTriggerHealthCheckJob` | Alert when GitHub trigger polling has silently stopped succeeding |
| 5m | `CleanupOrphanedSessionsJob` | Sessions marked `running` whose process is gone |
| 5m | `RefreshRuntimeAuthTokensJob` | Refresh Anthropic/OpenAI OAuth tokens |
| 5m | `CleanupExpiredElicitationsJob` | Expire elicitations + clear stranded blocks |
| 5m | `ElicitationEndpointHealthCheckJob` | Alert when MCP servers cannot reach the approval endpoint (production and staging only — see below) |
| 5m | `CleanupRuntimeLoginAttemptsJob` | Reap abandoned login attempts |
| 10m | `TranscriptArchiveJob` | Rebuild `latest.zip` |
| 15m | `CatalogRefreshJob` | `air update` + reload the catalog |
| 15m | `QuotaResetCheckerJob` | Restore `quota_exceeded` Claude accounts, then resume the sessions parked on them |
| 15m | `RefreshXOauthTokensJob` | Refresh X/Twitter tokens |
| 30m | `RefreshMcpOauthTokensJob` | Refresh MCP OAuth tokens expiring within the hour |
| hourly | `StaleCloneCleanupJob` | Reap clones from archived sessions |
| hourly :45 | `SlackTriggerHealthCheckJob` | Detect Slack feeds that silently stopped firing |
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
- **`:pollers`** with `total_limit: 1` — `SlackTriggerPollerJob` and `GithubTriggerPollerJob`.
  Both make slow external calls once per condition, and a slow tick must not stack against itself.
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
deferring and raises an alert.

A transient failure deep in the sweep does not abort it. Each unit — channel, thread, DM — owns a
cursor that only advances for units that finished, and those writes are batched at the end, so
unwinding mid-sweep would skip them and replay finished units as duplicate sessions. The unit
rescues record the failure instead, the sweep completes its bookkeeping, and the deferral happens
once at the end.

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

### Why the elicitation probe doesn't run in development

`ElicitationEndpointHealthCheckJob` is registered in `production.rb` and `staging.rb`, not
`development.rb`. Locally `AppUrl.base_url` falls back to `http://localhost:PORT` (unless you set
`ZIMMER_LOCAL_BASE_URL`), so the probe measures whether this particular process also happens to be
serving HTTP — a console, a bare worker, or a test harness fails it on every tick, forever. And the
recorded `unreachable` status is what `OrchestratorSystemPromptBuilder` reads, so every locally
spawned agent would be told the approval gate is down when it isn't. Never-probed reads as healthy,
which is the honest default here; run `ElicitationEndpointHealthCheckJob.new.perform` by hand to
exercise it.
