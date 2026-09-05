# frozen_string_literal: true

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
# which is volume-mounted (the claude_local named volume) for persistence
# across container restarts and deploys.
class ClaudeCodeUpdateJob < ApplicationJob
  queue_as :maintenance

  # Singleton: only one update at a time.
  include SingletonSweep

  # 2-minute timeout for the update command
  UPDATE_TIMEOUT = 120

  # Bound on the `claude --version` probe taken either side of the update.
  VERSION_TIMEOUT = 30

  def perform
    before_version = current_version
    Rails.logger.info "[ClaudeCodeUpdateJob] Starting update check (current: #{before_version || 'unknown'})"

    stdout, stderr, status = run_update

    if SubprocessStatus.success?(status)
      after_version = current_version
      if before_version != after_version
        Rails.logger.info "[ClaudeCodeUpdateJob] Updated from #{before_version} to #{after_version}"
      else
        Rails.logger.info "[ClaudeCodeUpdateJob] Already up to date (#{after_version})"
      end
    else
      Rails.logger.warn "[ClaudeCodeUpdateJob] Update command failed " \
        "(#{SubprocessStatus.describe_failure(status, stderr)})"
    end

    # Refresh CLI status cache so the version is immediately visible
    CliStatusRefreshJob.perform_later
  end

  private

  def current_version
    stdout, _stderr, status =
      BoundedSubprocess.run([ "claude", "--version" ], timeout: VERSION_TIMEOUT)
    return nil unless SubprocessStatus.success?(status)

    # Extract semver from output like "2.1.87 (Claude Code)"
    match = stdout.strip.match(/(\d+\.\d+\.\d+)/)
    match ? match[1] : nil
  rescue Errno::ENOENT, BoundedSubprocess::TimeoutError
    nil
  end

  # Returns the [stdout, stderr, status] triple `perform` destructures, including
  # on every failure branch — SubprocessStatus.describe_failure reads the nil
  # status as a failure rather than dereferencing it.
  def run_update
    BoundedSubprocess.run([ "claude", "update" ], timeout: UPDATE_TIMEOUT)
  rescue Errno::ENOENT
    Rails.logger.error "[ClaudeCodeUpdateJob] claude binary not found in PATH"
    [ nil, "claude binary not found", nil ]
  rescue BoundedSubprocess::TimeoutError
    Rails.logger.error "[ClaudeCodeUpdateJob] Update timed out after #{UPDATE_TIMEOUT}s (process group killed)"
    [ nil, "timeout", nil ]
  end
end
