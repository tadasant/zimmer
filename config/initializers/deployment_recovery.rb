# Deployment Recovery Initializer
#
# This initializer runs once when the Rails app starts and triggers automatic
# recovery of sessions that were interrupted by deployment.
#
# The problem: During deployment, GoodJob workers get killed, which interrupts
# running agent sessions. The CleanupOrphanedSessionsJob runs every 5 minutes
# and transitions these orphaned sessions to `needs_input` status, but they
# sit there waiting for manual intervention.
#
# The solution: On startup, enqueue a job that:
# 1. Waits briefly for the database and GoodJob to be ready
# 2. Finds sessions orphaned by the deployment (running with dead jobs, or
#    needs_input with paused_by: "recovery")
# 3. Automatically continues them with an automated recovery prompt
#
# This is distinct from the regular 5-minute cleanup cycle because it only
# runs once on startup and specifically targets deployment-related orphans.
#
# Sessions that legitimately entered needs_input during normal operation
# (e.g., user paused, natural stopping point) are NOT affected because they
# have paused_by: "user" or were never in a deployment-recovery state.

Rails.application.config.after_initialize do
  # Only run in production and development environments with GoodJob enabled
  # Skip in test environment to avoid interfering with tests
  next if Rails.env.test?

  # Skip if GoodJob is not configured (e.g., running console without workers)
  next unless defined?(GoodJob) && Rails.application.config.good_job.enable_cron

  # Skip during asset precompilation or other non-server contexts
  # These tasks don't have database access and shouldn't enqueue jobs
  # Note: Rake module may be defined but Rake.application may not exist in server context
  if defined?(Rake) && Rake.respond_to?(:application) && Rake.application.respond_to?(:top_level_tasks)
    next if Rake.application.top_level_tasks.any? { |task| task.include?("assets") }
  end

  # Skip if we're not running in a server context (e.g., rake tasks, console)
  # The server sets this when it starts
  next unless defined?(Rails::Server) || ENV["GOOD_JOB_EXECUTION_MODE"] == "external"

  # Schedule the deployment recovery job to run shortly after startup
  # Use a delay to ensure the database connection pool is ready and any
  # pending migrations have completed
  Rails.logger.info "[DeploymentRecovery] Scheduling deployment recovery job to run in 30 seconds"

  begin
    DeploymentRecoveryJob.set(wait: 30.seconds).perform_later
  rescue ActiveRecord::ConnectionNotEstablished, PG::ConnectionBad => e
    # Database not available yet - this can happen during certain startup scenarios
    # The job will be picked up by the regular cleanup cycle instead
    Rails.logger.warn "[DeploymentRecovery] Could not schedule recovery job: #{e.message}"
  end
end
