# frozen_string_literal: true

# Fires `system_event` trigger conditions when the DEPLOYMENT changes state.
#
# The sibling of AoEventTriggerJob, and deliberately a separate job because the
# events are a different shape. An ao_event is "session #N transitioned", so every
# decision that job makes — watched-session scoping, the loop guard that stops a
# trigger firing on the session it created, the is_autonomous filter — is about a
# session. A system event has no session at all: `quota_available` is the account
# pool recovering, which belongs to the fleet rather than to any one row.
#
# Currently supports:
# - quota_available: the account pool went from serving nothing to serving
#   something. See QuotaAvailabilityMonitor, which owns the edge detection.
# - no_sessions_in_progress: the deployment has been RUNNING fewer sessions than
#   its configured ceiling for the whole of its configured stretch. See
#   FleetIdleMonitor, which owns the latch and the cooldown under it.
#
# System events are broadcast by nature — every enabled trigger carrying a
# matching condition fires — and recurring, so a condition is never spent and the
# trigger is never auto-deleted. A fire that raises alerts and leaves the trigger
# enabled: the next recovery is a fresh chance, and parking the trigger would
# silently stop every future wake.
#
# A pass that HANDLES nothing — nothing listening, every fire raised, every fire
# burst-suppressed — puts the edge back through QuotaAvailabilityMonitor.rearm!,
# so the next sweep fires again. Without that, a deleted or broken fleet trigger
# would silently consume the one recovery the parked sessions were waiting for.
#
# "Handled" is deliberately wider than "spawned a session". A trigger with
# `skip_if_pending_session` on can answer the event by pointing at the session it
# already spawned, and that session — queued, holding the same prompt — is the
# thing the recovery was for. Counting that as undelivered would re-arm the edge,
# so the next sweep would find the level false against an available pool, call it
# a fresh recovery, fire, skip again and re-arm again: one wasted fire every
# sweep for as long as the pending session stays pending.
class SystemEventTriggerJob < ApplicationJob
  # Same queue as AoEventTriggerJob and for the same reason: a wake that arrives
  # late is a wake that did not happen. The pool recovering is the moment the
  # fleet has capacity again, and the session this fires decides who uses it.
  queue_as :triggers

  def perform(event_name)
    unless TriggerCondition::SYSTEM_EVENT_NAMES.include?(event_name)
      Rails.logger.warn "[SystemEventTriggerJob] Unknown event: #{event_name}"
      return
    end

    conditions = TriggerCondition
      .where(condition_type: "system_event")
      .joins(:trigger)
      .where(triggers: { status: "enabled" })
      .where("trigger_conditions.configuration @> ?", { event_name: event_name }.to_json)
      .includes(:trigger)

    if conditions.empty?
      Rails.logger.info "[SystemEventTriggerJob] No enabled trigger listens for #{event_name}"
      return rearm(event_name)
    end

    handled = 0
    AlertBatcher.with_batch do
      conditions.find_each { |condition| handled += 1 if fire(condition, event_name) }
    end

    # Nobody acted on the event. For `quota_available` that means the parked
    # sessions it exists to wake are still parked, so put the edge back rather
    # than spending it on a fire that did nothing — see
    # QuotaAvailabilityMonitor.rearm!.
    rearm(event_name) if handled.zero?
  end

  private

  def fire(condition, event_name)
    trigger = condition.trigger

    session = trigger.create_session!(prompt: trigger.interpolate_prompt(event: event_label(event_name)))

    # A burst-suppressed fire delivered nothing, so it must not be recorded as a
    # fire: advancing last_triggered_at would make the trigger list claim a wake
    # that never happened.
    if trigger.last_fire_burst_suppressed?
      Rails.logger.info(
        "[SystemEventTriggerJob] Trigger #{trigger.id} is burst-suppressed for #{event_name} — " \
        "no session created"
      )
      return false
    end

    # A dedup-skipped fire is HANDLED, not dropped: a session this trigger already
    # spawned is still queued with the same prompt, so the event has a listener —
    # it just does not need a second one. Return true so the pass does not re-arm
    # the edge, and leave last_triggered_at alone, because no new fire happened.
    if trigger.last_fire_skipped_for_pending_session?
      pending = trigger.last_fire_pending_session
      Rails.logger.info(
        "[SystemEventTriggerJob] Trigger #{trigger.id} skipped #{event_name} — session #{pending.id} " \
        "(#{pending.status}) is still pending and already carries this intent"
      )
      return true
    end

    condition.update!(last_triggered_at: Time.current)
    Rails.logger.info(
      "[SystemEventTriggerJob] Fired trigger #{trigger.id} for #{event_name}, " \
      "created session #{session&.id || 'none'}"
    )
    session.present?
  rescue => e
    Rails.logger.error(
      "[SystemEventTriggerJob] Error firing trigger #{trigger&.id} for #{event_name}: " \
      "#{e.message}\n#{e.backtrace&.first(5)&.join("\n")}"
    )

    AlertService.raise_alert(
      "System-event trigger failed to fire",
      details: "Condition #{condition.id} on trigger '#{trigger&.name}' (ID: #{trigger&.id}) failed " \
               "to fire for #{event_name}. This is a broadcast (recurring) condition: it stays " \
               "enabled and will fire on the next matching event.",
      source: "SystemEventTriggerJob",
      dedup_key: "system_event_trigger_#{trigger&.id}",
      error: e
    )
    false
  rescue => handler_error
    Rails.logger.error(
      "[SystemEventTriggerJob] Could not report the failed fire of trigger #{trigger&.id}: " \
      "#{handler_error.class}: #{handler_error.message}"
    )
    false
  end

  # Only `quota_available` gets its edge put back, and the asymmetry is
  # deliberate. That edge exists to wake sessions that are still parked, so a
  # fire nobody listened to leaves real work stranded and the next sweep should
  # try again.
  #
  # `no_sessions_in_progress` has nobody waiting on it: an idle fleet with no
  # enabled trigger is a deployment that has not asked for idle-time work.
  # Re-arming its latch would fire once per sweep for as long as the quiet
  # lasts, which is the loop FleetIdleMonitor's latch exists to prevent — so an
  # undelivered fire is simply spent, and the next one comes after the fleet has
  # actually run something.
  def rearm(event_name)
    QuotaAvailabilityMonitor.rearm! if event_name == QuotaAvailabilityMonitor::EVENT_NAME
    nil
  end

  def event_label(event_name)
    case event_name
    when "quota_available"
      "The Claude Code account pool has capacity again"
    when "no_sessions_in_progress"
      setting = AppSetting.current
      "The fleet has room for more work: fewer than " \
        "#{FleetIdleMonitor.max_sessions(setting)} sessions running for " \
        "#{FleetIdleMonitor.idle_threshold(setting).inspect}"
    else
      event_name.to_s.humanize
    end
  end
end
