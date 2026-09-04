# frozen_string_literal: true

# Re-arms the per-session wakes that https://github.com/tadasant/zimmer/issues/600
# parked `failed`, and that the fix for it (#834) deliberately did not reach back for.
#
# THE POINT OF THIS FILE: before #834, a wake armed for a session that resolves to
# no catalog agent root labelled itself with the *runtime* name — `"claude_code"`,
# which is not a root — and `Trigger#create_session!` resolved `agent_root_name`
# before it reached the reuse path. The fire raised
# `AgentRootsConfig::AgentRootNotFoundError` on a name it was never going to use,
# `ScheduleTriggerJob` (or `AoEventTriggerJob`) parked the trigger `failed`, and
# every firing path filters on `status: "enabled"`. The wake it owed was gone.
#
# #834 fixed the arming, not the wreckage. `Trigger::STATUSES` calls `failed` a
# state the user clears, `CleanupStaleTriggersJob` exempts it from every sweep, and
# the per-trigger **Re-arm** button on /triggers is the only route — which needs a
# human who already knows which rows to look at and why. So the repair ships with
# the deploy, as AGENTS.md ("ops actions ship with the deploy") requires, and what
# it did is a row in `post_deploy_task_runs` rather than somebody's recollection.
#
# WHAT THIS ADDS OVER `StrandedSleepRescue`
#
# `StrandedSleepRescue` (#855) already rescues the SESSION: every five minutes it
# takes the `waiting` rows that have run, carry no marker, have nothing queued,
# and are not #awaiting_scheduled_wake?, and nudges them — so a session bricked by
# #600 is no longer left asleep indefinitely. It does nothing for the TRIGGER: the
# parked row stays parked, and the specific prompt the wake carried is never
# delivered. This task delivers that prompt, to the sessions that are still
# waiting for it and no other.
#
# WHAT IT SELECTS, AND WHY EACH TERM IS THERE
#
#   status: "failed"          the parked state; nothing else needs re-arming
#   last_error LIKE …         the #600 signature. Without it this would also catch
#                             the wakes CleanupStaleTriggersJob parks for lapsing
#                             unfired, and every other unrelated failure.
#   reuse_session + a target  a wake, not a spawner
#   #one_time_reuse_trigger?  EVERY condition is a one-shot — a one-time schedule
#                             or a session-scoped ao_event. Both shapes had the
#                             identical bug (#834 fixed both), and a trigger that
#                             mixes a one-shot with a recurring condition is not a
#                             wake and is not Zimmer's own tools' output.
#   !#spent_one_shot_wake?    the one-shot has not already been consumed. A trigger
#                             that raised in the cleanup AFTER a successful fire
#                             created its session already; re-arming it would
#                             deliver a second one. This is the same predicate
#                             /triggers reads before offering the Re-arm button.
#   target still `waiting`    the symptom. A target that is `running` or
#                             `needs_input` has already moved on, and a prompt
#                             delivered into it now is a stale interruption.
#                             `archived` is excluded deliberately even though a
#                             `resuscitate_archived` trigger's own fire would
#                             unarchive it: bringing an archived session back is a
#                             bigger act than delivering a late wake, and not one
#                             to take unattended on rows nobody has looked at.
#   target not user-paused    `Trigger#reusable_session?` refuses a session a human
#                             took control of. A fire against one returns without
#                             following up, and `ScheduleTriggerJob` then destroys
#                             the one-time trigger — so re-arming would delete the
#                             wake and deliver nothing. Left parked instead, where
#                             a human can still see it.
#   no live wake already      `Session#awaiting_scheduled_wake?` — the same
#                             predicate `StrandedSleepRescue` uses to decide a
#                             session is resting on purpose. A session that was
#                             bricked, rescued by that sweep, and then armed a
#                             FRESH wake is `waiting` for a reason. Re-arming the
#                             stale trigger would fire it immediately (it is
#                             past-dated, so it is due), and the delivery would
#                             then take `Trigger#destroy_sibling_wakes!` through
#                             the live wake — waking the session early and deleting
#                             the wake it was actually waiting on, both silently.
#                             The bricked trigger itself cannot make this true: the
#                             predicate reads only `enabled` triggers.
#
# PAST-DATED WAKES ARE RE-ARMED AS THEY ARE, NOT RETIMED.
#
# By construction almost every row here is past-dated — it was parked when it came
# due, which was before this deploy. Retiming was considered and rejected:
#
#   * A one-time schedule that has passed is IMMEDIATELY due.
#     `TriggerCondition#schedule_due?` answers `now >= parsed` for a one-time
#     schedule, so `ScheduleTriggerJob` fires it on its next tick — within a
#     minute. Delivering an overdue wake now is the whole point; pushing it into
#     the future would only make a late wake later.
#   * The guard in `Sessions::ScheduleWakeUp` is about a different moment.
#     It rejects a past-dated `wake_at` at CREATION, when the target session is not
#     yet asleep — a `running` session only gets `pending_sleep`, so a condition
#     that is due on the very next tick can fire before the sleep lands, find
#     nothing to follow up into, and drop. Here the target is already `waiting`
#     (selected on it above), so the fire takes the reuse path and resumes it.
#     There is no race to lose.
#   * `scheduled_at` is also the record of when the wake was asked for. Rewriting
#     it would destroy that, on top of the `last_error` the re-arm already sheds.
#
# A session-scoped ao_event wake gets the weaker guarantee its own Re-arm button
# gives: re-enabling restores it to armed, and it delivers on the watched session's
# NEXT transition into the watched state. If that session has already made its last
# one, the wake stays armed and never fires. That is not a regression — the trigger
# was dead either way — and the stats below break the two shapes out so a human can
# see which rows got the weaker one.
#
# IDEMPOTENT, structurally: `Trigger#enable!` moves the row off `failed`, so it no
# longer matches the first term of the predicate. A second run selects nothing and
# writes nothing. It also never re-arms a trigger a human has already cleared, for
# the same reason.
#
# EVIDENCE. `Trigger#clear_failure_state_when_leaving_failed` discards `failed_at`
# and `last_error` the moment the row leaves `failed`, so touching a row destroys
# the proof of why it was touched. Everything a human would need to reconstruct
# this — trigger id and name, target session id, condition shape and its scheduled
# time, `failed_at`, and the `last_error` verbatim — is logged BEFORE the write,
# and a bounded digest of the same goes into `stats` so /health answers the
# question without anyone reading logs.
class RearmWakesBrickedByUnresolvableAgentRoot < PostDeployTask
  # The class name as `Trigger#format_last_error` wrote it: `"#{e.class}: #{message}"`,
  # truncated to 1000 chars. The class name leads, so truncation cannot hide it.
  ERROR_SIGNATURE = "AgentRootsConfig::AgentRootNotFoundError"

  # `stats` is rendered VERBATIM in four places — `/health` flattens it to one
  # inline string, `GET /api/v1/health` returns it, `get_system_health` pretty-prints
  # it into an agent's context window, and /supervisor/post_deploy_task_runs shows
  # the row — and the ledger row is never deleted. So the digest is bounded on both
  # axes: at most this many rows, each carrying a `last_error` clipped to a legible
  # prefix rather than `Trigger::MAX_LAST_ERROR_CHARS` of it. The log carries every
  # row, whole, and is the durable copy.
  MAX_DETAILED = 10
  MAX_ERROR_CHARS_IN_STATS = 160

  # Unindexed, and deliberately not worth an index: `status = 'failed'` is a tiny
  # slice of a table that holds tens of rows in this deployment, not millions.
  # Nothing here is sliced for the same reason — a `sweep` cursor would be
  # ceremony over a relation that fits in one batch.
  def self.candidates
    Trigger
      .where(status: "failed")
      .where("last_error LIKE ?", "%#{ERROR_SIGNATURE}%")
      .where(reuse_session: true)
      .where.not(last_session_id: nil)
      .includes(:trigger_conditions)
      .order(:id)
  end

  def up
    rearmed = []
    skipped = Hash.new(0)
    unenablable = []

    self.class.candidates.each do |trigger|
      category, detail = skip_reason(trigger)
      if category
        skipped[category] += 1
        logger.info(
          "[RearmWakesBrickedByUnresolvableAgentRoot] skipping trigger #{trigger.id} " \
          "(#{trigger.name.inspect}) — #{detail}"
        )
        next
      end

      record = describe(trigger)
      # Logged before the write: #enable! sheds `failed_at` and `last_error`.
      logger.info("[RearmWakesBrickedByUnresolvableAgentRoot] re-arming #{record.to_json}")
      begin
        trigger.enable!
        rearmed << record
      rescue ActiveRecord::ActiveRecordError => e
        # One row that will not save must not cost the others their repair — each
        # is an independent session still asleep. Collected and re-raised at the
        # end instead, once every row that CAN be re-armed has been, so the task
        # parks `failed` on the health page rather than reporting a success it did
        # not have. That is deliberate and it is a human handoff: a trigger that
        # fails its own validations fails identically on every retry, so the way
        # out is to fix the row at /triggers/:id and then press the task's re-arm
        # control — which then repeats only the rows that are still parked.
        logger.error(
          "[RearmWakesBrickedByUnresolvableAgentRoot] could not enable trigger #{trigger.id}: " \
          "#{e.class}: #{e.message}"
        )
        unenablable << "#{trigger.id} (#{e.class}: #{e.message})".truncate(MAX_ERROR_CHARS_IN_STATS)
      end
    end

    checkpoint!(
      rearmed: rearmed.size,
      # Split by shape because the two carry different guarantees: a schedule wake
      # is due the moment it is enabled, an ao_event wake waits for a transition
      # that may never come.
      rearmed_schedule_wakes: rearmed.count { |r| r[:shape] == "schedule" },
      rearmed_ao_event_wakes: rearmed.count { |r| r[:shape] == "ao_event" },
      rearmed_details: rearmed.first(MAX_DETAILED).map { |r| digest(r) },
      skipped: skipped.values.sum,
      skipped_by_reason: skipped,
      enable_failed: unenablable.size,
      enable_failures: unenablable.first(MAX_DETAILED),
      # The measurement the issue asked for, kept even when it is zero: a run that
      # matched nothing is a real answer, not a missing one.
      candidates_examined: rearmed.size + skipped.values.sum + unenablable.size
    )

    if unenablable.any?
      raise "#{unenablable.size} bricked wake(s) could not be re-armed and are still parked `failed`: " \
            "#{unenablable.join('; ')}"
    end

    nil
  end

  private

  # `nil` when the trigger should be re-armed. Otherwise a `[category, detail]`
  # pair: the category is a fixed string so `skipped_by_reason` stays a small,
  # countable histogram, and the detail — which names ids — goes to the log.
  def skip_reason(trigger)
    unless trigger.one_time_reuse_trigger?
      return [ "not_a_one_time_reuse_wake", "not a one-time reuse wake (conditions: #{trigger.condition_types.join(', ')})" ]
    end
    return [ "one_shot_already_consumed", "its one-shot was already consumed" ] if trigger.spent_one_shot_wake?

    session = Session.find_by(id: trigger.last_session_id)
    return [ "target_session_missing", "target session #{trigger.last_session_id} no longer exists" ] if session.nil?
    unless session.waiting?
      return [ "target_session_not_waiting", "target session #{session.id} is #{session.status}, not waiting" ]
    end
    if session.metadata&.dig("paused_by") == "user"
      return [ "target_session_paused_by_user", "target session #{session.id} was paused by a user" ]
    end
    if session.awaiting_scheduled_wake?
      return [ "target_session_has_a_live_wake", "target session #{session.id} is resting on a wake that can still fire" ]
    end

    nil
  end

  # Everything a human needs to reconstruct this row after the write has erased
  # `failed_at` and `last_error`.
  def describe(trigger)
    condition = trigger.trigger_conditions.find { |c| c.one_time_schedule? || c.session_scoped_ao_event? }

    {
      trigger_id: trigger.id,
      trigger_name: trigger.name,
      session_id: trigger.last_session_id,
      agent_root_name: trigger.agent_root_name,
      shape: condition&.condition_type,
      scheduled_at: condition&.one_time_schedule? ? condition.scheduled_at : nil,
      watched_session_id: condition&.session_scoped_ao_event? ? condition.watched_session_id : nil,
      condition_last_triggered_at: condition&.last_triggered_at&.iso8601,
      failed_at: trigger.failed_at&.iso8601,
      last_error: trigger.last_error
    }
  end

  # The bounded form of #describe that goes into `stats`. The name is dropped (the
  # id identifies the row, and the log has the name) and the error is clipped —
  # every row here matches ERROR_SIGNATURE by construction, so the prefix is the
  # confirmation, not the content.
  def digest(record)
    record
      .except(:trigger_name)
      .merge(last_error: record[:last_error]&.truncate(MAX_ERROR_CHARS_IN_STATS))
  end
end
