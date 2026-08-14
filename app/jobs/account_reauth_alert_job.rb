# frozen_string_literal: true

# Delivers the needs_reauth operator DM off the transition path.
#
# The transition that enqueues this happens inside ClaudeAccount#refresh_token!'s
# row lock, often inside a recovery sweep. Posting to Slack there would hold that
# lock across two HTTP round-trips to Slack, on a path whose whole purpose is to
# keep the pool rotating. Same reason QueueRecoveryModeAlertJob exists.
class AccountReauthAlertJob < ApplicationJob
  queue_as :default

  # No retry configuration on purpose. AlertService.dm_operator swallows its own
  # Slack failures and returns false, so this job does not raise on a Slack
  # outage and has nothing to retry — and a DM that arrives an hour late about an
  # account a human has already re-authenticated is worse than none.
  def perform(account_id)
    account = ClaudeAccount.find_by(id: account_id)
    return if account.nil?

    AccountReauthNotifier.notify(account)
  end
end
