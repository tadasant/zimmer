# frozen_string_literal: true

# Job that checks schedule trigger conditions and fires them when due.
#
# This job runs on a cron schedule (every minute) and:
# 1. Iterates through all schedule-type trigger conditions on enabled triggers
# 2. Checks if each condition's schedule is due
# 3. Creates sessions (or reuses existing ones) for due conditions
# 4. Updates the condition's last_triggered_at timestamp
#
# A fire that raises never destroys anything. A one-time trigger is parked as
# `failed` — visible, skipped by every firing path, and re-armable unless the
# schedule was already consumed — rather than deleted along with the wake it
# never delivered. See the rescue in #process_condition.
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
          details: "Condition #{condition.id} on trigger '#{condition.trigger&.name}' (ID: #{condition.trigger_id}) failed.",
          source: "ScheduleTriggerJob",
          dedup_key: "schedule_trigger_condition_#{condition.id}",
          error: e
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
      # Burst suppression already returned above, so nil here means either a
      # one-time reuse trigger whose target session is gone or a
      # `skip_if_pending_session` trigger whose previous session is still
      # pending. Neither is an error, and both are spent: the schedule advanced,
      # because the next occurrence is a fresh chance and re-running this one
      # would only ask the same question again.
      reason = if trigger.last_fire_skipped_for_pending_session?
                 "session #{trigger.last_fire_pending_session.id} is still pending"
      else
                 "no reusable target session"
      end
      Rails.logger.info "[ScheduleTriggerJob] Trigger #{trigger_id} fired but created no session (#{reason})"
    end
  rescue => e
    trigger = condition.trigger
    trigger_id = trigger&.id || condition.trigger_id
    trigger_name = trigger&.name || "unknown"
    is_one_time = condition.one_time_schedule?

    # Both branches below must leave the condition NOT due on the next tick —
    # otherwise a persistent error (an unhealable agent root, an invalid MCP
    # reference) fires every minute forever. They solve it differently because
    # they want different things afterwards.
    #
    # One-time: park the trigger as `failed`. Every firing path filters on
    #   `status: "enabled"`, so a failed trigger is skipped just as a disabled
    #   one is — the retry loop is closed by the STATUS, which means
    #   last_triggered_at can be left alone. That is deliberate: the schedule
    #   stays due, so re-enabling the trigger (the "Re-arm" button, or
    #   action_trigger's toggle) fires it for real on the next tick with no
    #   further edits. The trigger stays in the list either way, carrying the
    #   error that stopped it, instead of vanishing with the wake it owed.
    #   Parking is per-TRIGGER while the failure is per-CONDITION, so a trigger
    #   that also carries other conditions stops firing on those too — which
    #   bounds the blast radius to one trigger, and a one-time schedule sharing a
    #   trigger with anything else is not a shape Zimmer's own wake tools create.
    #
    # Recurring: advance last_triggered_at and leave the trigger enabled. A
    #   recurring schedule is expected to survive a bad tick and try again on
    #   its next interval, which is exactly what the timestamp bump gives it.
    #
    # One case does not re-arm, and is not claimed to: a raise from the cleanup
    # that FOLLOWS a successful fire (sibling destruction, the auto-delete)
    # lands here with the condition already advanced. The session exists, so
    # re-firing would duplicate it. #spent_one_shot_wake? is what the alert
    # and the UI read to tell the two apart instead of promising a re-arm that
    # would deliver nothing.
    parked = false
    rearmable = false
    if is_one_time && trigger
      parked = trigger.mark_failed(e)
      if parked
        rearmable = !trigger.spent_one_shot_wake?
        Rails.logger.error "[ScheduleTriggerJob] One-time trigger #{trigger_id} (#{trigger_name}) marked failed after a failed firing — left in place so it stays visible#{rearmable ? ' and can be re-armed' : ' (schedule already consumed; re-arming will not re-fire it)'}"
      end
    end

    # Recurring conditions, and the belt-and-braces case where parking the
    # trigger did not persist: fall back to the timestamp guard so a failure
    # can never leave the condition firing on every tick.
    unless parked
      unless condition.update(last_triggered_at: Time.current)
        Rails.logger.error "[ScheduleTriggerJob] Failed to advance last_triggered_at for condition #{condition.id}: #{condition.errors.full_messages.join(", ")}"
      end
    end

    backtrace = e.backtrace&.first(5)&.join("\n")

    retry_note = if is_one_time && parked && rearmable
      "The one-time trigger is marked *failed* and left in place — it will not fire again on its own. " \
      "Re-enable it at #{trigger_url(trigger_id)} to re-arm it (it fires within a minute)."
    elsif is_one_time && parked
      "The one-time trigger is marked *failed* and left in place, but its schedule was already consumed " \
      "before the error — the session may well have been created and only the cleanup after it failed. " \
      "Re-arming will NOT re-fire it. Check #{trigger_url(trigger_id)} and the sessions it spawned."
    elsif is_one_time
      "The one-time trigger could not be marked failed; last_triggered_at was advanced instead to prevent " \
      "infinite retries. Re-create it manually to retry."
    else
      "last_triggered_at advanced to prevent infinite retries. The trigger will attempt again on its next scheduled interval."
    end

    Rails.logger.error "[ScheduleTriggerJob] Failed to create session for condition #{condition.id} on trigger #{trigger_id} (#{trigger_name}): #{e.message}\n#{backtrace}"

    AlertService.raise_alert(
      "Schedule trigger session creation failed",
      details: "Condition #{condition.id} on trigger '#{trigger_name}' (ID: #{trigger_id}) failed to create a session.\n\n" \
               "#{retry_note}",
      source: "ScheduleTriggerJob",
      dedup_key: "schedule_trigger_session_#{trigger_id}",
      error: e
    )
  end
end
