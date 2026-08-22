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
  include SingletonSweep

  queue_as :default

  # Terminal attempts are kept briefly for post-mortem visibility, then pruned.
  RETENTION = 1.day

  def perform
    reap_orphaned
    prune_old_terminal
  end

  private

  # A non-terminal attempt is orphaned once its verification window has elapsed,
  # the job driving it stopped stamping its heartbeat, or the login CLI it was
  # driving is gone. Force it terminal so the UI stops polling, kill any lingering
  # PID, and drop the pasted authorization code.
  #
  # The heartbeat is what catches a worker killed hard enough to skip Ruby (deploy
  # SIGKILL, crash, container replacement): no ensure block runs, so the row would
  # otherwise sit non-terminal until its 14-minute window elapsed. It is also the
  # only one of the three signals that survives a container restart intact — a
  # recorded PID means nothing once PIDs have been renumbered in a fresh
  # container, where it may be absent (reaping a live login) or reused by an
  # unrelated process (never reaping a dead one).
  def reap_orphaned
    reaped = 0

    RuntimeLoginAttempt.active.find_each do |attempt|
      next unless attempt.orphaned? || process_dead?(attempt)

      kill_if_alive(attempt.pid)
      with_db_retry do
        # fail_orphaned! names which deadline was missed and returns false for a
        # row that is only process_dead?, which gets the generic reason instead.
        attempt.fail_orphaned! || attempt.update!(
          status: "failed",
          error_message: "The login CLI is no longer running, so this login cannot complete. Start a new login.",
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
  # of a PID is not death — only a recorded-but-gone PID counts. A never-spawned
  # attempt (queued job, no heartbeat yet) is reaped by the expired_window check
  # inside orphaned? instead.
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
