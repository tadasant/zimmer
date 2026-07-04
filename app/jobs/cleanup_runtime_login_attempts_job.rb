# frozen_string_literal: true

# Keeps the runtime_login_attempts table healthy. Runs every 5 minutes via
# GoodJob cron.
#
# RuntimeLoginJob holds a login CLI open while an attempt is in flight, so a
# worker that dies or is interrupted mid-login (deploy SIGTERM, crash) can leave:
#   * an orphaned CLI process (RuntimeLoginJob's ensure block kills its own child,
#     but a hard kill skips Ruby entirely), and
#   * a non-terminal attempt row the UI polls forever because no job will ever
#     touch it again.
#
# This job is the recovery story for both: it forces stranded attempts to a
# terminal state (killing any still-live PID and dropping credential-adjacent
# data) and prunes old terminal rows so the table doesn't grow without bound.
class CleanupRuntimeLoginAttemptsJob < ApplicationJob
  include DatabaseRetry

  queue_as :default

  # Terminal attempts are kept briefly for post-mortem visibility, then pruned.
  RETENTION = 1.day

  def perform
    reap_orphaned
    prune_old_terminal
  end

  private

  # A non-terminal attempt is orphaned once its verification window has elapsed or
  # the login CLI it was driving is gone. Force it to failed so the UI stops
  # polling, kill any lingering PID, and drop the pasted authorization code.
  def reap_orphaned
    reaped = 0

    RuntimeLoginAttempt.active.find_each do |attempt|
      next unless attempt.expired_window? || process_dead?(attempt)

      kill_if_alive(attempt.pid)
      with_db_retry do
        attempt.update!(
          status: "failed",
          error_message: "Login did not complete (worker stopped or verification window expired).",
          pasted_code: nil
        )
      end
      reaped += 1
    rescue => e
      Rails.logger.warn "[CleanupRuntimeLoginAttemptsJob] failed to reap attempt #{attempt.id}: #{e.class} - #{e.message}"
    end

    Rails.logger.info "[CleanupRuntimeLoginAttemptsJob] reaped #{reaped} orphaned attempt(s)" if reaped > 0
  end

  def prune_old_terminal
    deleted = with_db_retry do
      RuntimeLoginAttempt
        .where(status: RuntimeLoginAttempt::TERMINAL_STATUSES)
        .where(created_at: ..RETENTION.ago)
        .delete_all
    end

    Rails.logger.info "[CleanupRuntimeLoginAttemptsJob] pruned #{deleted} old terminal attempt(s)" if deleted > 0
  end

  # An attempt still in "starting" hasn't spawned its CLI yet (no PID), so absence
  # of a PID is not death — only a recorded-but-gone PID counts. The expired_window
  # check is what eventually reaps a never-spawned attempt.
  def process_dead?(attempt)
    attempt.pid.present? && !process_alive?(attempt.pid)
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def kill_if_alive(pid)
    return unless pid.present? && process_alive?(pid)
    Process.kill("TERM", pid)
  rescue Errno::ESRCH
    # Already gone between the check and the signal.
  end
end
