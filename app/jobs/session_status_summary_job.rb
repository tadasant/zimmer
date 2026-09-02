# frozen_string_literal: true

# Kicks off a status-summary generation off the request/transition path.
#
# Enqueued from three places: the pause/fail state transitions (the automatic
# trigger), the operator clicking "regenerate", and StatusSummaryBackstopJob
# (the repair sweep for a session at rest whose generation never landed).
# Rendering the panel never enqueues — a page view of a stale summary shows the
# cached text and the staleness count, and waits.
#
# Deliberately NOT deduped per session at the queue level. A GoodJob key on the
# session id would collapse an operator's forced Regenerate into an automatic
# refresh that happens to be queued for the same session — the operator presses
# the one control in the panel and nothing happens, because the queued run is
# unforced and returns "current". Mutual exclusion belongs where the expensive
# work is: SessionStatusSummaryGenerator claims the summary record before it
# forks, so a second run for the same session costs a SELECT and a locked read
# and starts nothing. The concurrency control below is a different thing from
# dedup — it rations worker threads, not sessions.
#
# The AUTOMATIC trigger does coalesce, at its enqueue site rather than here:
# SessionStateMachine#enqueue_status_summary_refresh skips the enqueue when any
# SessionStatusSummaryJob for the session is still unfinished (PendingSessionJob),
# because that job reads the transcript line count when it claims the record and
# so already covers the transition that would have enqueued another. Forced runs
# never consult that check, so a queued automatic refresh cannot swallow one.
class SessionStatusSummaryJob < ApplicationJob
  # A generation can block for HEADLESS_TIMEOUT. The inference queue has two
  # workers, so a burst waits here without consuming the default queue or
  # generating ConcurrencyExceeded retry rows.
  queue_as :inference

  discard_on ActiveRecord::RecordNotFound

  # Queue priority for a generation an operator asked for by hand — the panel's
  # Regenerate button, the REST endpoint, the MCP action.
  #
  # Sharing one queue with the automatic refreshes and title jobs means a human
  # request must get the next free inference worker. GoodJob orders `priority
  # ASC NULLS LAST`, so a negative priority jumps ahead of automatic work.
  FORCED_PRIORITY = -10

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
