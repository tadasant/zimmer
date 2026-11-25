# frozen_string_literal: true

# Revoke a session's brokered child tokens (TokenBroker) when its turn comes to
# rest, so a token outlives the process it was minted for by seconds, not by
# its six-hour lifetime.
#
# "Comes to rest" is every way a turn ends without an agent process still
# holding the token:
#
# - `needs_input`, `failed` or `archived`, from any state — except
#   `needs_input` reached by `block_on_elicitation`, where the process is alive
#   and waiting on a human's approval, and comes back with `unblock`;
# - `waiting` reached from `running` — a spot hold returning a turn to the
#   queue, or a queued message handed straight to the next turn. (The `sleep`
#   event itself starts from `needs_input`, which is already a rest.)
#
# `waiting` reached from anywhere else is not a rest: a turn mints its token
# while the session is still `waiting` and only becomes `running` once its
# process has spawned, and a recovery may move a session back to `waiting`
# right before that spawn.
#
# The work is a job (TokenBrokerRevokeJob), so a state transition never waits
# on a network call and never fails because strad did not answer. The job
# re-checks the session before revoking and revokes only children minted
# before this rest. TokenBrokerSweepJob is the backstop for a missed callback.
module BrokeredTokenRevocation
  extend ActiveSupport::Concern

  REST_STATES = %w[needs_input failed archived].freeze

  included do
    after_commit :revoke_brokered_tokens_at_rest, if: :brokered_token_rest?
  end

  private

  def brokered_token_rest?
    return false unless saved_change_to_status?

    if REST_STATES.include?(status.to_s)
      !(status.to_s == "needs_input" && blocked_on_elicitation?)
    else
      status.to_s == "waiting" && status_before_last_save.to_s == "running"
    end
  end

  # Never lets a broker problem break a state transition: the sweep catches
  # whatever this misses.
  def revoke_brokered_tokens_at_rest
    TokenBroker.session_came_to_rest(self)
  rescue StandardError => e
    Rails.logger.warn("[BrokeredTokenRevocation] session #{id}: #{e.class}: #{e.message}")
  end
end
