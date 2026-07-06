# API controller for CLI tools status and cache management.
#
# Provides endpoints to check CLI installation/auth status and clear caches.
# Status checks read from cache and never block on shell commands.
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::ClisController < Api::BaseController
  # GET /api/v1/clis/status
  # Get cached CLI tools status report.
  def status
    report = CliStatusService.cached_report
    render json: {
      cli_status: report,
      unauthenticated_count: CliStatusService.unauthenticated_count
    }
  end

  # POST /api/v1/clis/refresh
  # Trigger an immediate background refresh of CLI status.
  def refresh
    CliStatusRefreshJob.perform_later
    render json: {
      queued: true,
      message: "CLI status refresh queued",
      current_status: CliStatusService.cached_report
    }
  end

  # POST /api/v1/clis/clear_cache
  # Clear npm/pip caches and reinstall MCP packages in the worker container.
  def clear_cache
    CacheClearJob.perform_later(reinstall: true)
    render json: {
      queued: true,
      message: "Cache clear queued. Caches will be cleared in the worker container and MCP packages reinstalled."
    }
  end
end
