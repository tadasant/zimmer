require "active_support/core_ext/integer/time"

# Set Redis URL for development
ENV["REDIS_URL"] ||= "redis://localhost:6379"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # In development, use the in-repo air.json so local edits are picked up without
  # needing a ~/.air/air.json file.
  config.air_json_path = Rails.root.join("air.json").expand_path.to_s

  # Make code changes take effect immediately without server restart.
  config.enable_reloading = true

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full error reports.
  config.consider_all_requests_local = true

  # Enable server timing.
  config.server_timing = true

  # Enable/disable Action Controller caching. By default Action Controller caching is disabled.
  # Run rails dev:cache to toggle Action Controller caching.
  if Rails.root.join("tmp/caching-dev.txt").exist?
    config.public_file_server.headers = { "cache-control" => "public, max-age=#{2.days.to_i}" }
  else
    config.action_controller.perform_caching = false
  end

  # Use Redis cache store in development (database 1 to avoid conflict with other apps)
  config.cache_store = :redis_cache_store, { url: "#{ENV["REDIS_URL"]}/1" }

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Don't care if the mailer can't send.
  config.action_mailer.raise_delivery_errors = false

  # Make template changes take effect immediately.
  config.action_mailer.perform_caching = false

  # Set localhost to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "localhost", port: 3000 }

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = true

  # Append comments with runtime information tags to SQL queries in logs.
  config.active_record.query_log_tags_enabled = true

  # Highlight code that enqueued background job in logs.
  config.active_job.verbose_enqueue_logs = true

  # GoodJob configuration for development
  # Use :async mode for development - runs jobs in separate threads within the Rails process
  config.good_job.execution_mode = :async

  # Queue configuration matching production for dev/prod parity (configurable via ENV):
  # - agents: Long-running AgentSessionJob instances
  # - pollers: Singleton polling jobs
  # - default: Everything else
  agents_threads = ENV.fetch("GOOD_JOB_AGENTS_THREADS", 16).to_i
  pollers_threads = ENV.fetch("GOOD_JOB_POLLERS_THREADS", 3).to_i
  default_threads = ENV.fetch("GOOD_JOB_DEFAULT_THREADS", 4).to_i
  config.good_job.queues = "agents:#{agents_threads};pollers:#{pollers_threads};default:#{default_threads}"
  config.good_job.max_threads = ENV.fetch("GOOD_JOB_MAX_THREADS", 24).to_i
  config.good_job.poll_interval = 5
  config.good_job.enable_cron = true
  config.good_job.cron = {
    cleanup_orphaned_sessions: {
      cron: "*/5 * * * *", # Every 5 minutes
      class: "CleanupOrphanedSessionsJob",
      description: "Cleanup orphaned sessions every 5 minutes"
    },
    github_pull_request_poller: {
      cron: "*/30 * * * * *", # Every 30 seconds
      class: "GitHubPullRequestPollerJob",
      description: "Poll GitHub PR status for sessions with PR URLs"
    },
    stale_clone_cleanup: {
      cron: "0 * * * *", # Every hour at minute 0
      class: "StaleCloneCleanupJob",
      description: "Clean up stale clone directories from archived sessions"
    },
    github_comment_poller: {
      cron: "*/30 * * * * *", # Every 30 seconds
      class: "GithubCommentPollerJob",
      description: "Poll GitHub PR comments for sessions with PR URLs"
    },
    github_merge_conflict_poller: {
      cron: "*/2 * * * *", # Every 2 minutes (merge conflicts are less time-sensitive than CI status)
      class: "GitHubMergeConflictPollerJob",
      description: "Poll GitHub PRs for merge conflicts and notify sessions"
    },
    cli_status_refresh: {
      cron: "*/2 * * * *", # Every 2 minutes
      class: "CliStatusRefreshJob",
      description: "Refresh CLI tool status cache (gh, claude, fly)"
    },
    catalog_refresh: {
      cron: "*/15 * * * *", # Every 15 minutes
      class: "CatalogRefreshJob",
      description: "Refresh catalog repo (skills, servers, agent roots) from tadasant/zimmer-catalog"
    },
    slack_trigger_poller: {
      cron: "* * * * *", # Every minute (GoodJob/fugit doesn't support seconds)
      class: "SlackTriggerPollerJob",
      description: "Poll Slack channels for triggers and create sessions"
    },
    slack_trigger_health_check: {
      cron: "45 * * * *", # Every hour at minute 45 (offset from other hourly jobs)
      class: "SlackTriggerHealthCheckJob",
      description: "Detect Slack trigger feeds that have silently stopped firing and alert"
    },
    schedule_trigger: {
      cron: "* * * * *", # Every minute
      class: "ScheduleTriggerJob",
      description: "Check schedule triggers and create sessions when due"
    },
    refresh_mcp_oauth_tokens: {
      cron: "*/30 * * * *", # Every 30 minutes
      class: "RefreshMcpOauthTokensJob",
      description: "Proactively refresh MCP OAuth tokens before they expire"
    },
    transcript_archive: {
      cron: "*/10 * * * *", # Every 10 minutes
      class: "TranscriptArchiveJob",
      description: "Incrementally build/update transcript archive zip file"
    },
    warm_skills_cache: {
      cron: "0 */4 * * *", # Every 4 hours
      class: "WarmSkillsCacheJob",
      description: "Warm the Claude skills cache for follow-up prompt slash command typeahead"
    },
    cleanup_expired_elicitations: {
      cron: "*/5 * * * *", # Every 5 minutes
      class: "CleanupExpiredElicitationsJob",
      description: "Expire pending elicitations past their expiration time"
    },
    empty_trash: {
      cron: "0 * * * *", # Every hour
      class: "EmptyTrashJob",
      description: "Permanently delete clones for trashed sessions past retention period"
    },
    claude_code_update: {
      cron: "0 6 * * *", # Daily at 6:00 AM UTC
      class: "ClaudeCodeUpdateJob",
      description: "Update Claude Code CLI to the latest version"
    },
    refresh_runtime_auth_tokens: {
      cron: "*/5 * * * *", # Every 5 minutes (min rotation_interval across runtimes)
      class: "RefreshRuntimeAuthTokensJob",
      description: "Proactively refresh runtime login-credential tokens before they expire (fans out per runtime)"
    },
    cleanup_stale_triggers: {
      cron: "15 * * * *", # Every hour at minute 15 (offset from other hourly jobs)
      class: "CleanupStaleTriggersJob",
      description: "Destroy orphaned one-time wake-up triggers (archived target session or lapsed schedule)"
    },
    zombie_reaper: {
      cron: "*/5 * * * *", # Every 5 minutes
      class: "ZombieReaperJob",
      description: "Reap zombie subprocesses left by agent sessions (defense in depth alongside tini init shim)"
    }
  }

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  config.action_view.annotate_rendered_view_with_filenames = true

  # Uncomment if you wish to allow Action Cable access from any origin.
  # config.action_cable.disable_request_forgery_protection = true

  # Allow ngrok URLs for development tunneling
  config.hosts << /[a-z0-9-]+\.ngrok-free\.app/
  config.hosts << /[a-z0-9-]+\.ngrok\.app/
  config.hosts << /[a-z0-9-]+\.ngrok\.io/

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # Apply autocorrection by RuboCop to files generated by `bin/rails generate`.
  # config.generators.apply_rubocop_autocorrect_after_generate!

  # GoodJob dashboard configuration
  config.good_job.enable_dashboard = true
end
