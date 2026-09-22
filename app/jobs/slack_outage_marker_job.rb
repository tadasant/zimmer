# frozen_string_literal: true

# Once a minute, bring the outage marker on each Slack-spawned session's message in line with the
# session: add :hourglass_flowing_sand: when the session has hit API errors, never reached the
# model, and the poster has waited past SlackOutageMarker::THRESHOLD; take it off when the
# agent's first turn lands or the session stops. The rules are SlackOutageMarker's.
#
# Level-triggered, so a skipped tick costs a minute and nothing else. On an ordinary day every
# candidate settles `not_needed` on the first sweep after its first model turn and no Slack call is
# made.
class SlackOutageMarkerJob < ApplicationJob
  queue_as :default
  include SingletonSweep

  def perform
    return unless SlackService.configured?

    now = Time.current
    SlackOutageMarker.candidates(now: now).find_each do |session|
      SlackOutageMarker.new(session, now: now).converge!
    rescue => e
      # One session's failure must not stop the others. Its row is untouched, so the next sweep
      # tries it again. Reported once per session, not once a minute for as long as it keeps failing.
      Rails.logger.warn "[SlackOutageMarkerJob] Could not converge session #{session.id}: #{e.class}: #{e.message}"
      next if session.metadata&.dig(SlackOutageMarker::REPORTED_KEY).present?

      ErrorReporter.report_exception(e, context: { session_id: session.id, stage: "slack_outage_marker" })
      session.merge_metadata!(SlackOutageMarker::REPORTED_KEY => Time.current.iso8601)
    end
  end
end
