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
# 2. Triggers with at least one one-time schedule condition whose scheduled_at
#    is more than 1 hour in the past. ScheduleTriggerJob should have destroyed
#    these on its next tick; if they linger, something went wrong.
class CleanupStaleTriggersJob < ApplicationJob
  queue_as :default

  STALE_SCHEDULE_THRESHOLD = 1.hour

  def perform
    archived_target_count = destroy_archived_target_triggers
    stale_schedule_count = destroy_stale_one_time_schedule_triggers

    total = archived_target_count + stale_schedule_count
    if total > 0
      Rails.logger.info "[CleanupStaleTriggersJob] Destroyed #{total} stale trigger(s) " \
        "(archived target: #{archived_target_count}, lapsed one-time schedule: #{stale_schedule_count})"
    end
  end

  private

  # Destroys one-time-reuse triggers whose target session is archived.
  # Excludes resuscitate_archived triggers — those are an explicit opt-in
  # to wake archived sessions.
  def destroy_archived_target_triggers
    candidates = Trigger
      .where(reuse_session: true, resuscitate_archived: false)
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

  # Destroys triggers whose ONLY conditions are one-time schedules whose
  # scheduled_at is far enough in the past that ScheduleTriggerJob should
  # already have fired and destroyed them. Surviving triggers indicate a
  # bug or interrupted firing — they will never fire on their own (because
  # one_time_schedule? returns false once last_triggered_at is set, and
  # schedule_due? returns false if last is set), so nothing else will clean
  # them up.
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

    Trigger.where(id: candidate_ids).includes(:trigger_conditions).find_each do |trigger|
      # Only destroy if EVERY condition is a one-time schedule whose
      # scheduled_at is past the cutoff (timezone-aware). If the trigger has
      # any other kind of condition (recurring schedule, slack, ao_event),
      # leave it alone — those keep the trigger legitimate.
      next unless all_conditions_stale_one_time_schedules?(trigger, now)

      trigger_id = trigger.id
      trigger.destroy!
      destroyed_ids << trigger_id
      Rails.logger.info "[CleanupStaleTriggersJob] Destroyed lapsed one-time trigger #{trigger_id} — " \
        "scheduled_at(s) all > #{STALE_SCHEDULE_THRESHOLD.inspect} in the past"
    rescue => e
      Rails.logger.error "[CleanupStaleTriggersJob] Failed to destroy lapsed trigger #{trigger.id}: " \
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
