# frozen_string_literal: true

# Controller for the CLI tools management page
#
# Displays installation and authentication status for CLI tools
# and provides instructions for setting them up.
#
# Performance optimization:
# - CLI status checks are performed by CliStatusRefreshJob (runs every 2 minutes)
# - All endpoints read from cache and never block on shell commands
# - The "refresh" action triggers an immediate background job for on-demand refresh
class ClisController < ApplicationController
  # Main page - renders immediately with loading state
  def index
    @server_ip = server_tailscale_ip
  end

  # Async endpoint for loading CLI status (called via Turbo Frame)
  # Reads from cache - never blocks on shell commands
  def status
    @cli_report = CliStatusService.cached_report
    render partial: "cli_status", locals: { cli_report: @cli_report }
  end

  # Async endpoint for the badge count (called via Turbo Frame on sessions index)
  # Reads from cache - never blocks on shell commands
  def badge
    cli_issues = CliStatusService.unauthenticated_count
    render partial: "cli_badge", locals: { cli_issues: cli_issues }
  end

  # Trigger an immediate refresh of CLI status
  # Enqueues a background job to update the cache
  def refresh
    # Enqueue job for immediate execution
    CliStatusRefreshJob.perform_later

    respond_to do |format|
      format.html { redirect_to clis_path, notice: "CLI status refresh queued. Results will update shortly." }
      format.json do
        # Return current cached status immediately
        render json: CliStatusService.cached_report
      end
    end
  end

  # Clear npm and pip caches to fix corrupted cache issues and reinstall MCP packages
  # This is useful when MCP servers fail to start due to ENOTEMPTY errors or missing files
  #
  # IMPORTANT: Cache clearing runs via CacheClearJob in the worker container.
  # This is critical because web and worker containers have separate filesystems -
  # clearing cache in the web container wouldn't affect the worker's npm/pip caches
  # where MCP servers are actually spawned.
  def clear_cache
    CacheClearJob.perform_later(reinstall: true)

    message = "Cache clear queued. Caches will be cleared in the worker container and MCP packages reinstalled."

    respond_to do |format|
      format.html { redirect_to clis_path, notice: message }
      format.json { render json: { queued: true, message: message } }
    end
  end

  private

  # Get the server's Tailscale IP for SSH instructions
  def server_tailscale_ip
    # Try to get from tailscale CLI
    result = `tailscale ip -4 2>/dev/null`.strip
    return result if result.present? && result.match?(/\A\d+\.\d+\.\d+\.\d+\z/)

    # Fallback to request host if not available
    request.host
  end
end
