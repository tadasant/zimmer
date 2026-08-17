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
  # The script shells out to `npx` over the network for every catalog MCP package, so
  # the case this bounds is a registry that accepts the connection and then stalls --
  # the same half-open-socket failure BoundedSubprocess covers on the git path.
  # Undeadlined, that holds one of the `default` queue's 4 scheduler threads
  # (ConnectionBudget.good_job_queue_threads) until the worker restarts, on a queue
  # ~30 job classes share.
  #
  # The timing is what makes a single thread worth bounding: CacheClearJob is
  # enqueued 10s after every worker boot and chains this job whenever it actually
  # cleared the npx cache, so the window opens right after a deploy cutover --
  # alongside DeploymentRecoveryJob at +30s, and while a post-cutover check may be
  # asserting that `default` still drains.
  #
  # Seconds rather than a Duration, matching the other subprocess timeouts this
  # codebase passes to BoundedSubprocess. 900s is well above a cold full reinstall
  # and far below "never".
  PREINSTALL_TIMEOUT_SECONDS = 900

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

    # Run the preinstall script under a wall-clock watchdog, so a stalled npm cannot
    # hold a `default` scheduler thread indefinitely (see PREINSTALL_TIMEOUT_SECONDS).
    begin
      stdout, stderr, status = BoundedSubprocess.run([ script_path.to_s ], timeout: PREINSTALL_TIMEOUT_SECONDS)
    rescue BoundedSubprocess::TimeoutError => e
      # WARN rather than ERROR: hitting the deadline is this guard working, and the
      # consequence is a cold npx cache -- MCP servers install on demand at first use.
      # ERROR trips the "any Zimmer ERROR is critical" rule (see ApplicationJob), which
      # would page a human for slow npm. The non-zero-exit branch below stays ERROR:
      # that is the script failing, not the bound holding.
      Rails.logger.warn "[McpPackageReinstallJob] MCP package reinstall timed out: #{e.message}"
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
