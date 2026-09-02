# frozen_string_literal: true

# Periodic safety net for one-time wake-up triggers that became orphaned without
# a sibling firing. Sibling cleanup in AoEventTriggerJob and ScheduleTriggerJob
# handles the common "first wake fires, kill the rest" path. This job catches
# the residue: triggers whose target session was archived (or whose deadline
# already lapsed) without any sibling ever firing the cleanup.
#
# Heuristics:
# 1. One-time-reuse triggers whose target session is archived. The session is
#    off the user's homepage and the wake is moot. Triggers with
#    resuscitate_archived = true are exempt — those explicitly opt into
#    waking archived sessions.
# 2. Triggers with at least one one-time schedule condition, collected on
#    either of two grounds:
#    a. The wake is already dead — every condition is a one-shot, every one of
#       them has been consumed, and it created no session (Trigger#dead_one_time_wake?).
#       A resume consumes a pending wake without firing it, so this shape can
#       never fire again and is collectable the moment it appears, whatever its
#       scheduled_at says.
#    b. Every condition is a one-time schedule whose scheduled_at is more than
#       1 hour in the past. ScheduleTriggerJob should have destroyed these on its
#       next tick; if they linger, something went wrong.
#
# Triggers in the `failed` status are exempt from BOTH sweeps. A failed trigger
# is a deliberate tombstone: ScheduleTriggerJob parked it there precisely so the
# user would see that a wake did not fire and could re-arm it. It lapsed by
# definition — its scheduled_at is in the past and it will never fire on its own
# — so heuristic 2b would match every one of them and quietly delete the evidence
# an hour later, which is the bug this job would be re-introducing rather than
# catching. 2a would take the other half: the one failure that does not re-arm is
# a raise from the cleanup BEHIND a successful fire, which parks the trigger with
# its schedule already consumed. Only the user clears a failed trigger.
class CleanupStaleTriggersJob < ApplicationJob
  queue_as :default
  include SingletonSweep

  STALE_SCHEDULE_THRESHOLD = 1.hour

  def perform
    archived_target_count = destroy_archived_target_triggers
    stale_schedule_count = destroy_stale_one_time_schedule_triggers

    total = archived_target_count + stale_schedule_count
    if total > 0
      Rails.logger.info "[CleanupStaleTriggersJob] Destroyed #{total} stale trigger(s) " \
        "(archived target: #{archived_target_count}, dead one-time schedule: #{stale_schedule_count})"
    end
  end

  private

  # Destroys one-time-reuse triggers whose target session is archived.
  # Excludes resuscitate_archived triggers — those are an explicit opt-in
  # to wake archived sessions.
  def destroy_archived_target_triggers
    candidates = Trigger
      .where(reuse_session: true, resuscitate_archived: false)
      .where.not(status: "failed")
      .where.not(last_session_id: nil)
      .joins(:last_session)
      .where(last_session: { status: "archived" })
      .includes(:trigger_conditions)

    destroyed_ids = []
    candidates.find_each do |trigger|
      next unless trigger.one_time_reuse_trigger?

      trigger_id = trigger.id
      session_id = trigger.last_session_id
      trigger.destroy!
      destroyed_ids << trigger_id
      Rails.logger.info "[CleanupStaleTriggersJob] Destroyed orphan trigger #{trigger_id} — " \
        "target session #{session_id} is archived"
    rescue => e
      Rails.logger.error "[CleanupStaleTriggersJob] Failed to destroy trigger #{trigger.id}: " \
        "#{e.class}: #{e.message}"
    end

    destroyed_ids.size
  end

  # Destroys one-time schedule triggers that will never fire again, on either
  # of the two grounds described at the top of this file: the wake is already
  # dead (consumed without firing), or its scheduled_at lapsed far enough in the
  # past that ScheduleTriggerJob should already have fired and destroyed it.
  #
  # Both grounds rest on the same fact: #schedule_due? returns false forever
  # once last_triggered_at is set, so no other path will clean these up.
  # (TriggerCondition#one_time_schedule? is NOT that guard — it asks only
  # `condition_type == "schedule" && scheduled_at.present?` and keeps answering
  # true for a consumed condition.) That is exactly why a consumed wake needs a
  # collectability ground of its own: with nothing left to fire it, the lapsed
  # ground is all that reaches it, and that ground is a function of when the
  # wake was *scheduled* rather than of when it died. A wake set 12 hours out
  # and consumed five minutes later would sit in the list, `enabled` and
  # apparently armed, for the remaining ~13 hours.
  def destroy_stale_one_time_schedule_triggers
    now = Time.current
    destroyed_ids = []

    # SQL pre-filter narrows to triggers with at least one one-time schedule
    # condition. We deliberately do NOT filter by scheduled_at lex order in
    # SQL — the value can carry an arbitrary UTC offset (or a separate
    # timezone field), so lex comparison would silently misclassify edge
    # cases. Authoritative comparison happens in Ruby via
    # ActiveSupport::TimeZone parsing below — same logic as
    # TriggerCondition#schedule_due?. Candidate volume is bounded (one-time
    # schedules normally fire and self-destruct within a minute), so the
    # full scan is cheap.
    candidate_ids = TriggerCondition
      .schedule
      .where("(configuration->>'scheduled_at') IS NOT NULL")
      .pluck(:trigger_id)
      .uniq

    return 0 if candidate_ids.empty?

    Trigger.where(id: candidate_ids).where.not(status: "failed").includes(:trigger_conditions).find_each do |trigger|
      # Both grounds insist that EVERY condition on the trigger be dead, not
      # just the schedule that made it a candidate. If the trigger carries any
      # other kind of condition (recurring schedule, slack, an unconsumed
      # ao_event), leave it alone — those keep the trigger legitimate.
      reason =
        if trigger.dead_one_time_wake?
          "consumed without firing — it can never fire again"
        elsif all_conditions_stale_one_time_schedules?(trigger, now)
          "scheduled_at(s) all > #{STALE_SCHEDULE_THRESHOLD.inspect} in the past"
        end
      next if reason.nil?

      trigger_id = trigger.id
      trigger.destroy!
      destroyed_ids << trigger_id
      Rails.logger.info "[CleanupStaleTriggersJob] Destroyed dead one-time trigger #{trigger_id} — #{reason}"
    rescue => e
      Rails.logger.error "[CleanupStaleTriggersJob] Failed to destroy dead one-time trigger #{trigger.id}: " \
        "#{e.class}: #{e.message}"
    end

    destroyed_ids.size
  end

  def all_conditions_stale_one_time_schedules?(trigger, now)
    conditions = trigger.trigger_conditions
    return false if conditions.empty?

    conditions.all? do |c|
      next false unless c.one_time_schedule? && c.scheduled_at.present?
      parsed = parse_scheduled_at(c)
      parsed && (now - parsed) > STALE_SCHEDULE_THRESHOLD
    end
  end

  # Parse scheduled_at honoring the condition's configured timezone — matches
  # TriggerCondition#schedule_due? semantics so we never destroy a condition
  # this job would consider not-yet-due.
  def parse_scheduled_at(condition)
    zone = ActiveSupport::TimeZone[condition.schedule_timezone] || ActiveSupport::TimeZone["UTC"]
    zone.parse(condition.scheduled_at)
  rescue ArgumentError
    nil
  end
end
