# frozen_string_literal: true

# How much of a job class is queued and not yet claimed — the question an
# enqueue asks before adding another. Two shapes of it: #queued?, per session,
# for an automatic best-effort refresh, and #queued_count, fleet-wide, for a
# sweep that has to size a burst against the lane that will drain it.
#
# The two jobs that ask it, SessionTitleJob and SessionStatusSummaryJob, are
# enqueued by the `pause` and `fail` transitions, and both read the session's
# state at *run* time: a title job reads whatever transcript exists when it
# runs, and a summary job computes the transcript line count it is summarizing
# when it claims the record. So a second copy queued behind the first for the
# same session does no additional work — it finds the title written, or the
# summary current, and returns. What it does cost is one of the `inference`
# lane's two threads, a GoodJob claim and its bookkeeping round-trips, and
# during a burst that is the whole bill: on 2026-09-02 a tranche of ~45 sessions
# sleeping and waking on 5–15 minute self-wakes had 100 SessionTitleJobs and 90
# SessionStatusSummaryJobs ready on a queue that was draining ~800 jobs an hour.
#
# The check is a read on the job table rather than a GoodJob concurrency key
# because the forced surfaces (Regenerate in the panel, REST and MCP) must
# never be collapsed into a queued automatic run — a key on the session id
# would do exactly that, so they do not consult this at all.
#
# A job that is already performing does not count. It took its snapshot of the
# session when it started, so a transition landing during its run is not
# covered by it, and the fresh enqueue that follows is the cheap kind: the
# running job holds the summary claim, so the new one returns "already being
# generated" or "current" after a SELECT. A row GoodJob is retrying has had
# `performed_at` reset to nil and does count, which is right — it has not yet
# read anything.
#
# StatusSummaryBackstopJob and SessionStatusSummaryHarvestJob also enqueue a
# summary job and are deliberately not routed through the PER-SESSION check: the
# backstop refuses a record already `pending`, and the harvest retries once per
# fork, so neither can stack a job per wake for one session.
#
# What the backstop cannot get from a per-session check is how much it may
# enqueue ACROSS sessions, and that is the bill that came due in #776: a sweep
# sized in 2026-08 against the wide `default` lane kept enqueuing ten repairs
# every five minutes onto the two-thread `inference` lane #763 moved them to,
# which drains at most eighty an hour. #queued_count is the arrival-side
# admission check it sizes itself with instead — see
# StatusSummaryBackstopJob::LANE_DEPTH_CEILING.
#
# `serialized_params -> 'arguments' ->> 0` is the session id, the same column
# expression PendingAgentTurns reads. Best-effort by design: two transitions
# landing in the same instant can both see nothing queued and enqueue twice,
# which is the pre-existing behaviour, not a regression.
module PendingSessionJob
  module_function

  # @param job_class [Class] an ActiveJob class whose first argument is a session id
  # @param session_id [Integer]
  # @return [Boolean] true when a job of that class is queued for the session and no
  #   worker has claimed it yet
  def queued?(job_class, session_id)
    unclaimed(job_class)
      .where("serialized_params -> 'arguments' ->> 0 = ?", session_id.to_s)
      .exists?
  end

  # The same population #queued? asks about, without the session filter: the
  # depth a job of this class enqueued right now would wait behind. A caller
  # deciding how many to enqueue reads this, not a constant.
  #
  # @param job_class [Class]
  # @return [Integer]
  def queued_count(job_class) = unclaimed(job_class).count

  # Queued and not yet claimed — the one definition both questions share, and
  # the one place the retry subtlety above is encoded: GoodJob resets
  # `performed_at` when it re-enqueues a row, so a row in back-off is counted.
  #
  # Private: this module's surface is the two questions its header describes, not
  # a relation for callers to bolt further conditions onto.
  def unclaimed(job_class)
    GoodJob::Job.where(job_class: job_class.name, finished_at: nil, performed_at: nil)
  end
  private_class_method :unclaimed
end
