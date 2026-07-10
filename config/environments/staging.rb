require "active_support/core_ext/integer/time"
require_relative "../../app/services/air_catalog_ref_rewriter"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Staging shares production's catalog source: the in-image air.production.json
  # uses github:// URIs to pull catalog content (skills, mcp servers, roots, etc.)
  # from tadasant/zimmer-catalog HEAD. Deployed images only ship agents/agent-orchestrator,
  # so the dev air.json's ../skills/... relative paths would not resolve here.
  # AIR_CONFIG env still wins.
  #
  # AIR_CATALOG_REF (optional): when set, generate a temp air.staging.json that
  # rewrites every `github://tadasant/zimmer-catalog/...` URI to pin the catalog to
  # the given ref (branch / tag / commit SHA). Lets a staging deploy test
  # catalog changes from a feature branch without merging them to main.
  config.air_json_path = ENV.fetch("AIR_CONFIG") {
    base_path = Rails.root.join("air.production.json").to_s
    catalog_ref = ENV["AIR_CATALOG_REF"].to_s.strip
    if catalog_ref.empty?
      base_path
    else
      rewritten = AirCatalogRefRewriter.rewrite(
        File.read(base_path),
        pins: { AirCatalogRefRewriter::PULSEMCP_PREFIX => catalog_ref }
      )
      out_path = Rails.root.join("tmp", "air.staging.json")
      FileUtils.mkdir_p(out_path.dirname)
      File.write(out_path, rewritten)
      out_path.to_s
    end
  }

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # SSL can be disabled for staging environments without HTTPS
  unless ENV["DISABLE_SSL"] == "true"
    config.assume_ssl = true

    # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
    config.force_ssl = true
  end

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!)
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # GoodJob configuration for staging
  # Use :external mode - requires separate worker process
  config.good_job.execution_mode = :external

  # Queue configuration with thread allocation (configurable via ENV):
  # - agents: Long-running AgentSessionJob instances
  # - pollers: Singleton polling jobs that shouldn't queue up
  # - default: Everything else - cleanup, title generation, etc.
  # Note: max_threads should be >= sum of queue allocations
  agents_threads = ENV.fetch("GOOD_JOB_AGENTS_THREADS", 16).to_i
  pollers_threads = ENV.fetch("GOOD_JOB_POLLERS_THREADS", 3).to_i
  default_threads = ENV.fetch("GOOD_JOB_DEFAULT_THREADS", 4).to_i
  config.good_job.queues = "agents:#{agents_threads};pollers:#{pollers_threads};default:#{default_threads}"
  config.good_job.max_threads = ENV.fetch("GOOD_JOB_MAX_THREADS", 24).to_i
  config.good_job.enable_cron = true
  config.good_job.enable_dashboard = true
  config.good_job.cron = {
    cleanup_orphaned_sessions: {
      cron: "*/5 * * * *", # Every 5 minutes
      class: "CleanupOrphanedSessionsJob",
      description: "Cleanup orphaned sessions every 5 minutes"
    },
    heartbeat_sweep: {
      cron: "*/30 * * * * *", # Every 30 seconds
      class: "HeartbeatSweepJob",
      description: "Beat per-session heartbeats: nudge needs_input sessions due for a beat"
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
    cleanup_runtime_login_attempts: {
      cron: "*/5 * * * *", # Every 5 minutes
      class: "CleanupRuntimeLoginAttemptsJob",
      description: "Reap orphaned UI login attempts and prune old terminal rows"
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
    quota_reset_checker: {
      cron: "*/15 * * * *", # Every 15 minutes
      class: "QuotaResetCheckerJob",
      description: "Check if quota-exceeded accounts have reset and restore them to active"
    },
    refresh_runtime_auth_tokens: {
      cron: "*/5 * * * *", # Every 5 minutes (min rotation_interval across runtimes)
      class: "RefreshRuntimeAuthTokensJob",
      description: "Proactively refresh runtime login-credential tokens before they expire (fans out per runtime)"
    },
    docker_cleanup: {
      cron: "0 */6 * * *", # Every 6 hours
      class: "DockerCleanupJob",
      description: "Clean up stale dev-server containers, prune old Docker images, and handle emergency disk situations"
    },
    orphan_clone_filesystem_cleanup: {
      cron: "30 */6 * * *", # Every 6 hours, offset from docker_cleanup
      class: "OrphanCloneFilesystemCleanupJob",
      description: "Remove clone directories on disk with no matching session in the database"
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
    },
    cert_expiry_monitor: {
      cron: "0 7 * * *", # Daily at 07:00 UTC (offset from claude_code_update at 06:00)
      class: "CertExpiryMonitorJob",
      description: "Check public TLS certs (ao/obs hosts) and alert when expiry nears — catches broken auto-renewal"
    }
  }

  # Redis cache store for staging
  config.cache_store = :redis_cache_store, {
    url: "#{ENV["REDIS_URL"]}/0",
    connect_timeout: 30,
    read_timeout: 5,
    write_timeout: 15,
    reconnect_attempts: 3,
    error_handler: ->(method:, returning:, exception:) {
      Rails.logger.error("[redis_cache_store] Redis error: #{exception.class} - #{exception.message}")
    },
    pool: {
      size: ENV.fetch("REDIS_POOL_SIZE", 50).to_i,
      timeout: 30
    }
  }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "staging.zimmer.example.com" }

  # Specify outgoing SMTP server. Remember to add smtp/* credentials via rails credentials:edit.
  # config.action_mailer.smtp_settings = {
  #   user_name: Rails.application.credentials.dig(:smtp, :user_name),
  #   password: Rails.application.credentials.dig(:smtp, :password),
  #   address: "smtp.example.com",
  #   port: 587,
  #   authentication: :plain
  # }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in staging/production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
