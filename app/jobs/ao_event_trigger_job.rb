# frozen_string_literal: true

# Job that fires ao_event trigger conditions when internal Zimmer events occur.
#
# Currently supports:
# - session_needs_input: Fired when a session transitions to needs_input
# - session_failed: Fired when a session transitions to failed
# - session_archived: Fired when a session is archived (from any prior state)
#
# This job is enqueued by the session state machine's pause/fail/archive callbacks.
# It runs asynchronously to avoid slowing down state transitions.
#
# For broadcast (unscoped) conditions, only autonomous sessions trigger the
# event — non-autonomous (user-driven) sessions are filtered out below.
# Watched-session conditions are an explicit per-session opt-in and fire
# regardless of is_autonomous.
#
# Loop prevention:
# - Sessions created by the same trigger are excluded from firing that trigger again
# - Only autonomous sessions (is_autonomous: true) trigger this event
# - Non-autonomous sessions (e.g., user-paused) are ignored
#
# Watched-session scoping:
# - Conditions with watched_session_id in configuration ONLY fire when THAT
#   session transitions. Conditions without watched_session_id fire for any
#   transitioning autonomous session (broadcast semantics).
class AoEventTriggerJob < ApplicationJob
  # Runs on the dedicated `triggers` queue rather than `default`. These wakes are
  # latency-sensitive — a watched session transitioning to needs_input/failed/
  # archived must resume its waiting requester promptly. On the shared `default`
  # queue this job was starved for hours behind a backlog of periodic/bulk jobs
  # (heartbeat sweeps, Slack polling, cleanup), so the enqueued wake never ran in
  # time and requesters stalled until an unrelated deadline backstop fired.
  queue_as :triggers

  # Warn when the gap between enqueue and execution grows large enough that a
  # state-change wake is effectively late. A silently-delayed wake is exactly the
  # failure this queue split fixes; surfacing the latency keeps future queue
  # starvation observable instead of invisible (see logging philosophy in
  # CLAUDE.md — a self-resolving hiccup is .info, a genuinely late wake is .warn).
  DISPATCH_LATENCY_WARN_THRESHOLD = 120 # seconds

  def perform(event_name, session_id)
    warn_on_high_dispatch_latency(event_name, session_id)

    session = Session.find_by(id: session_id)
    return unless session

    unless TriggerCondition::AO_EVENT_NAMES.include?(event_name)
      Rails.logger.warn "[AoEventTriggerJob] Unknown event: #{event_name}"
      return
    end

    fire_event(event_name, session)
  end

  private

  # Compute how long this job waited between being enqueued and being performed.
  # ActiveJob populates `enqueued_at` at enqueue time and restores it on the
  # worker, so no extra argument or timestamp plumbing is needed. Defensive: any
  # parsing hiccup is swallowed — observability must never break trigger firing.
  def warn_on_high_dispatch_latency(event_name, session_id)
    return if enqueued_at.blank?

    enqueued = enqueued_at.is_a?(Time) ? enqueued_at : Time.parse(enqueued_at.to_s)
    latency = Time.current - enqueued
    return if latency <= DISPATCH_LATENCY_WARN_THRESHOLD

    Rails.logger.warn(
      "[AoEventTriggerJob] High dispatch latency: #{latency.round(1)}s between enqueue and " \
      "execution for #{event_name} (session #{session_id}). The `triggers` queue may be " \
      "backlogged — state-change wakes are being delivered late."
    )
  rescue => e
    Rails.logger.info "[AoEventTriggerJob] Could not compute dispatch latency: #{e.class}: #{e.message}"
  end

  def fire_event(event_name, session)
    # Find all enabled triggers with ao_event conditions for this event_name
    conditions = TriggerCondition.ao_event
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .where("trigger_conditions.configuration @> ?", { event_name: event_name }.to_json)
      .includes(:trigger)

    # Wrap the fan-out in an AlertBatcher scope so catalog issues affecting
    # many triggers collapse to one aggregated Slack message.
    AlertBatcher.with_batch do
      conditions.find_each do |condition|
        trigger = condition.trigger
        scoped = condition.session_scoped_ao_event?

        # Watched-session scoping: if this condition is scoped to a specific
        # session, skip unless the transitioning session matches.
        if scoped && condition.watched_session_id != session.id
          next
        end

        # Session-scoped conditions are one-shot: once they've fired (or been
        # cancelled by a manual resume), don't re-fire on subsequent watched
        # session transitions. The trigger row itself may also have been
        # destroyed below for single-condition wake-ups.
        if scoped && condition.last_triggered_at.present?
          Rails.logger.debug "[AoEventTriggerJob] Skipping already-fired session-scoped condition #{condition.id}"
          next
        end

        # Broadcast (unscoped) ao_event conditions only fire for autonomous
        # sessions — user-paused sessions shouldn't trigger global automation.
        # Session-scoped conditions are an explicit per-session opt-in, so they
        # fire regardless of is_autonomous.
        if !scoped && !session.is_autonomous
          Rails.logger.debug "[AoEventTriggerJob] Skipping non-autonomous session #{session.id} for broadcast #{event_name}"
          next
        end

        # Prevent infinite loops: don't fire if this session was created by this trigger
        if session.metadata&.dig("trigger_id").to_s == trigger.id.to_s
          Rails.logger.info "[AoEventTriggerJob] Skipping trigger #{trigger.id} for session #{session.id} (created by this trigger)"
          next
        end

        begin
          prompt = trigger.interpolate_prompt(
            event: event_label(event_name, session)
          )
          result_session = trigger.create_session!(prompt: prompt)
          condition.update!(last_triggered_at: Time.current)
          Rails.logger.info "[AoEventTriggerJob] Fired trigger #{trigger.id} for session #{session.id} #{event_name}, created/reused session #{result_session.id}"

          # One-time wake-up triggers (only session-scoped ao_events and/or
          # one-time schedules) auto-delete after firing — they've done their
          # job and there's nothing left to fire. Mirrors ScheduleTriggerJob.
          #
          # CRITICAL: only destroy the trigger and its siblings when the wake
          # was actually delivered or queued. If the wake fired while the
          # requester session was still running and the trigger didn't queue
          # the message (e.g., recurring trigger with enqueue_messages off),
          # the wake was silently dropped — destroying siblings would leave
          # the requester with no wakes at all. Leave siblings in place so
          # they can deliver when their watched events transition (or the
          # deadline backstop fires).
          if trigger.one_time_reuse_trigger?
            if trigger.last_follow_up_dropped?
              Rails.logger.info "[AoEventTriggerJob] Trigger #{trigger.id} fired but delivery was dropped (requester still running, no enqueue) — preserving siblings and skipping auto-delete"
            else
              trigger_id = trigger.id
              requester_id = trigger.last_session_id
              sibling_count = trigger.destroy_sibling_wakes!
              trigger.destroy!
              Rails.logger.info "[AoEventTriggerJob] One-time trigger #{trigger_id} auto-deleted after firing"
              if sibling_count > 0
                Rails.logger.info "[AoEventTriggerJob] Destroyed #{sibling_count} sibling wake-up trigger(s) for requester session #{requester_id}"
              end
            end
          end
        rescue => e
          Rails.logger.error "[AoEventTriggerJob] Error firing trigger #{trigger.id} for session #{session.id}: #{e.message}"
        end
      end
    end
  end

  def event_label(event_name, session)
    title = session.title.presence || "Untitled"
    case event_name
    when "session_needs_input"
      "Session ##{session.id} (#{title}) needs input"
    when "session_failed"
      "Session ##{session.id} (#{title}) failed"
    when "session_archived"
      "Session ##{session.id} (#{title}) archived"
    else
      "Session ##{session.id} (#{title}) #{event_name}"
    end
  end
end
