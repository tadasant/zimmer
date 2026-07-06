# frozen_string_literal: true

require "open3"

# Background job to keep Claude Code CLI up to date.
#
# Runs daily via cron to execute `claude update`, which checks for and installs
# the latest Claude Code version. The native installer's auto-update binary
# handles the actual update mechanics — this job just triggers the check.
#
# After updating, refreshes the CLI status cache so the /clis page shows
# the current version without waiting for the next CliStatusRefreshJob run.
#
# In production, Claude Code is installed to ~/.local/share/claude/versions/
# which is volume-mounted (agent-orchestrator_claude-local) for persistence
# across container restarts and deploys.
class ClaudeCodeUpdateJob < ApplicationJob
  queue_as :default

  # Singleton: only one update at a time
  good_job_control_concurrency_with(
    key: -> { "claude_code_update" },
    total_limit: 1
  )

  # 2-minute timeout for the update command
  UPDATE_TIMEOUT = 120

  def perform
    before_version = current_version
    Rails.logger.info "[ClaudeCodeUpdateJob] Starting update check (current: #{before_version || 'unknown'})"

    stdout, stderr, status = run_update

    if status&.success?
      after_version = current_version
      if before_version != after_version
        Rails.logger.info "[ClaudeCodeUpdateJob] Updated from #{before_version} to #{after_version}"
      else
        Rails.logger.info "[ClaudeCodeUpdateJob] Already up to date (#{after_version})"
      end
    else
      Rails.logger.warn "[ClaudeCodeUpdateJob] Update command failed (exit #{status&.exitstatus}): #{stderr.to_s.strip}"
    end

    # Refresh CLI status cache so the version is immediately visible
    CliStatusRefreshJob.perform_later
  end

  private

  def current_version
    stdout, _stderr, status = Timeout.timeout(30) do
      Open3.capture3("claude", "--version")
    end
    return nil unless status.success?

    # Extract semver from output like "2.1.87 (Claude Code)"
    match = stdout.strip.match(/(\d+\.\d+\.\d+)/)
    match ? match[1] : nil
  rescue Errno::ENOENT, Timeout::Error
    nil
  end

  def run_update
    Timeout.timeout(UPDATE_TIMEOUT) do
      Open3.capture3("claude", "update")
    end
  rescue Errno::ENOENT
    Rails.logger.error "[ClaudeCodeUpdateJob] claude binary not found in PATH"
    [ nil, "claude binary not found", nil ]
  rescue Timeout::Error
    Rails.logger.error "[ClaudeCodeUpdateJob] Update timed out after #{UPDATE_TIMEOUT}s"
    [ nil, "timeout", nil ]
  end
end
