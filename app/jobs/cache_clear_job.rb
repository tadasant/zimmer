# frozen_string_literal: true

# Background job to clear package manager caches in the worker container
#
# This job runs in the worker container where MCP servers are actually spawned.
# This is critical because the web and worker containers have separate filesystems,
# so clearing cache in the web container doesn't affect the worker's npm/pip caches.
#
# After clearing caches, it optionally triggers McpPackageReinstallJob to
# pre-populate the cache with MCP server packages.
#
# Usage:
#   CacheClearJob.perform_later                    # Clear caches only
#   CacheClearJob.perform_later(reinstall: true)   # Clear and reinstall MCP packages
class CacheClearJob < ApplicationJob
  queue_as :default

  def perform(reinstall: false)
    Rails.logger.info "[CacheClearJob] Starting cache clear in worker container"

    results = CacheClearService.clear_all

    # Log results
    results.each do |cache_key, result|
      if result[:cleared]
        Rails.logger.info "[CacheClearJob] Cleared #{cache_key}: #{result[:path]}"
      elsif result[:error]
        Rails.logger.error "[CacheClearJob] Failed to clear #{cache_key}: #{result[:error]}"
      else
        Rails.logger.info "[CacheClearJob] Skipped #{cache_key}: #{result[:message]}"
      end
    end

    # Optionally trigger reinstall
    if reinstall
      npm_cleared = results[:npm_npx]&.dig(:cleared) || results[:npm_cache]&.dig(:cleared)
      if npm_cleared
        Rails.logger.info "[CacheClearJob] Queueing MCP package reinstall"
        McpPackageReinstallJob.perform_later
      else
        Rails.logger.info "[CacheClearJob] Skipping reinstall - no npm cache was cleared"
      end
    end

    Rails.logger.info "[CacheClearJob] Cache clear completed"
  end
end
