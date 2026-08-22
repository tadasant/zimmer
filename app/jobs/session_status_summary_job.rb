# frozen_string_literal: true

# Kicks off a status-summary generation off the request/transition path.
#
# Enqueued from three places: the pause/fail state transitions (the automatic
# trigger), the operator clicking "regenerate", and StatusSummaryBackstopJob
# (the repair sweep for a session at rest whose generation never landed).
# Rendering the panel never enqueues — a page view of a stale summary shows the
# cached text and the staleness count, and waits.
#
# Deliberately NOT deduped per session. A key on the session id would collapse an
# operator's forced Regenerate into an automatic refresh that happens to be queued
# for the same session — the operator presses the one control in the panel and
# nothing happens, because the queued run is unforced and returns "current".
# Mutual exclusion belongs where the expensive work is:
# SessionStatusSummaryGenerator claims the summary record before it forks, so a
# second run for the same session costs a SELECT and a locked read and starts
# nothing. The concurrency control below is a different thing from dedup — it
# rations worker threads, not sessions, and every enqueue still runs.
class SessionStatusSummaryJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  # A generation may block its worker thread for up to
  # SessionStatusSummaryGenerator::HEADLESS_TIMEOUT seconds shelling out to
  # `claude -p`, so this job is bounded against `default`'s thread count along
  # with every other blocking-inference class.
  #
  # The bound is unconditional, and it has to be: the caller does not decide
  # whether a generation blocks. SessionStatusSummaryGenerator takes the headless
  # path on `headless || pool_exhausted?`, so ANY generation — including one
  # enqueued as a fork by a `pause` transition or by an operator's Regenerate —
  # turns into a blocking subprocess the moment the account pool runs dry. A
  # bound that keyed off the `headless:` argument would describe the caller's
  # intent rather than the work, and would stop binding during exactly the outage
  # it was written for.
  include BlockingInferenceBounded

  # Queue priority for a generation an operator asked for by hand — the panel's
  # Regenerate button, the REST endpoint, the MCP action.
  #
  # Sharing one perform limit with the automatic refreshes and the title jobs
  # means a forced run can lose the race for a slot, and a human is watching the
  # panel for that one. GoodJob orders `priority ASC NULLS LAST` and admits the
  # oldest claims first, so a lower number is claimed sooner and therefore takes
  # the next free slot ahead of the unforced work. Negative rather than zero
  # because the default is nil, which sorts last.
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
