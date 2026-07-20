# frozen_string_literal: true

# Job that checks schedule trigger conditions and fires them when due.
#
# This job runs on a cron schedule (every minute) and:
# 1. Iterates through all schedule-type trigger conditions on enabled triggers
# 2. Checks if each condition's schedule is due
# 3. Creates sessions (or reuses existing ones) for due conditions
# 4. Updates the condition's last_triggered_at timestamp
class ScheduleTriggerJob < ApplicationJob
  # Runs on the dedicated `triggers` queue (alongside AoEventTriggerJob) rather
  # than `default`. This is the time-based trigger-firing path — it fires the
  # scheduled "wake me later" backstops that keep waiting sessions moving — so it
  # is just as latency-sensitive as ao_event wakes and must not be starved behind
  # the `default` queue's periodic/bulk backlog.
  queue_as :triggers

  def perform
    # Wrap the entire iteration in an AlertBatcher scope so that a catalog
    # change affecting many triggers in one tick collapses into a single
    # aggregated Slack message instead of one-alert-per-trigger.
    AlertBatcher.with_batch do
      TriggerCondition.schedule
        .joins(:trigger)
        .where(triggers: { status: "enabled" })
        .includes(:trigger)
        .find_each do |condition|
        process_condition(condition)
      rescue => e
        Rails.logger.error "[ScheduleTriggerJob] Error processing condition #{condition.id}: #{e.message}"
        AlertService.raise_alert(
          "Schedule trigger error",
          details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' (ID: #{condition.trigger_id}) failed:\n#{e.message}",
          source: "ScheduleTriggerJob",
          dedup_key: "schedule_trigger_condition_#{condition.id}"
        )
      end
    end
  end

  private

  def process_condition(condition)
    return unless condition.schedule_due?

    trigger = condition.trigger

    Rails.logger.info "[ScheduleTriggerJob] Schedule condition #{condition.id} on trigger #{trigger.id} (#{trigger.name}) is due, creating session"

    # Interpolate the prompt template with time/date variables
    prompt = trigger.interpolate_prompt

    # Create or reuse session
    session = trigger.create_session!(prompt: prompt)

    # A burst-suppressed fire delivered NOTHING. Treat it like the dropped-wake
    # case below: don't advance the condition (so the schedule stays due and
    # fires for real once the burst ends) and don't auto-delete a one-time
    # trigger that never did its job.
    if trigger.last_fire_burst_suppressed?
      Rails.logger.info "[ScheduleTriggerJob] Condition #{condition.id} on trigger #{trigger.id} is burst-suppressed — leaving it due; it will fire when the burst ends"
      return
    end

    # Update condition's last_triggered_at
    condition.update!(last_triggered_at: Time.current)

    trigger_id = trigger.id
    trigger_name = trigger.name

    if condition.one_time_schedule?
      # Destroy sibling wake triggers ONLY on the success path — the failure
      # path below also destroys one-time triggers, but the wake never actually
      # delivered (e.g., create_session! raised), so we shouldn't void other
      # wakes the agent set up to handle the same requester.
      #
      # Additionally guard against the silent-drop race: if the wake fired
      # while the requester session was still running and #follow_up_session!
      # couldn't queue the message (recurring trigger with enqueue_messages
      # off), the wake was dropped. Destroying siblings in that case would
      # leave the requester with no wakes at all. Keep this trigger and its
      # siblings in place so a later wake (or the deadline backstop) can
      # actually deliver.
      if trigger.last_follow_up_dropped?
        Rails.logger.info "[ScheduleTriggerJob] One-time trigger #{trigger_id} (#{trigger_name}) fired but delivery was dropped (requester still running, no enqueue) — preserving siblings and skipping auto-delete"
      else
        sibling_count = trigger.destroy_sibling_wakes!
        requester_id = trigger.last_session_id
        trigger.destroy!
        Rails.logger.info "[ScheduleTriggerJob] One-time trigger #{trigger_id} (#{trigger_name}) auto-deleted after firing"
        if sibling_count > 0
          Rails.logger.info "[ScheduleTriggerJob] Destroyed #{sibling_count} sibling wake-up trigger(s) for requester session #{requester_id}"
        end
      end
    end

    if session
      Rails.logger.info "[ScheduleTriggerJob] Created/reused session #{session.id} for trigger #{trigger_id}"
    else
      # Burst suppression already returned above, so nil here means a one-time
      # reuse trigger whose target session is gone. Not an error.
      Rails.logger.info "[ScheduleTriggerJob] Trigger #{trigger_id} fired but created no session (no reusable target session)"
    end
  rescue => e
    # Always advance last_triggered_at to prevent infinite retry loops.
    # Without this, a persistent error (e.g. invalid MCP server reference)
    # causes the condition to fire every minute indefinitely. (For one-time
    # triggers we destroy the trigger below, which cascade-destroys this
    # condition — but advancing first is harmless and keeps the recurring
    # path simple.)
    unless condition.update(last_triggered_at: Time.current)
      Rails.logger.error "[ScheduleTriggerJob] Failed to advance last_triggered_at for condition #{condition.id}: #{condition.errors.full_messages.join(", ")}"
    end

    # Capture identifiers before any potential destroy so log/alert messages
    # remain meaningful even after the trigger row is gone.
    trigger_id = condition.trigger&.id || condition.trigger_id
    trigger_name = condition.trigger&.name || "unknown"
    is_one_time = condition.one_time_schedule?

    # One-time triggers must be deleted even on failure — otherwise they
    # remain in the database forever, never firing again (last_triggered_at
    # was just set, so schedule_due? returns false). Deletion keeps the
    # triggers list clean of single-shot tombstones.
    if is_one_time
      condition.trigger&.destroy!
      Rails.logger.info "[ScheduleTriggerJob] One-time trigger #{trigger_id} (#{trigger_name}) auto-deleted after failed firing"
    end

    backtrace = e.backtrace&.first(5)&.join("\n")

    retry_note = if is_one_time
      "One-time trigger has been auto-deleted. Re-create it manually to retry."
    else
      "The trigger will attempt again on its next scheduled interval."
    end

    Rails.logger.error "[ScheduleTriggerJob] Failed to create session for condition #{condition.id} on trigger #{trigger_id} (#{trigger_name}): #{e.message}\n#{backtrace}"

    details_body = "Condition #{condition.id} on trigger '#{trigger_name}' (ID: #{trigger_id}) failed to create session:\n#{e.class}: #{e.message}"
    details_body += "\n\nBacktrace:\n#{backtrace}" if backtrace.present?
    details_body += "\n\nlast_triggered_at advanced to prevent infinite retries. #{retry_note}"

    AlertService.raise_alert(
      "Schedule trigger session creation failed",
      details: details_body,
      source: "ScheduleTriggerJob",
      dedup_key: "schedule_trigger_session_#{trigger_id}"
    )
  end
end
