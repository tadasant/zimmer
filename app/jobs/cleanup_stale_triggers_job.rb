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
# 2. Dead one-time wakes — every condition is a one-shot, every one of them has
#    been consumed, and the trigger created no session (Trigger#dead_one_time_wake?).
#    A resume consumes a pending wake without firing it, so this shape can never
#    fire again and is collectable the moment it appears, whatever its
#    scheduled_at says. Asked of EVERY one-time wake, not only of those carrying
#    a schedule: a `wake_me_up_when_session_changes_state` watcher consumed by a
#    resume is the same dead row with the same answer
#    (https://github.com/tadasant/zimmer/issues/793).
#
#    Unlike (3), this ground can match a trigger a firing job is still working
#    through: it goes true the instant ScheduleTriggerJob or AoEventTriggerJob
#    advances last_triggered_at, which is before their own sibling cleanup and
#    auto-delete run. That race is benign in both directions — delivery has
#    already happened by then, #destroy_sibling_wakes! reads last_session_id off
#    an in-memory trigger rather than re-finding the row, and a #destroy! of a row
#    this job already deleted affects zero rows without raising. Losing the race
#    just means this job did the auto-delete the firing job was about to do.
# 3. Lapsed one-time schedules — every condition is a one-time schedule whose
#    scheduled_at is more than 1 hour in the past. ScheduleTriggerJob should have
#    destroyed these on its next tick; if they linger, something went wrong.
#
#    What is done about them depends on whether the wake was ever DELIVERED, and
#    that distinction is tadasant/zimmer#855. A lapsed schedule that already fired
#    is residue and is destroyed. A lapsed schedule that never fired is the
#    OPPOSITE: it is a wake somebody is still asleep on, and deleting it erases
#    the only evidence that the wake was owed — which is exactly what happened to
#    trigger 13671, a 02:05Z deadline backstop that never fired and was gone
#    without trace by 03:15Z, leaving its requester in `waiting` for 38.7 hours
#    looking like a session sleeping correctly. Those are PARKED as `failed`
#    instead: visible at /triggers, carrying the reason, re-armable, and — because
#    every firing path and Session#awaiting_scheduled_wake? filter on `enabled` —
#    no longer able to make a stranded session read as a resting one.
#
# Triggers in the `failed` status are exempt from ALL of the sweeps. A failed
# trigger is a deliberate tombstone: ScheduleTriggerJob parked it there precisely
# so the user would see that a wake did not fire and could re-arm it. It lapsed by
# definition — its scheduled_at is in the past and it will never fire on its own
# — so heuristic 3 would match every one of them and quietly delete the evidence
# an hour later, which is the bug this job would be re-introducing rather than
# catching. 2 would take the other half: the one failure that does not re-arm is
# a raise from the cleanup BEHIND a successful fire, which parks the trigger with
# its schedule already consumed. Only the user clears a failed trigger. Parking
# under heuristic 3 puts a trigger into exactly that population, which is why it
# is a terminal answer here and not a state this job revisits.
class CleanupStaleTriggersJob < ApplicationJob
  queue_as :default
  include SingletonSweep

  STALE_SCHEDULE_THRESHOLD = 1.hour

  # What #collect_lapsed_one_time_schedules did on one pass. Parking and
  # destroying are different outcomes with different meanings, so they are
  # counted apart rather than summed into one "cleaned up" number.
  Lapsed = Data.define(:destroyed, :parked)

  def perform
    archived_target_count = destroy_archived_target_triggers
    dead_wake_count = destroy_dead_one_time_wakes
    lapsed = collect_lapsed_one_time_schedules

    total = archived_target_count + dead_wake_count + lapsed.destroyed
    if total > 0 || lapsed.parked > 0
      Rails.logger.info "[CleanupStaleTriggersJob] Destroyed #{total} stale trigger(s) " \
        "(archived target: #{archived_target_count}, dead one-time wake: #{dead_wake_count}, " \
        "lapsed schedule: #{lapsed.destroyed}); parked #{lapsed.parked} undelivered wake(s)"
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

  # Destroys one-time wake triggers that have already been consumed and never
  # delivered anything (Trigger#dead_one_time_wake?).
  #
  # Asked of every one-time wake rather than only of those carrying a schedule.
  # The usual way a trigger reaches this shape is a resume: SessionStateMachine
  # #cancel_pending_one_time_wake_triggers stamps last_triggered_at on every
  # pending one-time wake aimed at the session being resumed, and that stamp
  # closes #schedule_due? — and the session-scoped `ao_event` one-shot guard —
  # permanently. Nothing fires it, so the auto-delete behind a fire never runs.
  # Restricting the question to schedule-carrying triggers left the `ao_event`
  # half of that population uncollected, reading `enabled` with 0 sessions to
  # every reader of /triggers and `search_triggers`
  # (https://github.com/tadasant/zimmer/issues/793).
  #
  # #dead_one_time_wake? is what makes this safe to ask so broadly: it demands
  # that EVERY condition be a consumed one-shot and that the trigger created no
  # session, so a wake with anything still live on it is not touched.
  def destroy_dead_one_time_wakes
    destroyed_ids = []

    Trigger
      .where(reuse_session: true, sessions_created_count: [ 0, nil ])
      .where.not(status: "failed")
      .includes(:trigger_conditions)
      .find_each do |trigger|
        next unless trigger.dead_one_time_wake?

        trigger_id = trigger.id
        trigger.destroy!
        destroyed_ids << trigger_id
        Rails.logger.info "[CleanupStaleTriggersJob] Destroyed dead one-time wake #{trigger_id} — " \
          "consumed without firing, so it can never fire again"
      rescue => e
        Rails.logger.error "[CleanupStaleTriggersJob] Failed to destroy dead one-time wake " \
          "#{trigger.id}: #{e.class}: #{e.message}"
      end

    destroyed_ids.size
  end

  # Deals with one-time schedule triggers whose moment lapsed far enough in the
  # past that ScheduleTriggerJob should already have fired and destroyed them.
  #
  # Two outcomes, and which one a trigger gets is the whole of #855. The ground
  # rests on the fact that #schedule_due? returns false forever once
  # last_triggered_at is set, so no other path will clean these up.
  # (TriggerCondition#one_time_schedule? is NOT that guard — it asks only
  # `condition_type == "schedule" && scheduled_at.present?` and keeps answering
  # true for a consumed condition.)
  #
  # - The wake DELIVERED and only its auto-delete was lost: residue. Destroy it.
  # - The wake NEVER FIRED: it is not residue, it is an undelivered promise, and
  #   somebody may still be asleep on it. Park it `failed` so it stays on
  #   /triggers with the reason, re-armable — and so it stops counting as an
  #   armed wake in Session#awaiting_scheduled_wake?, which filters on `enabled`.
  #   That second effect is the one that matters: while the row sat there
  #   `enabled` and unfired it made a stranded session read as a resting one to
  #   every sweep and every surface.
  #
  # @return [Lapsed]
  def collect_lapsed_one_time_schedules
    now = Time.current
    destroyed_ids = []
    parked_ids = []

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

    return Lapsed.new(destroyed: 0, parked: 0) if candidate_ids.empty?

    Trigger.where(id: candidate_ids).where.not(status: "failed").includes(:trigger_conditions).find_each do |trigger|
      # The ground insists that EVERY condition on the trigger be a lapsed
      # one-time schedule, not just the one that made it a candidate. If the
      # trigger carries any other kind of condition (recurring schedule, slack,
      # an `ao_event`), leave it alone — those keep the trigger legitimate.
      next unless all_conditions_stale_one_time_schedules?(trigger, now)

      trigger_id = trigger.id

      if undelivered_wake?(trigger)
        park_undelivered_wake(trigger)
        parked_ids << trigger_id
        next
      end

      trigger.destroy!
      destroyed_ids << trigger_id
      Rails.logger.info "[CleanupStaleTriggersJob] Destroyed lapsed one-time trigger #{trigger_id} — " \
        "it already fired and its scheduled_at(s) are all > #{STALE_SCHEDULE_THRESHOLD.inspect} in the past"
    rescue => e
      Rails.logger.error "[CleanupStaleTriggersJob] Failed to collect lapsed one-time trigger " \
        "#{trigger.id}: #{e.class}: #{e.message}"
    end

    Lapsed.new(destroyed: destroyed_ids.size, parked: parked_ids.size)
  end

  # Whether this lapsed trigger still owes a wake nobody ever got.
  #
  # Any unconsumed one-shot condition is enough: the trigger fires per condition,
  # so one with `last_triggered_at` still nil is a wake that was never delivered.
  # `sessions_created_count` is the second half — a trigger that spawned a session
  # did its job, whatever its conditions say.
  def undelivered_wake?(trigger)
    return false unless trigger.sessions_created_count.to_i.zero?

    trigger.trigger_conditions.any? do |condition|
      (condition.one_time_schedule? || condition.session_scoped_ao_event?) &&
        condition.last_triggered_at.nil?
    end
  end

  # Park an undelivered wake as `failed` and say so, once, out loud.
  #
  # An alert rather than a log line because this is a wake that did not happen:
  # the requester is, by construction, either already resumed by something else
  # or sitting in `waiting` with nothing to wake it. StrandedSleepRescue is what
  # gets that session moving again; this is what tells a human it had to.
  def park_undelivered_wake(trigger)
    scheduled = trigger.trigger_conditions.filter_map { |c| c.scheduled_at.presence }.join(", ")
    reason = "This one-time wake never fired. Its scheduled time (#{scheduled}) lapsed more than " \
             "#{STALE_SCHEDULE_THRESHOLD.inspect} ago and ScheduleTriggerJob never delivered it, so " \
             "Zimmer parked it here rather than deleting the only record that a wake was owed."

    unless trigger.mark_failed(reason)
      Rails.logger.error "[CleanupStaleTriggersJob] Could not park undelivered wake #{trigger.id}"
      return
    end

    Rails.logger.warn "[CleanupStaleTriggersJob] Parked undelivered one-time wake #{trigger.id} as " \
      "failed — scheduled for #{scheduled}, never fired (requester session " \
      "#{trigger.last_session_id || 'none'})"

    AlertService.raise_alert(
      "A one-time wake never fired",
      details: "Trigger '#{trigger.name}' (ID: #{trigger.id}) was scheduled for #{scheduled} and " \
               "never fired. It has been marked *failed* and left in place at " \
               "#{trigger_url(trigger.id)} so it stays visible and can be re-armed.\n\n" \
               "Requester session: #{trigger.last_session_id || 'none'}. If that session is still " \
               "in `waiting`, StrandedSleepRescue will resume it within the hour.",
      source: "CleanupStaleTriggersJob",
      dedup_key: "undelivered_wake_#{trigger.id}"
    )
  rescue => e
    Rails.logger.error "[CleanupStaleTriggersJob] Could not report parked wake #{trigger.id}: " \
      "#{e.class}: #{e.message}"
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
