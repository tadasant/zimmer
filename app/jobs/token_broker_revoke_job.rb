# frozen_string_literal: true

# Revokes a session's brokered child tokens after its turn came to rest
# (BrokeredTokenRevocation), or after a new turn superseded them.
#
# Runs a few seconds after the rest rather than inside the transition, and
# re-checks the session when it runs: a recovery can move a session to rest and
# straight back to a spawn, and a token that the new process is about to use
# must not be revoked under it. Only children minted at or before the rest are
# touched; one minted since belongs to the turn that started afterwards.
#
# A revocation that fails is not retried here. The row stays `revoke_pending`
# with its next attempt scheduled, and TokenBrokerSweepJob retries it until it
# lands or the token expires.
class TokenBrokerRevokeJob < ApplicationJob
  queue_as :default

  DELAY = 15.seconds

  # @param session_id [Integer]
  # @param rested_at [String] ISO 8601
  # @param only_pending [Boolean] true when a new turn superseded the previous
  #   child: revoke what is already marked, without the at-rest checks
  def perform(session_id, rested_at, only_pending: false)
    rested_at = Time.iso8601(rested_at)

    unless only_pending
      session = Session.find_by(id: session_id)
      if session && (session.running? || (session.needs_input? && session.blocked_on_elicitation?))
        Rails.logger.info("[TokenBrokerRevokeJob] session #{session_id} is live again; leaving its token to the next rest")
        return
      end
    end

    revoked = if only_pending
      McpBrokeredToken.revoke_pending.where(session_id: session_id).to_a.count { |row| TokenBroker.revoke!(row) }
    else
      TokenBroker.revoke_session_tokens(session_id, rested_at: rested_at)
    end
    Rails.logger.info("[TokenBrokerRevokeJob] session #{session_id}: revoked #{revoked} brokered token(s)") if revoked.positive?
  end
end
