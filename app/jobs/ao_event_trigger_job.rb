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
#
# A fire that raises always alerts. A session-scoped (one-shot) wake is also
# parked as `failed` rather than left silently enabled, because it fires only on
# its watched session's transitions and a terminal session has none left. A
# broadcast condition is recurring and stays enabled. See #handle_fire_failure.
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

        # Flipped once the fire has actually delivered. Everything past that
        # point is cleanup, and a failure there must not be advertised as
        # re-armable — re-firing would duplicate the session that already exists.
        delivered = false

        begin
          prompt = trigger.interpolate_prompt(
            event: event_label(event_name, session)
          )
          result_session = trigger.create_session!(prompt: prompt)

          # A burst-suppressed fire delivered nothing, so it must not consume the
          # condition: advancing last_triggered_at would spend a session-scoped
          # condition's one-shot guard, and the auto-delete below would destroy a
          # wake trigger that never woke anything.
          if trigger.last_fire_burst_suppressed?
            Rails.logger.info "[AoEventTriggerJob] Trigger #{trigger.id} is burst-suppressed for session #{session.id} #{event_name} — no session created, condition left unfired"
            next
          end

          delivered = true
          condition.update!(last_triggered_at: Time.current)
          if result_session
            Rails.logger.info "[AoEventTriggerJob] Fired trigger #{trigger.id} for session #{session.id} #{event_name}, created/reused session #{result_session.id}"
          else
            # Burst suppression already skipped above, so nil here means a
            # one-time reuse trigger whose target session is gone. Not an error.
            Rails.logger.info "[AoEventTriggerJob] Fired trigger #{trigger.id} for session #{session.id} #{event_name}, but no session was created (no reusable target session)"
          end

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
          handle_fire_failure(
            condition: condition,
            trigger: trigger,
            scoped: scoped,
            session: session,
            event_name: event_name,
            delivered: delivered,
            error: e
          )
        end
      end
    end
  end

  # A fire that raised. Left to itself this used to be one `.error` log line —
  # no alert, no record, and a trigger still sitting there `enabled` with its
  # condition unspent, as if it were going to try again.
  #
  # For a SESSION-SCOPED condition that "going to try again" is a promise the
  # event stream cannot keep. The condition is one-shot and fires only on its
  # watched session's transitions; if that session was already making its last
  # one — which is exactly the `session_archived` / `session_failed` case agents
  # schedule most — there is no next transition, and the wake is simply lost.
  # So park the trigger as `failed`, mirroring ScheduleTriggerJob: it stays
  # visible at /triggers carrying the error that stopped it, and re-enabling it
  # re-arms the wake. Parking is also what closes the retry loop (every firing
  # path filters on `status: "enabled"`), which is why the condition's
  # last_triggered_at is deliberately left alone — the wake stays unspent, so a
  # re-arm delivers for real rather than needing a hand-edit first.
  #
  # For a BROADCAST condition the shape is the opposite. It is recurring by
  # nature — any autonomous session's transition fires it — so it is expected to
  # survive a bad event and fire on the next one. Parking one would silently
  # stop every future wake, which is this very bug pointed the other way. It
  # alerts and stays enabled.
  def handle_fire_failure(condition:, trigger:, scoped:, session:, event_name:, delivered:, error:)
    trigger_id = trigger.id
    trigger_name = trigger.name

    parked = scoped && trigger.mark_failed(error)

    Rails.logger.error(
      "[AoEventTriggerJob] Error firing trigger #{trigger_id} (#{trigger_name}) for session " \
      "#{session.id} #{event_name}: #{error.message}\n#{error.backtrace&.first(5)&.join("\n")}"
    )

    retry_note =
      if parked && !delivered
        watched_id = condition.watched_session_id
        "This is a one-shot state-change wake. It is marked *failed* and left in place, so it no " \
        "longer fires on its own. Re-enable it at #{trigger_url(trigger_id)} to re-arm it — but note " \
        "it can only re-fire if session ##{watched_id} transitions again, and a session already in a " \
        "terminal state never will. If so, the requester needs resuming by hand."
      elsif parked
        "This is a one-shot state-change wake, and it had already delivered when the error hit — a " \
        "session was created and only the cleanup behind it failed. The trigger is marked *failed* " \
        "and left in place, but re-arming it will NOT re-fire it. Check #{trigger_url(trigger_id)} " \
        "and the sessions it spawned."
      elsif scoped
        "This is a one-shot state-change wake and it could NOT be marked failed, so it remains " \
        "enabled — it will re-fire only if session ##{condition.watched_session_id} transitions " \
        "again. Check #{trigger_url(trigger_id)} by hand."
      else
        "This is a broadcast (recurring) state-change condition: it remains enabled and will fire " \
        "on the next matching session transition."
      end

    if parked
      Rails.logger.error(
        "[AoEventTriggerJob] One-shot trigger #{trigger_id} (#{trigger_name}) marked failed after a " \
        "failed firing — left in place so it stays visible" \
        "#{delivered ? " (wake already delivered; re-arming will not re-fire it)" : " and can be re-armed"}"
      )
    end

    AlertService.raise_alert(
      "State-change wake failed to fire",
      details: "Condition #{condition.id} on trigger '#{trigger_name}' (ID: #{trigger_id}) failed to " \
               "fire for #{event_name} on session ##{session.id}.\n\n#{retry_note}",
      source: "AoEventTriggerJob",
      dedup_key: "ao_event_trigger_#{trigger_id}",
      error: error
    )
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
