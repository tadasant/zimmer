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

  # How many headless generations may be RUNNING at once, fleet-wide.
  #
  # A headless run blocks its worker thread for up to
  # SessionStatusSummaryGenerator::HEADLESS_TIMEOUT seconds shelling out to
  # `claude -p`, and `default` has four threads in production. Three things
  # enqueue headless work — the repair sweep, the harvest of a fork that could
  # not deliver, and a forced Regenerate during an outage — and only the first
  # is capped per sweep, so without a limit here an outage could put summary
  # inference on most of the shared queue at once and make every other `default`
  # job wait behind it. Two threads is the ceiling; the rest queue and run next.
  HEADLESS_PERFORM_LIMIT = 2

  # The key is nil for a fork generation, which is how GoodJob is told this
  # control does not apply to it. Forks must stay uncontrolled: they are
  # deliberately not deduped (see above), and they do not hold a thread the way
  # a blocking subprocess does — AgentSessionJob owns that lifecycle.
  HEADLESS_CONCURRENCY_KEY = "status_summary_headless"

  good_job_control_concurrency_with(
    key: -> { headless_argument? ? HEADLESS_CONCURRENCY_KEY : nil },
    perform_limit: HEADLESS_PERFORM_LIMIT
  )

  # Reads the mode off the serialized arguments, tolerating both symbol and
  # string keys: the key proc runs against a job that may have been round-tripped
  # through the queue, where the kwargs hash comes back with string keys.
  def headless_argument?
    options = arguments.last
    return false unless options.is_a?(Hash)

    options[:headless] || options["headless"] ? true : false
  end

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
