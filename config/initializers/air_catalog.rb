# frozen_string_literal: true

# Refresh AIR catalog sources on startup, in every process, so any github sources
# declared in air.json are pulled to their latest commits and the result is stored
# as the newest CatalogSnapshot before the first request lands. Running it in the
# web as well as the worker is what makes a new image's in-repo catalog live as
# soon as that image boots. Skipped in test (uses in-repo air.json).
#
# After boot, no process re-resolves on a timer. The worker's */15 CatalogRefreshJob
# cron refreshes and stores a new snapshot, and every process — web included —
# serves the newest snapshot on AirCatalogService's 60-second TTL. See
# AirCatalogService and docs/src/content/docs/air/zimmer-integration.md.
unless Rails.env.test?
  Rails.application.config.after_initialize do
    AirCatalogService.refresh!
  rescue => e
    Rails.logger.warn "[AirCatalog] Failed to initialize catalog: #{e.message}"
  end
end
