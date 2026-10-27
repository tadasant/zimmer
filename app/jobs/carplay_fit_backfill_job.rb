# frozen_string_literal: true

# Marks one session's CarPlay fit from the status summary it already has.
#
# Enqueued by the `BackfillCarplayFitFromStatusSummaries` post-deploy task for
# every session that was resting in `needs_input` with a blurb written before the
# summary fork learned to answer the CarPlay-fit question itself. Nothing else
# enqueues it: from that deploy on, every rest writes the mark through the fork
# (SessionStatusSummaryGenerator::CARPLAY_FIT_TRAILER_RULE).
#
# Idempotent by construction — a session that has a mark by the time the job
# runs is left alone, so a re-enqueue, a retry, or a human who got there first
# all cost nothing. Runs on the `inference` lane with the summary jobs, because
# it is one `claude -p` completion and belongs with the work that shares that
# budget.
class CarplayFitBackfillJob < ApplicationJob
  queue_as :inference

  def perform(session_id)
    session = Session.find_by(id: session_id)
    return if session.nil?
    return if session.carplay_fit.present?
    return unless session.needs_input?

    result = CarplayFitClassifier.call(session)
    Rails.logger.info("[CarplayFitBackfillJob] session=#{session_id} #{result.outcome}: #{result.message}")
  end
end
