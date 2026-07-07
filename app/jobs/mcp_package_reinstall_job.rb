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

    # Run the preinstall script
    # Use Open3 to capture output for logging
    stdout, stderr, status = Open3.capture3(script_path.to_s)

    if status.success?
      Rails.logger.info "[McpPackageReinstallJob] MCP package reinstall completed successfully"
      Rails.logger.debug "[McpPackageReinstallJob] Output: #{stdout}" if stdout.present?
    else
      Rails.logger.error "[McpPackageReinstallJob] MCP package reinstall failed with exit code #{status.exitstatus}"
      Rails.logger.error "[McpPackageReinstallJob] stderr: #{stderr}" if stderr.present?
      Rails.logger.error "[McpPackageReinstallJob] stdout: #{stdout}" if stdout.present?
    end
  end
end
