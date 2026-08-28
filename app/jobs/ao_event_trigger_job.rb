# frozen_string_literal: true

# Job that fires ao_event trigger conditions when internal Zimmer events occur.
#
# Supports two kinds of event, told apart by what they are ABOUT:
#
# - Session events (session_needs_input, session_failed, session_archived),
#   enqueued by the session state machine's pause/fail/archive callbacks. They
#   run asynchronously so a state transition is not slowed down by trigger firing.
# - Account events (account_needs_reauth), enqueued by ClaudeAccount's
#   status-transition callback when an account's refresh token dies for good.
#
# The second argument is therefore a SUBJECT id, not a session id. AoEventSubject
# resolves it and owns every per-subject rule — watched-session scoping, the
# one-shot guard, the is_autonomous filter and loop prevention for sessions; a
# freshness re-check for accounts — so nothing below has to ask which kind of
# event it is holding.
#
# For session events, broadcast (unscoped) conditions only fire for autonomous
# sessions; non-autonomous (user-driven) sessions are filtered out. Conditions
# carrying a watched_session_id are an explicit per-session opt-in, fire
# regardless of is_autonomous, and only for that session. Sessions created by the
# same trigger never re-fire it.
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

  # @param settle_marker [Integer, nil] only supplied for session_needs_input,
  #   which is emitted at every turn boundary and therefore has to be re-checked
  #   after a settle window before it can wake anybody (see
  #   SessionStateMachine::NEEDS_INPUT_SETTLE_WINDOW). The default keeps jobs
  #   enqueued by an older deploy — and every other event, which is terminal and
  #   cannot flap — working unchanged.
  def perform(event_name, subject_id, settle_marker = nil)
    warn_on_high_dispatch_latency(event_name, subject_id, settle_marker)

    unless TriggerCondition::AO_EVENT_NAMES.include?(event_name)
      Rails.logger.warn "[AoEventTriggerJob] Unknown event: #{event_name}"
      return
    end

    subject = AoEventSubject.resolve(event_name, subject_id, settle_marker)
    return unless subject

    # The condition the event announced can un-happen between enqueue and here —
    # an account can be re-authenticated, or resurrected by a filesystem sync.
    # Firing on a stale subject spawns a session about a problem that no longer
    # exists.
    if subject.stale?
      Rails.logger.info "[AoEventTriggerJob] Skipping #{event_name} for #{subject} — no longer applies"
      return
    end

    fire_event(event_name, subject)
  end

  private

  # Compute how long this job waited between being enqueued and being performed.
  # ActiveJob populates `enqueued_at` at enqueue time and restores it on the
  # worker, so no extra argument or timestamp plumbing is needed. Defensive: any
  # parsing hiccup is swallowed — observability must never break trigger firing.
  def warn_on_high_dispatch_latency(event_name, subject_id, settle_marker)
    return if enqueued_at.blank?

    enqueued = enqueued_at.is_a?(Time) ? enqueued_at : Time.parse(enqueued_at.to_s)
    latency = Time.current - enqueued
    # A settled session_needs_input is deliberately held for the settle window,
    # which is part of the wait and not queue starvation. Discount it so the
    # threshold keeps measuring the thing it was added to measure — and only for
    # the jobs that actually carried the wait, which the marker identifies. The
    # immediate-fire path (Trigger#fire_ao_event_immediately_if_state_matches)
    # and any job enqueued before this argument existed carry none, and
    # discounting those would hide a genuinely late wake.
    latency -= settle_window_for(event_name, settle_marker)
    return if latency <= DISPATCH_LATENCY_WARN_THRESHOLD

    Rails.logger.warn(
      "[AoEventTriggerJob] High dispatch latency: #{latency.round(1)}s between enqueue and " \
      "execution for #{event_name} (subject #{subject_id}). The `triggers` queue may be " \
      "backlogged — state-change wakes are being delivered late."
    )
  rescue => e
    Rails.logger.info "[AoEventTriggerJob] Could not compute dispatch latency: #{e.class}: #{e.message}"
  end

  def settle_window_for(event_name, settle_marker)
    return 0 unless event_name == "session_needs_input"
    return 0 if settle_marker.nil?

    SessionStateMachine::NEEDS_INPUT_SETTLE_WINDOW.to_i
  end

  def fire_event(event_name, subject)
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

        # Every reason not to fire this condition for this subject — scoping, the
        # one-shot guard, autonomy, loop prevention — lives on the subject.
        if (skip = subject.skip(condition))
          Rails.logger.public_send(skip.level, "[AoEventTriggerJob] Skipping #{event_name} for #{subject}: #{skip.message}")
          next
        end

        # Flipped once the fire has actually delivered. Everything past that
        # point is cleanup, and a failure there must not be advertised as
        # re-armable — re-firing would duplicate the session that already exists.
        delivered = false

        begin
          prompt = trigger.interpolate_prompt(
            event: subject.label(event_name)
          )
          result_session = trigger.create_session!(prompt: prompt)

          # A burst-suppressed fire delivered nothing, so it must not consume the
          # condition: advancing last_triggered_at would spend a session-scoped
          # condition's one-shot guard, and the auto-delete below would destroy a
          # wake trigger that never woke anything.
          if trigger.last_fire_burst_suppressed?
            Rails.logger.info "[AoEventTriggerJob] Trigger #{trigger.id} is burst-suppressed for #{subject} #{event_name} — no session created, condition left unfired"
            next
          end

          # A dedup-skipped fire delivered nothing either, so it must not consume
          # the condition. For a SESSION-SCOPED condition last_triggered_at is the
          # one-shot guard: spending it here would lose that wake permanently
          # because a session the trigger spawned earlier happened to still be
          # pending. Leave the condition unfired, as the burst path does.
          if trigger.last_fire_skipped_for_pending_session?
            Rails.logger.info "[AoEventTriggerJob] Trigger #{trigger.id} skipped #{subject} #{event_name} — session #{trigger.last_fire_pending_session.id} is still pending; condition left unfired"
            next
          end

          delivered = true
          condition.update!(last_triggered_at: Time.current)
          if result_session
            Rails.logger.info "[AoEventTriggerJob] Fired trigger #{trigger.id} for #{subject} #{event_name}, created/reused session #{result_session.id}"
          else
            # Burst suppression and dedup both skipped above, so nil here means a
            # one-time reuse trigger whose target session is gone. Not an error.
            Rails.logger.info "[AoEventTriggerJob] Fired trigger #{trigger.id} for #{subject} #{event_name}, but no session was created (no reusable target session)"
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
            subject: subject,
            event_name: event_name,
            delivered: delivered,
            error: e
          )
        end
      end
    end
  end

  # Records a fire that raised: it alerts, and for a one-shot wake it parks.
  #
  # For a SESSION-SCOPED condition, leaving the trigger `enabled` with its
  # condition unspent reads as "it will try again" — and that is a promise the
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
  #
  # Parking is per-TRIGGER while the failure is per-CONDITION, exactly as in
  # ScheduleTriggerJob: a trigger carrying other conditions stops firing on those
  # too. That bounds the blast radius to one trigger, and a session-scoped
  # ao_event sharing a trigger with anything else is not a shape Zimmer's own
  # wake tools create.
  #
  # The whole body is rescued because parking and alerting can raise — Slack is a
  # network call — and there is no outer per-condition rescue around the
  # find_each fan-out here the way there is in ScheduleTriggerJob#perform. A
  # raise escaping this method would abort the remaining conditions and drop
  # OTHER triggers' wakes, turning one lost wake into several.
  def handle_fire_failure(condition:, trigger:, scoped:, subject:, event_name:, delivered:, error:)
    trigger_id = trigger.id
    trigger_name = trigger.name

    parked = scoped && trigger.mark_failed(error)

    Rails.logger.error(
      "[AoEventTriggerJob] Error firing trigger #{trigger_id} (#{trigger_name}) for " \
      "#{subject} #{event_name}: #{error.message}\n#{error.backtrace&.first(5)&.join("\n")}"
    )

    # `delivered` and `spent` are different questions and must not be conflated.
    # `delivered` says a session was created; `spent` says the one-shot guard
    # actually PERSISTED. `condition.update!` sits between them and is itself a
    # raise site, so a fire can deliver its session and still leave the guard
    # unspent — and that combination is the dangerous one: the trigger is still
    # armed, so a re-arm would deliver a SECOND session for a wake already paid.
    # Reading the in-memory flag alone would advertise the opposite.
    spent = condition_spent?(condition)

    retry_note =
      if parked && !delivered
        "This is a one-shot state-change wake, and it delivered nothing. It is marked *failed* and " \
        "left in place, so it no longer fires on its own. Re-enable it at #{trigger_url(trigger_id)} " \
        "to re-arm it — but note it can only re-fire if session ##{condition.watched_session_id} " \
        "transitions again, and a session already in a terminal state never will. If so, the " \
        "requester needs resuming by hand."
      elsif parked && spent
        "This is a one-shot state-change wake, and it had already delivered when the error hit — only " \
        "the cleanup behind it failed. The trigger is marked *failed* and left in place, but " \
        "re-arming it will NOT re-fire it. Check #{trigger_url(trigger_id)} and the sessions it " \
        "spawned."
      elsif parked
        "This is a one-shot state-change wake. It had already delivered when the error hit, but the " \
        "error stopped its one-shot guard from being recorded, so the trigger is still armed. It is " \
        "marked *failed* and left in place. Do NOT re-arm it at #{trigger_url(trigger_id)} before " \
        "checking the sessions it spawned — re-arming would create a second session for a wake that " \
        "already delivered one."
      elsif scoped
        "This is a one-shot state-change wake and it could NOT be marked failed, so it remains " \
        "enabled — it will re-fire only if session ##{condition.watched_session_id} transitions " \
        "again. Check #{trigger_url(trigger_id)} by hand."
      else
        "This is a broadcast (recurring) condition: it remains enabled and will fire on the next " \
        "matching #{event_name} event."
      end

    if parked
      outcome =
        if !delivered then " and can be re-armed"
        elsif spent then " (wake already delivered; re-arming will not re-fire it)"
        else " (wake already delivered but its guard was not recorded; re-arming would duplicate it)"
        end
      Rails.logger.error(
        "[AoEventTriggerJob] One-shot trigger #{trigger_id} (#{trigger_name}) marked failed after a " \
        "failed firing — left in place so it stays visible#{outcome}"
      )
    end

    AlertService.raise_alert(
      "State-change wake failed to fire",
      details: "Condition #{condition.id} on trigger '#{trigger_name}' (ID: #{trigger_id}) failed to " \
               "fire for #{event_name} on #{subject}.\n\n#{retry_note}",
      source: "AoEventTriggerJob",
      dedup_key: "ao_event_trigger_#{trigger_id}",
      error: error
    )
  rescue => handler_error
    # Last resort, and deliberately the one thing here that cannot raise: the
    # original failure must still reach the log even if reporting it fell over.
    Rails.logger.error(
      "[AoEventTriggerJob] Could not report the failed fire of trigger #{trigger&.id} for " \
      "#{subject}: #{handler_error.class}: #{handler_error.message}. Original error: " \
      "#{error.class}: #{error.message}"
    )
  end

  # Whether the condition's one-shot guard is persisted, re-read from the row
  # rather than trusted from memory: the in-memory attribute is set by
  # `condition.update!` before that write is known to have committed, and it is
  # precisely a failure of that write which makes the two disagree.
  def condition_spent?(condition)
    condition.reload.last_triggered_at.present?
  rescue ActiveRecord::RecordNotFound
    # The trigger and its conditions were destroyed by the cleanup behind a
    # successful fire. Nothing survives to re-arm, so treat it as spent.
    true
  rescue => e
    Rails.logger.warn "[AoEventTriggerJob] Could not re-read condition #{condition.id}: #{e.class}: #{e.message}"
    condition.last_triggered_at.present?
  end
end
