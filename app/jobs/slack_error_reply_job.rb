# frozen_string_literal: true

# Once a minute, post the fixed threaded reply on each Slack request whose session cannot serve it:
# out of inference quota, cut off from the provider, or failed before the agent could answer. The
# rules and the wording are SlackErrorReply's.
#
# Level-triggered, so a skipped tick costs a minute and nothing else. On an ordinary day every
# candidate settles `not_needed` (or `not_addressed`) on the first sweep that sees it, and no Slack
# call is made.
class SlackErrorReplyJob < ApplicationJob
  queue_as :default
  include SingletonSweep

  def perform
    return unless SlackService.configured?

    now = Time.current
    SlackErrorReply.candidates(now: now).find_each do |session|
      SlackErrorReply.new(session, now: now).converge!
    rescue => e
      # One session's failure must not stop the others. Reported once per session, not once a
      # minute for as long as it keeps failing.
      Rails.logger.warn "[SlackErrorReplyJob] Could not converge session #{session.id}: #{e.class}: #{e.message}"
      next if session.metadata&.dig(SlackErrorReply::REPORTED_KEY).present?

      ErrorReporter.report_exception(e, context: { session_id: session.id, stage: "slack_error_reply" })
      session.merge_metadata!(SlackErrorReply::REPORTED_KEY => Time.current.iso8601)
    end
  end
end
