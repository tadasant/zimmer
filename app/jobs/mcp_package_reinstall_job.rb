# frozen_string_literal: true

# Background job to reinstall MCP packages after cache is cleared
#
# This job runs the bin/preinstall-mcp-packages script to re-populate
# the npm cache with MCP server packages. This ensures subsequent
# MCP server startups don't have to wait for package downloads.
#
# The job is triggered by CacheClearService.clear_all_and_reinstall
# after clearing the npm cache.
class McpPackageReinstallJob < ApplicationJob
  queue_as :default

  # Wall-clock bound on the preinstall script.
  #
  # This job is enqueued 10s after every worker boot (CacheClearJob, from the
  # post_deploy_cache_clear initializer), so it runs on the `default` queue at the
  # one moment that queue is least able to absorb a long occupancy: right after a
  # deploy cutover, alongside DeploymentRecoveryJob. `default` has 4 scheduler
  # threads (ConnectionBudget.good_job_queue_threads) and ~30 job classes, so an
  # unbounded install would hold a quarter of them for as long as npm takes.
  #
  # The script shells out to `npx` over the network for every catalog MCP package,
  # so the case this bounds is a registry that accepts the connection and then
  # stalls -- the same half-open-socket failure BoundedSubprocess covers on the git
  # path. Undeadlined, that pins the thread until the worker restarts, which is what
  # the 2026-08-17 production cutover measured: its drain canary sat unclaimed on
  # `default` for the full 180s while `pollers`, `triggers` and `agents` each
  # claimed and finished in ~4s.
  #
  # 15 minutes is well above a cold full reinstall and far below "never".
  PREINSTALL_TIMEOUT = 15.minutes

  # Don't retry on failure - this is a best-effort operation
  discard_on StandardError

  # GoodJob::InterruptError < StandardError, so the broad discard_on above would otherwise
  # catch deploy interrupts and log them at ERROR (tripping the "any Zimmer ERROR → critical"
  # Grafana alert). Re-register the quiet INFO handler AFTER discard_on so last-registered-wins
  # routes interrupts there instead. See ApplicationJob.discard_interrupt_quietly.
  discard_interrupt_quietly

  def perform
    Rails.logger.info "[McpPackageReinstallJob] Starting MCP package reinstall"

    script_path = Rails.root.join("bin", "preinstall-mcp-packages")

    unless File.exist?(script_path)
      Rails.logger.warn "[McpPackageReinstallJob] Script not found: #{script_path}"
      return
    end

    # Run the preinstall script under a wall-clock watchdog, so a stalled npm
    # cannot hold a `default` scheduler thread indefinitely (see PREINSTALL_TIMEOUT).
    begin
      stdout, stderr, status = BoundedSubprocess.run([ script_path.to_s ], timeout: PREINSTALL_TIMEOUT)
    rescue BoundedSubprocess::TimeoutError => e
      Rails.logger.error "[McpPackageReinstallJob] MCP package reinstall timed out: #{e.message}"
      return
    end

    if SubprocessStatus.success?(status)
      Rails.logger.info "[McpPackageReinstallJob] MCP package reinstall completed successfully"
      Rails.logger.debug "[McpPackageReinstallJob] Output: #{stdout}" if stdout.present?
    else
      Rails.logger.error "[McpPackageReinstallJob] MCP package reinstall failed (#{SubprocessStatus.describe_failure(status)})"
      Rails.logger.error "[McpPackageReinstallJob] stderr: #{stderr}" if stderr.present?
      Rails.logger.error "[McpPackageReinstallJob] stdout: #{stdout}" if stdout.present?
    end
  end
end
