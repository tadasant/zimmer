# frozen_string_literal: true

# Computes the Cycle Time row of the hierarchy a just-archived session belongs to.
#
# Enqueued by Session's archive after_commit with a delay (SETTLE): the
# transcript poller ingests a session's last lines on its own cadence, so
# analyzing the instant the archive commits would miss the turn's final events.
# A hierarchy still in flight is a no-op — the archive of its last session
# enqueues this again. Safe to run repeatedly: CycleTimes::Analyzer upserts on
# the root.
class CycleTimeAnalysisJob < ApplicationJob
  queue_as :default

  SETTLE = 3.minutes

  # At most one queued and one running per archived session. Two sessions of
  # the same hierarchy may still compute it concurrently; the upsert on the
  # root makes that a repeated write, not a conflict.
  good_job_control_concurrency_with(
    key: -> { "cycle_time_analysis_#{arguments.first}" },
    enqueue_limit: 1,
    perform_limit: 1
  )

  def perform(session_id)
    session = Session.find_by(id: session_id)
    return if session.nil?

    root = CycleTimes::Hierarchy.root_for(session)
    # A status-summary fork is Zimmer's bookkeeping, not anyone's task.
    return if root.status_summary_fork?

    CycleTimes::Analyzer.call(root)
  end
end
