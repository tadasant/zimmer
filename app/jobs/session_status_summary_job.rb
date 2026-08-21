# frozen_string_literal: true

# Kicks off a status-summary generation off the request/transition path.
#
# Enqueued from three places: the pause/fail state transitions (the automatic
# trigger), the operator clicking "regenerate", and StatusSummaryBackstopJob
# (the repair sweep for a session at rest whose generation never landed).
# Rendering the panel never enqueues — a page view of a stale summary shows the
# cached text and the staleness count, and waits.
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

  # @param headless [Boolean] write the blurb with one pool-independent
  #   `claude -p` completion instead of forking. Passed by the two callers that
  #   know a fork cannot deliver right now: the repair sweep during an auth
  #   outage, and the harvest of a fork that came back with no answer.
  def perform(session_id, force: false, headless: false)
    session = Session.find(session_id)
    result = SessionStatusSummaryGenerator.call(session: session, force: force, headless: headless)

    Rails.logger.info(
      "[SessionStatusSummaryJob] session=#{session_id} force=#{force} headless=#{headless} " \
      "outcome=#{result.outcome} #{result.message}"
    )
  end
end
