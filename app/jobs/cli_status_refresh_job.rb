# frozen_string_literal: true

# Background job to refresh CLI tool status cache.
#
# This job runs periodically (every 2 minutes via cron) to check the installation
# and authentication status of CLI tools (gh, claude, fly). Results are cached
# so the web endpoints can return immediately without blocking on shell commands.
#
# The CLI status checks can take 3-10+ seconds (especially `claude whoami`),
# so running them in a background job prevents blocking page loads.
class CliStatusRefreshJob < ApplicationJob
  queue_as :pollers

  # Singleton pattern: only allow one instance to run/queue at a time
  # This prevents queue backup when refresh takes longer than the cron interval
  good_job_control_concurrency_with(
    key: -> { "cli_status_refresh" },
    total_limit: 1
  )

  # Perform the CLI status refresh
  def perform
    service = CliStatusService.new
    report = service.full_status_report

    # Cache the full report for immediate access by the web layer
    Rails.cache.write(
      CliStatusService::CACHE_KEY,
      report,
      expires_in: CliStatusService::CACHE_TTL
    )

    Rails.logger.info "[CliStatusRefreshJob] CLI status refreshed: #{report[:unauthenticated_count]} unauthenticated tools"
  end
end
