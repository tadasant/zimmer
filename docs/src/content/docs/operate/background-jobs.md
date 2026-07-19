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
| 30s | `GitHubPullRequestPollerJob` | Poll CI status on sessions with a PR URL |
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
| 5m | `CleanupRuntimeLoginAttemptsJob` | Reap abandoned login attempts |
| 10m | `TranscriptArchiveJob` | Rebuild `latest.zip` |
| 15m | `CatalogRefreshJob` | `air update` + reload the catalog |
| 15m | `QuotaResetCheckerJob` | Restore `quota_exceeded` Claude accounts |
| 15m | `RefreshXOauthTokensJob` | Refresh X/Twitter tokens |
| 30m | `RefreshMcpOauthTokensJob` | Refresh MCP OAuth tokens expiring within the hour |
| hourly | `StaleCloneCleanupJob` | Reap clones from archived sessions |
| hourly :45 | `SlackTriggerHealthCheckJob` | Detect Slack feeds that silently stopped firing |
| — | `ZombieReaperJob`, `DeferredCloneCleanupJob`, `EmptyTrashJob`, `DockerCleanupJob`, `OrphanCloneFilesystemCleanupJob`, `SystemHealthMonitorJob`, `CertExpiryMonitorJob`, `EgressHealthCheckJob` | cleanup and monitoring |

:::note[Sub-minute cron: the config contradicts itself]
The `*/30 * * * * *` entries are six-field cron (with seconds), which fugit supports. But
`SlackTriggerPollerJob`'s own comment says *"GoodJob/fugit doesn't support seconds"* and settles for a
one-minute cron. Both forms are in the same config file. One of those two comments is wrong; the
six-field entries suggest it's the Slack one.
Tracked in [#106](https://github.com/tadasant/zimmer/issues/106).
:::

## Queues

Most jobs run on `default`. Two are deliberately isolated:

- **`:triggers`** — `AoEventTriggerJob` and `ScheduleTriggerJob`. They were previously starved on
  `default`; `AoEventTriggerJob::DISPATCH_LATENCY_WARN_THRESHOLD = 120s` exists because of it.
- **`:pollers`** with `total_limit: 1` — `SlackTriggerPollerJob` and `GithubTriggerPollerJob`.
  `SlackService` retries up to 10 times with a blocking 1-second `sleep` inside the job thread, and
  the comment admits this would "saturate the queue's whole thread pool." `GithubTriggerPollerJob`
  is capped for the same reason: it shells out to `gh` once per condition, and a slow tick must not
  stack against itself. Its polling is idempotent — state only advances for items that produced a
  session — so a skipped tick is simply picked up by the next run.

:::caution[A Slack rate-limit episode stalls all Slack polling]
`total_limit: 1` caps the blast radius, but it also means no Slack polling at all while you're
throttled — and ticks are silently dropped.
:::

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

When it trips, live UI updates stop for 60 seconds. The session keeps running; you can't
see it. There's no banner telling you the breaker is open.
Tracked in [#86](https://github.com/tadasant/zimmer/issues/86).

## Alerts

`AlertService` has a `DEDUP_WINDOW = 1.hour` — a genuinely new instance of the same alert inside an
hour is swallowed. `AlertBatcher` truncates aggregated bodies at `MAX_AGGREGATED_DETAILS_CHARS =
2700`.
