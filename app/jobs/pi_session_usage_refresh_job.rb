# frozen_string_literal: true

# Sweep ONE Pi session's usage into the token ledger as soon as a model response
# lands, and repaint the session page's spend figures.
#
# The fleet-wide TokenUsageIngestionJob runs every ten minutes, which left a
# running Pi session's cost up to ten minutes behind what the session had
# actually spent — and the session page never repainted it until a reload. Pi is
# the one runtime whose usage is cheap to read per session: the durable copy of
# its transcript is `sessions.transcript`, which TranscriptPollerService has just
# written, so this re-reads that one row rather than a directory tree.
#
# Enqueued by TranscriptPollerService when a poll stores a new Pi entry that
# carries `usage`. At most one queued and one running per session, so a burst of
# responses coalesces into one sweep instead of one per response; the ingestor
# is an insert-ignoring upsert, so a sweep that overlaps the cron's is harmless.
class PiSessionUsageRefreshJob < ApplicationJob
  queue_as :pollers

  good_job_control_concurrency_with(
    key: -> { "pi_session_usage_refresh_#{arguments.first}" },
    enqueue_limit: 1,
    perform_limit: 1
  )

  # @param session_id [Integer]
  # @return [Integer, nil] ledger rows added, nil when there was nothing to do
  def perform(session_id)
    session = Session.find_by(id: session_id)
    return nil unless session && session.agent_runtime == PiTokenUsageIngestionService::RUNTIME

    result = PiTokenUsageIngestionService.new(session_ids: [ session.id ]).call
    session.broadcast_cost if result.session_rows.positive?
    result.session_rows
  end
end
