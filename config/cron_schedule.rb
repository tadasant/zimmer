# frozen_string_literal: true

# The GoodJob cron table: every scheduled job, and the environments each one runs in.
#
# WHY IT LIVES HERE
# -----------------
# A cron entry that is absent does not error, does not log and does not alert -- the job
# simply never runs. `SlackTriggerHealthCheckJob`'s own header explains that it exists
# because a Slack feed "went dark for days" before anyone noticed; a schedule that can
# lose an entry without saying so is the same failure one level up, and a schedule kept
# in three copies is how an entry gets lost.
#
# So there is one table, and an environment that skips a job says so in a `%i[...]` list
# a reviewer can disagree with rather than by an absence nobody diffs.
# `test/config/cron_schedule_test.rb` pins the resolved hash for every environment
# against `test/fixtures/files/good_job_cron_schedule.json`.
#
# LOAD ORDER
# ----------
# `config/environments/*.rb` reads this during `Rails.application.initialize!`, before
# autoload paths are configured, so nothing here can be autoloaded. `config/application.rb`
# requires it explicitly, the same way it requires `config/connection_budget.rb`. Keep it
# plain Ruby with no Rails dependencies.
#
# ADDING A JOB
# ------------
# 1. Add an entry below with the environments it should run in.
# 2. Regenerate `test/fixtures/files/good_job_cron_schedule.json` and read the diff. That
#    file pins the resolved hash per environment, so a new job, a changed cadence or a
#    dropped entry shows up as a failing test rather than as silence. The command is in
#    `docs/src/content/docs/operate/background-jobs.md`.
# 3. Add a row to the table in that same page. The test asserts every scheduled class
#    appears there.
module CronSchedule
  module_function

  # The environments that have a cron schedule. `test` has none: the suite does not run
  # GoodJob's cron, and a scheduled sweep firing mid-test would be a source of flakes.
  ENVIRONMENTS = %i[production staging development].freeze

  # The keys `for` hands to GoodJob. `GoodJob::CronEntry` reads more than these -- `set`,
  # `args`, `kwargs`, `enabled_by_default` -- so an entry needing one of those has to be
  # added here AND to `for`. Writing it on an entry alone would be silently discarded,
  # which is why `validate!` rejects any key it does not recognise.
  GOOD_JOB_KEYS = %i[cron class description].freeze

  # Every key an entry may carry. Anything else is a typo, or a GoodJob option `for`
  # would drop on the floor.
  ENTRY_KEYS = (GOOD_JOB_KEYS + %i[environments cron_overrides]).freeze

  # Every entry:
  #
  #   cron:            the schedule. Five-field, or six-field for seconds resolution --
  #                    fugit reads the leading seconds field and GoodJob hands straight
  #                    through to it, so "*/30 * * * * *" really does fire twice a minute.
  #   class:           the ActiveJob class name.
  #   description:     what shows up in the GoodJob dashboard.
  #   environments:    which environments schedule it. Not optional: a job that runs
  #                    everywhere still has to say so.
  #   cron_overrides:  optional, `{ environment => cron }` for an entry that runs on a
  #                    different cadence somewhere. No entry needs one; it is the seam
  #                    tadasant/zimmer#457 asked for, so that an environment-specific
  #                    cadence is a written difference rather than a reason to fork the
  #                    table again.
  #
  # Development runs a deliberate subset: nothing that spends money or quota, and nothing
  # that reaps the deployed droplet's disk. Paging is not what decides it --
  # AlertService::ALERTING_ENVIRONMENTS is production and staging, so a monitor scheduled
  # in development cannot reach #eng-alerts. Where the reason for an omission is more
  # specific than that, it is written on the entry.
  ENTRIES = {
    outcome_analysis_batch_pump: {
      cron: "* * * * *", # Every minute — the engine behind "Analyze All" concurrency
      class: "OutcomeAnalysisBatchPumpJob",
      description: "Advance every running Outcomes Analyze All batch: reconcile in-flight analyses, spawn the next wave",
      environments: %i[production staging development]
    },
    cleanup_orphaned_sessions: {
      cron: "*/5 * * * *", # Every 5 minutes
      class: "CleanupOrphanedSessionsJob",
      description: "Cleanup orphaned sessions every 5 minutes",
      environments: %i[production staging development]
    },
    heartbeat_sweep: {
      cron: "*/30 * * * * *", # Every 30 seconds
      class: "HeartbeatSweepJob",
      description: "Beat per-session heartbeats: nudge needs_input sessions due for a beat",
      environments: %i[production staging development]
    },
    github_pull_request_poller: {
      cron: "*/30 * * * * *", # Every 30 seconds
      class: "GitHubPullRequestPollerJob",
      description: "Poll GitHub PR status for sessions with PR URLs",
      environments: %i[production staging development]
    },
    stale_clone_cleanup: {
      cron: "0 * * * *", # Every hour at minute 0
      class: "StaleCloneCleanupJob",
      description: "Clean up stale clone directories from archived sessions",
      environments: %i[production staging development]
    },
    # Not in development, deliberately: locally the endpoint it probes is
    # http://localhost:PORT, so the probe measures whether this process happens to also be
    # serving HTTP -- a console, a bare worker or a test harness fails it on every tick
    # forever. Worse than the noise: the recorded "unreachable" status is what
    # OrchestratorSystemPromptBuilder reads, so every locally spawned agent gets told the
    # approval gate is down when it isn't. Unprobed reads as healthy, which is the honest
    # default here. Run it by hand (`ElicitationEndpointHealthCheckJob.new.perform`).
    elicitation_endpoint_health_check: {
      cron: "*/5 * * * *", # Every 5 minutes
      class: "ElicitationEndpointHealthCheckJob",
      description: "Probe the MCP approval (elicitation) endpoint agents are pointed at",
      environments: %i[production staging]
    },
    github_comment_poller: {
      cron: "*/30 * * * * *", # Every 30 seconds
      class: "GithubCommentPollerJob",
      description: "Poll GitHub PR comments for sessions with PR URLs",
      environments: %i[production staging development]
    },
    github_merge_conflict_poller: {
      cron: "*/2 * * * *", # Every 2 minutes (merge conflicts are less time-sensitive than CI status)
      class: "GitHubMergeConflictPollerJob",
      description: "Poll GitHub PRs for merge conflicts and notify sessions",
      environments: %i[production staging development]
    },
    token_usage_ingestion: {
      cron: "*/10 * * * *", # Every 10 minutes
      class: "TokenUsageIngestionJob",
      description: "Sweep recent transcripts into the token-spend ledger",
      environments: %i[production staging]
    },
    token_usage_backfill: {
      cron: "*/5 * * * *", # Every 5 minutes; a no-op once history has been swept
      class: "TokenUsageBackfillJob",
      description: "Sweep the whole transcript corpus into the ledger once, a slice at a time, so history needs no shell on the box",
      environments: %i[production staging]
    },
    # Every two minutes rather than every minute: the steady state is one indexed
    # lookup per task file, but a task that yields for a slice should be handed
    # back promptly, and 2 minutes against a 90-second slice budget is the
    # cadence that keeps a long sliced task moving without ever overlapping.
    post_deploy_tasks: {
      cron: "*/2 * * * *",
      class: "PostDeployTaskJob",
      description: "Run the one-time post-deploy tasks in db/post_deploy, so an ops step ships with the deploy instead of needing a shell",
      environments: %i[production staging development]
    },
    experimental_flag_backfill: {
      cron: "*/15 * * * *", # Every 15 minutes; an indexed anti-join that writes nothing once history is labelled
      class: "ExperimentalFlagBackfillJob",
      description: "Label pre-tracking sessions with what each experimental setting was, so the Costs experiment report has history",
      environments: %i[production staging development]
    },
    cli_status_refresh: {
      cron: "*/2 * * * *", # Every 2 minutes
      class: "CliStatusRefreshJob",
      description: "Refresh CLI tool status cache (gh, claude, fly)",
      environments: %i[production staging development]
    },
    catalog_refresh: {
      cron: "*/15 * * * *", # Every 15 minutes
      class: "CatalogRefreshJob",
      description: "Refresh catalog repo (skills, servers, agent roots) from tadasant/zimmer-catalog",
      environments: %i[production staging development]
    },
    queue_recovery_mode_expiry: {
      cron: "* * * * *", # Every minute
      class: "QueueRecoveryModeExpiryJob",
      description: "Lift queue recovery mode once its TTL has elapsed (runs on `agents`, the queue recovery mode never pauses)",
      environments: %i[production staging development]
    },
    slack_trigger_poller: {
      # Every minute. GoodJob/fugit do support second-granularity cron — the six-field
      # "*/30 * * * * *" entries above really do fire every 30s — so this cadence is a
      # deliberate choice for Slack polling, not a platform limit.
      cron: "* * * * *",
      class: "SlackTriggerPollerJob",
      description: "Poll Slack channels for triggers and create sessions",
      environments: %i[production staging development]
    },
    github_trigger_poller: {
      cron: "* * * * *", # Every minute — one search request per condition, against a 30/min budget
      class: "GithubTriggerPollerJob",
      description: "Poll GitHub for label-added and new-issue trigger conditions and create sessions",
      environments: %i[production staging]
    },
    # Staging does not run this; production and development do. The reason on record
    # (test/config/cron_schedule_test.rb's NOT_ON_STAGING) is that it is an alerting
    # canary and a staging copy would double-page on production's own signals. That reason
    # came with the schedule rather than from a decision, and it is only about staging:
    # AlertService::ALERTING_ENVIRONMENTS excludes development, so the development copy
    # cannot page anything. Staging can, so whether staging should run it is a real and
    # open question -- tadasant/zimmer#686.
    slack_trigger_health_check: {
      cron: "45 * * * *", # Every hour at minute 45 (offset from other hourly jobs)
      class: "SlackTriggerHealthCheckJob",
      description: "Detect Slack trigger feeds that have silently stopped firing and alert",
      environments: %i[production development]
    },
    github_trigger_health_check: {
      cron: "*/5 * * * *", # Every 5 minutes — catches a silent poller freeze within ~15-20 min
      class: "GithubTriggerHealthCheckJob",
      description: "Alert #eng-alerts when GitHub trigger polling has silently stopped succeeding",
      environments: %i[production staging]
    },
    schedule_trigger: {
      cron: "* * * * *", # Every minute
      class: "ScheduleTriggerJob",
      description: "Check schedule triggers and create sessions when due",
      environments: %i[production staging development]
    },
    refresh_mcp_oauth_tokens: {
      cron: "*/30 * * * *", # Every 30 minutes
      class: "RefreshMcpOauthTokensJob",
      description: "Proactively refresh MCP OAuth tokens before they expire",
      environments: %i[production staging development]
    },
    refresh_x_oauth_tokens: {
      cron: "*/15 * * * *", # Every 15 minutes (X access tokens live ~2h)
      class: "RefreshXOauthTokensJob",
      description: "Proactively refresh X (Twitter) OAuth access tokens before they expire",
      environments: %i[production staging development]
    },
    transcript_archive: {
      cron: "*/10 * * * *", # Every 10 minutes
      class: "TranscriptArchiveJob",
      description: "Incrementally build/update transcript archive zip file",
      environments: %i[production staging development]
    },
    warm_skills_cache: {
      cron: "0 */4 * * *", # Every 4 hours
      class: "WarmSkillsCacheJob",
      description: "Warm the Claude skills cache for follow-up prompt slash command typeahead",
      environments: %i[production staging development]
    },
    cleanup_expired_elicitations: {
      cron: "*/5 * * * *", # Every 5 minutes
      class: "CleanupExpiredElicitationsJob",
      description: "Expire pending elicitations past their expiration time",
      environments: %i[production staging development]
    },
    cleanup_runtime_login_attempts: {
      cron: "*/5 * * * *", # Every 5 minutes
      class: "CleanupRuntimeLoginAttemptsJob",
      description: "Reap orphaned UI login attempts and prune old terminal rows",
      environments: %i[production staging]
    },
    empty_trash: {
      cron: "0 * * * *", # Every hour
      class: "EmptyTrashJob",
      description: "Permanently delete clones for trashed sessions past retention period",
      environments: %i[production staging development]
    },
    claude_code_update: {
      cron: "0 6 * * *", # Daily at 6:00 AM UTC
      class: "ClaudeCodeUpdateJob",
      description: "Update Claude Code CLI to the latest version",
      environments: %i[production staging development]
    },
    status_summary_backstop: {
      cron: "*/5 * * * *", # Every 5 minutes, capped at 5 sessions a sweep
      class: "StatusSummaryBackstopJob",
      description: "Re-run a status-summary generation that never landed, for sessions already at rest",
      environments: %i[production staging]
    },
    quota_reset_checker: {
      cron: "*/15 * * * *", # Every 15 minutes
      class: "QuotaResetCheckerJob",
      description: "Check if quota-exceeded accounts have reset and restore them to active",
      environments: %i[production staging]
    },
    fleet_idle_checker: {
      cron: "* * * * *", # Every minute — the resolution of FleetIdleMonitor::IDLE_THRESHOLD
      class: "FleetIdleCheckerJob",
      description: "Fire the no_sessions_in_progress event once the fleet has had nothing to do for 5 minutes",
      environments: %i[production staging]
    },
    spot_ceiling_sweep: {
      cron: "*/5 * * * *", # Every 5 minutes — quota readings land every 15, so this is not the bound
      class: "SpotCeilingSweepJob",
      description: "Pause running spot sessions when a quota window reaches its target, and resume them when it falls",
      environments: %i[production staging]
    },
    spot_hold_sweep: {
      cron: "*/5 * * * *", # Every 5 minutes; SpotSessionHold::OVERDUE_GRACE is what bounds staleness
      class: "SpotHoldSweepJob",
      description: "Put held spot sessions back on the re-check ladder when their re-check never fired",
      environments: %i[production staging]
    },
    # Not in development, on the same rule as the two spot sweeps beside it: the
    # repair is to START a session, which spends quota. A developer's database is
    # full of `waiting` rows left over from testing, and a sweep that woke all of
    # them at once would be a surprising way to spend an afternoon's tokens.
    stalled_start_sweep: {
      cron: "*/5 * * * *", # Every 5 minutes; StalledSessionStart::GRACE is what bounds staleness
      class: "StalledStartSweepJob",
      description: "Re-enqueue the first turn of a session that has been waiting to start with no job behind it",
      environments: %i[production staging]
    },
    burn_rate_recompute: {
      cron: "*/20 * * * *", # Every 20 minutes — the ledger only lands every 10, so this is not the bound
      class: "BurnRateRecomputeJob",
      description: "Recompute the $/min burn rate of every harness+model combination from the token ledger",
      environments: %i[production staging]
    },
    quota_capacity_calibration: {
      cron: "*/15 * * * *", # Every 15 minutes, matching the cadence quota snapshots land at
      class: "QuotaCapacityCalibrationJob",
      description: "Re-estimate what each Claude quota window is worth in Opus dollars, from spend over that window",
      environments: %i[production staging]
    },
    claude_usage_sampler: {
      cron: "*/15 * * * *", # Every 15 minutes
      class: "ClaudeUsageSamplerJob",
      description: "Sample the serving Claude account's quota so the per-session usage rate has a time series",
      environments: %i[production staging]
    },
    refresh_runtime_auth_tokens: {
      cron: "*/5 * * * *", # Every 5 minutes (min rotation_interval across runtimes)
      class: "RefreshRuntimeAuthTokensJob",
      description: "Proactively refresh runtime login-credential tokens before they expire (fans out per runtime)",
      environments: %i[production staging development]
    },
    docker_cleanup: {
      cron: "0 */6 * * *", # Every 6 hours
      class: "DockerCleanupJob",
      description: "Clean up stale dev-server containers, prune old Docker images, and handle emergency disk situations",
      environments: %i[production staging]
    },
    orphan_clone_filesystem_cleanup: {
      cron: "30 */6 * * *", # Every 6 hours, offset from docker_cleanup
      class: "OrphanCloneFilesystemCleanupJob",
      description: "Remove clone directories on disk with no matching session in the database",
      environments: %i[production staging]
    },
    cleanup_stale_triggers: {
      cron: "15 * * * *", # Every hour at minute 15 (offset from other hourly jobs)
      class: "CleanupStaleTriggersJob",
      description: "Destroy dead one-time wake-up triggers (archived target session, consumed-without-firing wake, or lapsed schedule)",
      environments: %i[production staging development]
    },
    zombie_reaper: {
      cron: "*/5 * * * *", # Every 5 minutes
      class: "ZombieReaperJob",
      description: "Reap zombie subprocesses left by agent sessions (defense in depth alongside tini init shim)",
      environments: %i[production staging development]
    },
    cert_expiry_monitor: {
      cron: "0 7 * * *", # Daily at 07:00 UTC (offset from claude_code_update at 06:00)
      class: "CertExpiryMonitorJob",
      description: "Check public TLS certs (ao/obs hosts) and alert when expiry nears — catches broken auto-renewal",
      environments: %i[production staging]
    },
    system_health_monitor: {
      cron: "*/2 * * * *", # Every 2 minutes
      class: "SystemHealthMonitorJob",
      description: "Alert #eng-alerts when the GoodJob queue backlog is critical (sustained across checks)",
      environments: %i[production staging development]
    },
    # Development is deliberate: a real per-minute outbound DNS probe on a developer's
    # laptop (VPN, captive portal, offline) would waste I/O and flash a false "network
    # egress degraded" banner locally.
    #
    # Staging is the open question, on the same footing as slack_trigger_health_check
    # above -- tadasant/zimmer#686.
    egress_health_check: {
      cron: "* * * * *", # Every minute
      class: "EgressHealthCheckJob",
      description: "Probe the primary DNS resolver's public egress; drive the network-degraded banner",
      environments: %i[production]
    },
    mangled_clone_report: {
      cron: "0 8 * * *", # Daily at 08:00 UTC (offset from cert_expiry_monitor at 07:00)
      class: "MangledCloneReportJob",
      description: "Report how many mangled clones the archive-side mass-deletion guard defused in the last day",
      environments: %i[production staging]
    }
  }.freeze

  # The schedule GoodJob should run in `environment`, in exactly the shape it expects:
  # `{ name => { cron:, class:, description: } }`.
  #
  # `entries` is a seam for the tests, which exercise the resolver against a table of
  # three entries rather than against the forty-odd real ones. Nothing else passes it.
  def for(environment, entries = ENTRIES)
    environment = environment.to_sym
    unless ENVIRONMENTS.include?(environment)
      raise ArgumentError, "#{environment.inspect} has no cron schedule (known: #{ENVIRONMENTS.join(', ')})"
    end

    entries.each_with_object({}) do |(name, entry), schedule|
      next unless entry[:environments].include?(environment)

      schedule[name] = {
        cron: entry.dig(:cron_overrides, environment) || entry[:cron],
        class: entry[:class],
        description: entry[:description]
      }
    end
  end

  # Run at load, so a malformed table fails the boot it would otherwise pass silently.
  # An entry that names an environment nobody schedules, an override for an environment
  # the entry does not run in, or a key `for` would quietly drop is a job that does not
  # run as written -- the exact failure this file exists to make loud.
  def validate!(entries = ENTRIES)
    entries.each do |name, entry|
      GOOD_JOB_KEYS.each do |key|
        raise "cron entry #{name.inspect} is missing #{key.inspect}" if entry[key].nil?
      end

      stray = entry.keys - ENTRY_KEYS
      if stray.any?
        raise "cron entry #{name.inspect} carries keys nothing reads: #{stray.inspect}. " \
              "A misspelled key, or a GoodJob option (set/args/kwargs/enabled_by_default) " \
              "that `for` would discard -- teach `for` about it rather than writing it here"
      end

      environments = entry[:environments]
      raise "cron entry #{name.inspect} declares no environments" if environments.nil? || environments.empty?

      unknown = environments - ENVIRONMENTS
      raise "cron entry #{name.inspect} names unknown environments: #{unknown.inspect}" if unknown.any?

      undeclared = (entry[:cron_overrides]&.keys || []) - environments
      if undeclared.any?
        raise "cron entry #{name.inspect} overrides the schedule for #{undeclared.inspect}, " \
              "which it does not run in"
      end
    end
  end

  validate!
end
