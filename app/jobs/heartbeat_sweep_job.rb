# frozen_string_literal: true

# Recurring sweep that drives the per-session heartbeat feature.
#
# A session with `heartbeat_enabled: true` "beats" every
# `heartbeat_interval_seconds`. This job runs on a short cron cadence, finds the
# sessions that are due for their next beat, and acts based on each session's
# current state:
#
# - running / waiting  -> do nothing (the session is already making progress or
#                          is queued). We still record the beat so the cadence
#                          stays anchored to real time.
# - needs_input        -> inject the heartbeat nudge prompt and resume the agent
#                          (the same delivery path the API follow_up uses).
# - failed / archived  -> terminal: auto-disable the heartbeat so we don't beat
#                          against a session that can never move again.
#
# Idempotency: each session is beaten inside a row-locked transaction and the
# due-ness is re-checked under the lock, so two overlapping sweeps can't stack
# two nudges. Once a needs_input session is nudged it transitions to running, so
# the next due beat is a no-op record rather than a second nudge.
class HeartbeatSweepJob < ApplicationJob
  queue_as :default

  def perform
    now = Time.current
    due_ids = Session.heartbeat_due(now).pluck(:id)
    return if due_ids.empty?

    Rails.logger.info "[HeartbeatSweepJob] #{due_ids.size} session(s) due for a beat"

    due_ids.each do |session_id|
      beat_session(session_id)
    rescue => e
      # One session failing to beat must not abort the whole sweep. The sweep
      # runs again on the next tick and will retry, so a single failure is
      # recoverable — log at info per the repo logging philosophy (transient
      # failures retried on the next scheduled run are info, not warn/error).
      Rails.logger.info "[HeartbeatSweepJob] Failed to beat session #{session_id}: #{e.class}: #{e.message}"
    end
  end

  private

  def beat_session(session_id)
    Session.transaction do
      session = Session.lock.find_by(id: session_id)
      return unless session
      # Re-check under the row lock: another sweep (or a manual disable) may have
      # already handled or turned off this heartbeat since we built the due list.
      return unless session.heartbeat_enabled?
      return unless session.heartbeat_due?

      case session.status
      when "running", "waiting"
        # Already progressing/queued — just anchor the cadence. update_column
        # avoids bumping updated_at (this is a no-op beat, not real activity).
        session.update_column(:heartbeat_last_beat_at, Time.current)
      when "needs_input"
        beat_needs_input(session)
      when "failed"
        # Failed sessions can be restarted, and the user likely still wants the
        # heartbeat to drive them to completion afterward — so DON'T disable it.
        # Just anchor the cadence and skip the nudge (a failed session can't run).
        session.update_column(:heartbeat_last_beat_at, Time.current)
      when "archived"
        # Terminal and intentionally done/trashed — auto-disable so an archived
        # session's heartbeat can never loop forever.
        session.update_columns(heartbeat_enabled: false, heartbeat_last_beat_at: Time.current)
        session.logs.create!(level: "info", content: "Heartbeat auto-disabled: session is archived.")
        Rails.logger.info "[HeartbeatSweepJob] Auto-disabled heartbeat for archived session #{session.id}"
      end
    end
  end

  # A needs_input session is only nudged when it is genuinely idle and waiting on
  # the human. Two needs_input sub-states must be left alone:
  #   - blocked on a pending MCP elicitation: the live agent process is STILL
  #     running, so resuming would spawn a SECOND process and orphan the
  #     elicitation.
  #   - has a pending enqueued message: real work is already queued and will be
  #     delivered on the next resume; nudging would race/clobber it.
  def beat_needs_input(session)
    if session.blocked_on_elicitation? || session.enqueued_messages.pending.exists?
      session.update_column(:heartbeat_last_beat_at, Time.current)
      return
    end

    nudge_needs_input(session)
  end

  # Deliver the heartbeat nudge to an idle (needs_input) session. This mirrors
  # the API follow_up direct-resume path (Api::V1::SessionsController#follow_up):
  # stamp the prompt, fire the resume event, enqueue the agent job, and record
  # the running job id. (That 4-line sequence is duplicated across several
  # callers — a future refactor could extract a shared Session#deliver_follow_up!.)
  def nudge_needs_input(session)
    session.update!(prompt: AutomatedPrompts::HEARTBEAT, heartbeat_last_beat_at: Time.current)
    session.resume! if session.may_resume?
    job = AgentSessionJob.enqueue_with_prompt(session.id, AutomatedPrompts::HEARTBEAT)
    session.update!(running_job_id: job.job_id)
    session.logs.create!(level: "info", content: "Heartbeat nudged session (needs_input → running).")
    Rails.logger.info "[HeartbeatSweepJob] Nudged needs_input session #{session.id}"
  end
end
