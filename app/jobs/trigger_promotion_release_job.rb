# frozen_string_literal: true

# Start the sessions a trigger's scheduling-class change promoted to `priority`,
# instead of leaving them to wait out a spot-gate re-check the promotion made
# moot.
#
# #480 gave the trigger's selector reach: flipping it to priority during a quota
# backlog carries the class onto the trigger's own already-spawned waiting
# sessions. It stopped one step short — the class landed and nothing else
# changed, so a session already HELD by the gate went on sitting behind a
# deferred AgentSessionJob scheduled up to an hour out. That is #423 on the last
# promotion path still carrying it.
#
# == Why this is a job and not the after_commit itself
#
# Trigger#reclassify_spawned_waiting_sessions is set operations on purpose: it
# runs inside the operator's own request, and #480's whole scenario is a long
# backlog. Releasing is not a set operation — each session needs its own queue
# read and its own reschedule — so doing it inline would put ~8 statements per
# session, several of them row locks, into a PATCH that has already committed.
# At the ~141-session backlog this file's neighbours cite, that request times out
# halfway through and the operator cannot tell a failed release from a failed
# save. Every other bulk flow in this app is bounded or off-request for the same
# reason (SpotSessionHold.sweep!, StalledSessionStart, StrandedSleepRescue).
#
# == Sessions::StartNow is the owner, not a second implementation of one
#
# Every promotion path — the Ranked view's Promote, the hold banner's button,
# `action_session`'s `change_scheduling_class`, `PATCH /api/v1/sessions/:id` —
# goes through it, and it is where the DOUBLE-START hazard is answered: a held
# session's turn is already queued, so the job is RESCHEDULED to now (GoodJob's
# own `reschedule_job`, which takes the row lock) rather than a second one being
# enqueued alongside it. Two jobs against one session means two runtimes against
# one clone, and the concurrency guard only covers the window in which the first
# still holds `running_job_id`.
#
# == What it refuses, and who owns those instead
#
# A promotion is a trigger-WIDE statement, and three populations answer to
# something more specific:
#
#   * A session that is no longer `waiting`, or whose class did not end up
#     priority. Both are re-read here rather than trusted: the ids were collected
#     before the trigger's save committed, and a session can start, be demoted by
#     hand, or have its promotion rolled back in between.
#   * A session carrying a spot-ceiling pause or an auth-outage park. Each has
#     its own resume owner (SpotCeilingSweepJob, the pool's recovery), and a
#     `pause_into_spot_queue` park is a PER-SESSION deliberate choice that a
#     trigger-wide one must not override — the same rule that keeps a
#     hand-moved session's class where somebody put it. Promotion out of a
#     ceiling pause is its own open question (#613), and this deliberately does
#     not answer it here.
#   * A session in a frozen category. Session.not_in_frozen_category is the
#     scope every bulk "start / recover all sessions" flow honours, and this is
#     one.
class TriggerPromotionReleaseJob < ApplicationJob
  # `maintenance`, not `default`. A released backlog can hold this thread for
  # minutes — one queue read and one row lock per session — and that lane exists
  # precisely so long-running work does not sit in front of ordinary callbacks.
  queue_as :maintenance

  # @param trigger_id [Integer] only for the actor sentence and the log line; a
  #   trigger deleted between the commit and this run still releases its sessions
  # @param session_ids [Array<Integer>] the rows the reclassification moved INTO
  #   priority
  def perform(trigger_id, session_ids)
    ids = Array(session_ids)
    return if ids.empty?

    trigger = Trigger.find_by(id: trigger_id)
    actor = trigger ? %(a change to trigger "#{trigger.name}") : "a trigger scheduling-class change"

    Session.where(id: ids, status: "waiting").not_in_frozen_category.find_each do |session|
      next unless session.priority?
      next if dormant_for_another_reason?(session)

      result = Sessions::StartNow.call(session, actor: actor)
      next unless result.refused?

      Rails.logger.info(
        "[TriggerPromotionReleaseJob] Session #{session.id} was promoted by trigger #{trigger_id} " \
        "but not started: #{result.message}"
      )
    rescue StandardError => e
      # Per session, not around the loop. One session that cannot be read says
      # nothing about the next, and a rescue spanning the loop would abandon the
      # rest of a backlog the operator asked to release.
      Rails.logger.warn(
        "[TriggerPromotionReleaseJob] Could not start session #{session.id} after trigger " \
        "#{trigger_id} promoted it: #{e.class}: #{e.message}"
      )
    end
  end

  private

  def dormant_for_another_reason?(session)
    SpotSessionPause.paused?(session) || AuthOutageParkService.parked?(session)
  end
end
