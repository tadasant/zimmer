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
| 2m | `GitHubMergeConflictPollerJob` | Detect merge conflicts on open PRs |
| 2m | `CliStatusRefreshJob` | Refresh the `gh` / `claude` / `codex` version cache |
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
- **`:pollers`** with `total_limit: 1` — `SlackTriggerPollerJob`. `SlackService` retries up to 10 times
  with a blocking 1-second `sleep` inside the job thread, and the comment admits this would
  "saturate the queue's whole thread pool."

:::caution[A Slack rate-limit episode stalls all Slack polling]
`total_limit: 1` caps the blast radius, but it also means no Slack polling at all while you're
throttled — and ticks are silently dropped.
:::

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
