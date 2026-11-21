# frozen_string_literal: true

# One short-lived child token the token broker exchanged from a parent grant
# (McpBrokerGrant): either a session's token for one turn, or one of Zimmer's
# own tokens for its backend calls to a brokered server.
#
# The row exists so the token can be revoked: RFC 7009 revocation takes the
# token itself, so it is kept, Active Record–encrypted, until it is revoked or
# has expired. It is never rendered anywhere.
#
# ## States
#
#   live            in use (a session's current turn, or the backend's cache)
#   revoke_pending  the turn ended (or the token was superseded); revocation
#                   is owed and is retried until it lands
#   revoked         strad accepted the revocation
#   expired         it ran out before a revocation landed — which is the
#                   designed fallback, not a failure: an unrevoked child
#                   simply stops working at `expires_at`
class McpBrokeredToken < ApplicationRecord
  PURPOSES = %w[session backend].freeze
  STATES = %w[live revoke_pending revoked expired].freeze

  # Retry spacing for a failed revocation, by attempt number. The last value
  # repeats until the token expires, at which point retrying is pointless.
  REVOKE_BACKOFF = [ 30.seconds, 2.minutes, 10.minutes, 30.minutes ].freeze

  # How long revoked and expired rows are kept for the Token broker page's
  # recent history before TokenBrokerSweepJob deletes them.
  RETENTION = 7.days

  encrypts :token

  belongs_to :grant, class_name: "McpBrokerGrant", foreign_key: :mcp_broker_grant_id, inverse_of: :brokered_tokens
  belongs_to :session, optional: true

  validates :purpose, inclusion: { in: PURPOSES }
  validates :state, inclusion: { in: STATES }
  validates :label, :scope, :token, :expires_at, presence: true

  scope :live, -> { where(state: "live") }
  scope :revoke_pending, -> { where(state: "revoke_pending") }
  scope :for_sessions, -> { where(purpose: "session") }
  scope :for_backend, -> { where(purpose: "backend") }
  scope :unexpired, ->(now = Time.current) { where("expires_at > ?", now) }
  scope :revoke_due, ->(now = Time.current) {
    revoke_pending.where("next_revoke_attempt_at IS NULL OR next_revoke_attempt_at <= ?", now)
  }

  def expired?(now = Time.current) = expires_at <= now

  # Ask for this token to be revoked. Idempotent, and cheap: it only marks the
  # row. TokenBroker.revoke! (inline, or from the sweep) does the network call.
  def request_revoke!(now: Time.current)
    return unless state == "live"

    update!(state: "revoke_pending", revoke_requested_at: now, next_revoke_attempt_at: now)
  end

  # Record the outcome of one revocation attempt.
  def revoke_succeeded!(now: Time.current)
    update!(state: "revoked", revoked_at: now, next_revoke_attempt_at: nil, last_revoke_error: nil)
  end

  def revoke_failed!(error, now: Time.current)
    attempts = revoke_attempts + 1
    if expires_at <= now
      update!(state: "expired", revoke_attempts: attempts, last_revoke_error: error.to_s.truncate(500), next_revoke_attempt_at: nil)
    else
      delay = REVOKE_BACKOFF[[ attempts - 1, REVOKE_BACKOFF.size - 1 ].min]
      update!(revoke_attempts: attempts, last_revoke_error: error.to_s.truncate(500), next_revoke_attempt_at: now + delay)
    end
  end
end
