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
#
# System events are broadcast by nature — every enabled trigger carrying a
# matching condition fires — and recurring, so a condition is never spent and the
# trigger is never auto-deleted. A fire that raises alerts and leaves the trigger
# enabled: the next recovery is a fresh chance, and parking the trigger would
# silently stop every future wake.
#
# A pass that delivers NO session — nothing listening, every fire raised, every
# fire burst-suppressed — puts the edge back through
# QuotaAvailabilityMonitor.rearm!, so the next sweep fires again. Without that,
# a deleted or broken fleet trigger would silently consume the one recovery the
# parked sessions were waiting for.
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

    delivered = 0
    AlertBatcher.with_batch do
      conditions.find_each { |condition| delivered += 1 if fire(condition, event_name) }
    end

    # Nobody acted on the event. For `quota_available` that means the parked
    # sessions it exists to wake are still parked, so put the edge back rather
    # than spending it on a fire that delivered nothing — see
    # QuotaAvailabilityMonitor.rearm!.
    rearm(event_name) if delivered.zero?
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

  # Only `quota_available` carries an edge that can be spent; a future system
  # event with no stored level has nothing to put back.
  def rearm(event_name)
    QuotaAvailabilityMonitor.rearm! if event_name == QuotaAvailabilityMonitor::EVENT_NAME
    nil
  end

  def event_label(event_name)
    case event_name
    when "quota_available"
      "The Claude Code account pool has capacity again"
    else
      event_name.to_s.humanize
    end
  end
end
