# frozen_string_literal: true

# Refresh AIR catalog sources on startup so any github sources declared in air.json
# are pulled to their latest commits before the first request lands. The 60-second
# in-memory cache picks up subsequent disk changes. Skipped in test (uses in-repo
# air.json).
#
# Keeping the on-disk github clones fresh BETWEEN boots is split by process:
#   - Worker (GoodJob): CatalogRefreshJob runs `air update` every 15 min via cron.
#   - Web (Puma): runs no GoodJob cron, so PeriodicCatalogRefresher (below) does the
#     same on a schedule inside the web process. Without it, the web's per-container
#     ~/.air/cache — and thus get_configs / MCP-name validation served by Puma —
#     would stay stale until the next web deploy.
unless Rails.env.test?
  Rails.application.config.after_initialize do
    AirCatalogService.refresh!
  rescue => e
    Rails.logger.warn "[AirCatalog] Failed to initialize catalog: #{e.message}"
  end

  # Start the in-process refresher ONLY in the web server process. `Rails::Server` is
  # defined under `bin/rails server` (the web container's CMD) but not under
  # `good_job start` (worker), rake, console, or runner — so this covers exactly the
  # process that lacks a periodic refresh, without spawning redundant threads in the
  # worker (already covered by cron) or in short-lived one-off processes.
  # DISABLE_WEB_CATALOG_REFRESHER=true is an escape hatch.
  if defined?(Rails::Server) && ENV["DISABLE_WEB_CATALOG_REFRESHER"] != "true"
    Rails.application.config.after_initialize do
      PeriodicCatalogRefresher.start!
    end
  end
end
