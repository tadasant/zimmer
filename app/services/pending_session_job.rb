# frozen_string_literal: true

# Whether a session already has an unfinished job of a given class queued or
# running — the question an automatic, best-effort enqueue asks before adding
# another.
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
# `serialized_params -> 'arguments' ->> 0` is the session id, the same column
# expression PendingAgentTurns reads. Best-effort by design: two transitions
# landing in the same instant can both see nothing queued and enqueue twice,
# which is the pre-existing behaviour, not a regression.
module PendingSessionJob
  module_function

  # @param job_class [Class] an ActiveJob class whose first argument is a session id
  # @param session_id [Integer]
  # @return [Boolean] true when an unfinished job of that class exists for the session
  def queued?(job_class, session_id)
    GoodJob::Job
      .where(job_class: job_class.name, finished_at: nil)
      .where("serialized_params -> 'arguments' ->> 0 = ?", session_id.to_s)
      .exists?
  end
end
