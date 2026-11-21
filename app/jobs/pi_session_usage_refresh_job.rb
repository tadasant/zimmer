# frozen_string_literal: true

# Sweep ONE Pi session's usage into the token ledger soon after a model response
# lands, and repaint the session page's spend figures.
#
# The fleet-wide TokenUsageIngestionJob runs every ten minutes; this is what keeps
# a running Pi session's figure within seconds of what it has spent. Pi is the one
# runtime whose usage is cheap to read per session: the durable copy of its
# transcript is `sessions.transcript`, which TranscriptPollerService has just
# written, so this re-reads that one row rather than a directory tree.
#
# Enqueued by TranscriptPollerService when a poll stores a new Pi entry that
# carries `usage`. Bounded per session three ways: one queued, one running, and
# at most one run per THROTTLE_PERIOD. A run past the throttle is retried by
# GoodJob's concurrency `retry_on`, so the newest response is still swept, just
# later. The bound matters because a sweep re-parses the session's whole stored
# transcript; the ingestor is an insert-ignoring upsert, so a sweep that overlaps
# the cron's costs time and nothing else.
class PiSessionUsageRefreshJob < ApplicationJob
  queue_as :pollers

  THROTTLE_PERIOD = 15.seconds

  good_job_control_concurrency_with(
    key: -> { "pi_session_usage_refresh_#{arguments.first}" },
    enqueue_limit: 1,
    perform_limit: 1,
    perform_throttle: [ 1, THROTTLE_PERIOD ]
  )

  # @param session_id [Integer]
  # @return [Integer, nil] ledger rows added, nil when there was nothing to do
  def perform(session_id)
    session = Session.find_by(id: session_id)
    return nil unless session && session.agent_runtime == PiTokenUsageIngestionService::RUNTIME

    started_at = Time.current
    result = PiTokenUsageIngestionService.new(session_ids: [ session.id ]).call
    return result.session_rows unless result.session_rows.positive?

    # Repaint whichever sessions the new rows were credited to. Usually that is
    # this one, but a forked transcript opens with its source's header and the
    # ingestor credits by header, so the session whose figure moved may not be
    # the one that was swept.
    SessionTokenUsage.where(agent_runtime: PiTokenUsageIngestionService::RUNTIME, created_at: started_at..)
                     .where.not(session_id: nil).distinct.pluck(:session_id)
                     .then { |ids| Session.where(id: ids) }
                     .each(&:broadcast_cost)
    result.session_rows
  end
end
