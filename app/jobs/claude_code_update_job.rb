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

  # Bound on `claude update`. Raised from 120s when the bound stopped being
  # decorative (#908): what it used to do was let the installer finish and then
  # relabel the result, and what it does now is SIGKILL the process group
  # part-way through a download-and-extract into the volume-mounted
  # ~/.local/share/claude/versions/. A killed installer is a worse outcome than
  # a slow one — nobody can reach a shell on the box to repair a half-written
  # binary — so the bound is set where it still catches a genuine wedge and
  # cannot plausibly fire on a contended droplet. Overridable via ENV for ops
  # tuning, like AirPrepareService's.
  UPDATE_TIMEOUT = Integer(ENV.fetch("CLAUDE_UPDATE_TIMEOUT_SECONDS", "600"))

  # Bound on the `claude --version` probe taken either side of the update. A
  # working binary answers in milliseconds; this only has to outlast a loaded box.
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
    # The status is nil, so SubprocessStatus.describe_failure reaches for its
    # generic "child reaped before its waiter" wording — true of the #271 race
    # and not of this. The stderr slot is what corrects it in the same line.
    [ nil, "timed out after #{UPDATE_TIMEOUT}s; process group SIGKILLed", nil ]
  end
end
