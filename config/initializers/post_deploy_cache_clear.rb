# Post-Deploy Cache Clear Initializer
#
# Automatically clears npm/pip caches and reinstalls MCP packages when the
# worker container boots after a deploy.
#
# The problem: npm's npx cache (stored on a Docker volume that persists across
# deploys) can become corrupted when a new container image is deployed. This
# causes TAR_ENTRY_ERROR / ENOENT errors when MCP servers try to start:
#
#   npm WARN tar TAR_ENTRY_ERROR ENOENT: no such file or directory,
#     open '/home/rails/.npm/_npx/.../node_modules/qs/lib/utils.js'
#
# The solution: On every worker boot, proactively clear the npx cache and
# reinstall MCP packages. This runs as a background job so it doesn't block
# startup, and the CacheClearJob handles all the actual work.

Rails.application.config.after_initialize do
  next if Rails.env.test?
  next unless defined?(GoodJob) && Rails.application.config.good_job.enable_cron

  # Skip during asset precompilation or other non-server contexts
  if defined?(Rake) && Rake.respond_to?(:application) && Rake.application.respond_to?(:top_level_tasks)
    next if Rake.application.top_level_tasks.any? { |task| task.include?("assets") }
  end

  # Only run in the worker process (where MCP servers are spawned and caches live).
  # The web container has a separate filesystem, so clearing cache there is pointless.
  next unless ENV["GOOD_JOB_EXECUTION_MODE"] == "external"

  Rails.logger.info "[PostDeployCacheClear] Scheduling cache clear and MCP package reinstall"

  begin
    # Small delay to let the database connection pool stabilize
    CacheClearJob.set(wait: 10.seconds).perform_later(reinstall: true)
  rescue ActiveRecord::ConnectionNotEstablished, PG::ConnectionBad => e
    Rails.logger.warn "[PostDeployCacheClear] Could not schedule cache clear job: #{e.message}"
  end
end
