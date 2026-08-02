# frozen_string_literal: true

# Kicks off a status-summary generation off the request/transition path.
#
# Enqueued from two places and only two: the pause/fail state transitions (the
# single automatic trigger), and the operator clicking "regenerate". Nothing
# polls, and rendering the panel never enqueues — a page view of a stale summary
# shows the cached text and the staleness count, and waits.
# Deliberately NOT deduped with `good_job_control_concurrency_with`. A key on the
# session id would collapse an operator's forced Regenerate into an automatic
# refresh that happens to be queued for the same session — the operator presses
# the one control in the panel and nothing happens, because the queued run is
# unforced and returns "current". Mutual exclusion belongs where the expensive
# work is: SessionStatusSummaryGenerator claims the summary record before it
# forks, so a second run for the same session costs a SELECT and a locked read
# and starts nothing.
class SessionStatusSummaryJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(session_id, force: false)
    session = Session.find(session_id)
    result = SessionStatusSummaryGenerator.call(session: session, force: force)

    Rails.logger.info(
      "[SessionStatusSummaryJob] session=#{session_id} force=#{force} outcome=#{result.outcome} #{result.message}"
    )
  end
end
