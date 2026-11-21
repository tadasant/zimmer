# frozen_string_literal: true

# The token broker's parent grant for one authorization server: the OAuth grant
# a human approved once, as Zimmer's own hosted client (OauthClientIdentity),
# that every short-lived child token for that server is exchanged from.
#
# It is held only by the backend. No session file, environment, `.mcp.json`,
# credentials store or log line ever carries it: the child tokens minted from
# it are what reach sessions (McpBrokeredToken). Both tokens are Active
# Record–encrypted from the first write, with no plaintext column at all.
#
# One per authorization server, keyed by `authorization_server` (its
# normalized origin, `https://strad.tadasant.com`). Every catalog entry that
# opts into brokered auth on that server shares it, so ninety entries on one
# server are one grant and one consent, not ninety.
#
# ## Refresh
#
# The access token is short-lived; #access_token! renews it with the refresh
# token and a fresh `private_key_jwt` assertion when it is within
# REFRESH_MARGIN of expiry. strad rotates the refresh token on every refresh
# and treats a replay of an old generation as theft, revoking the whole grant —
# so two processes must never refresh at once. The refresh runs under a row
# lock, and re-reads the row after taking it, so the second waiter finds a
# fresh token and does not refresh again.
class McpBrokerGrant < ApplicationRecord
  STATUSES = %w[active needs_consent].freeze

  # Renew the parent access token when it has less than this left. Generous on
  # purpose: a token exchange spends it, and a token that expires between the
  # check and the exchange is a failed turn start.
  REFRESH_MARGIN = 5.minutes

  encrypts :access_token, :refresh_token

  has_many :brokered_tokens, class_name: "McpBrokeredToken", dependent: :delete_all,
    inverse_of: :grant, foreign_key: :mcp_broker_grant_id

  validates :authorization_server, presence: true, uniqueness: true
  validates :token_endpoint, :resource, :client_id, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :active, -> { where(status: "active") }

  # Raised when the grant cannot produce an access token: it needs a human to
  # consent again, or the refresh failed. The message names the cause and is
  # safe to show — it never carries a token.
  class Unusable < StandardError; end

  def self.for_authorization_server(origin)
    find_by(authorization_server: TokenBroker.normalize_origin(origin))
  end

  # Store the result of a completed consent: the code exchange's tokens and the
  # endpoints discovered when the flow started. Re-consenting replaces the
  # previous grant's tokens in place (its children keep their rows; strad ends
  # them if the human revoked the old grant).
  #
  # @param pending_flow [McpOauthPendingFlow] a broker flow
  # @param tokens [Hash] McpOauthService#extract_tokens output
  # @return [McpBrokerGrant]
  def self.store_consent!(pending_flow, tokens, revocation_endpoint:, issuer:)
    grant = find_or_initialize_by(authorization_server: pending_flow.broker_authorization_server)
    grant.update!(
      issuer: issuer,
      token_endpoint: pending_flow.token_endpoint,
      revocation_endpoint: revocation_endpoint,
      resource: pending_flow.resource.presence || pending_flow.server_url,
      client_id: pending_flow.client_id,
      access_token: tokens["access_token"],
      refresh_token: tokens["refresh_token"],
      access_token_expires_at: tokens["expires_in"] ? Time.current + tokens["expires_in"].to_i.seconds : nil,
      scope: tokens["scope"],
      status: "active",
      last_error: nil,
      consented_at: Time.current,
      last_refreshed_at: Time.current
    )
    grant
  end

  def active? = status == "active"

  def access_token_fresh?(now: Time.current)
    access_token.present? && (access_token_expires_at.nil? || access_token_expires_at > now + REFRESH_MARGIN)
  end

  # A live parent access token, renewed first when it is near expiry.
  #
  # @param client [TokenBroker::Client]
  # @return [String]
  # @raise [Unusable]
  def access_token!(client: TokenBroker::Client.new)
    raise Unusable, unusable_message unless active?
    return access_token if access_token_fresh?

    failure = nil
    with_lock do
      # Another process may have refreshed while this one waited for the lock.
      next unless active?
      next if access_token_fresh?

      # Never raises: a raise here would roll back the very row update that
      # records why the refresh failed.
      failure = refresh_under_lock(client)
    end

    raise Unusable, failure if failure
    raise Unusable, unusable_message unless active?

    access_token
  end

  # Mark the grant as needing a human, with the cause. Children already minted
  # keep working until they expire or strad ends them.
  def needs_consent!(reason)
    update!(status: "needs_consent", last_error: reason.to_s.truncate(500))
  end

  def unusable_message
    reason = last_error.presence || "the grant needs a human to approve it again"
    "the token broker's grant for #{authorization_server} is not usable (#{reason}). " \
      "Reconnect it on Zimmer's Token broker page."
  end

  private

  # @return [String, nil] why the refresh failed, or nil when it succeeded
  def refresh_under_lock(client)
    if refresh_token.blank?
      update!(status: "needs_consent", last_error: "no refresh token is stored")
      return unusable_message
    end

    result = client.refresh(self)
    update!(
      access_token: result.access_token,
      refresh_token: result.refresh_token.presence || refresh_token,
      access_token_expires_at: result.expires_in ? Time.current + result.expires_in.seconds : nil,
      last_refreshed_at: Time.current,
      last_error: nil
    )
    nil
  rescue TokenBroker::Client::GrantRejected => e
    # The authorization server refused the refresh token itself: the grant was
    # revoked, expired, or replayed. Only a human can fix that.
    update!(status: "needs_consent", last_error: e.message.truncate(500))
    unusable_message
  rescue TokenBroker::Client::Error, OauthClientIdentity::Unavailable => e
    # Transient (the server or KMS did not answer). The grant stays usable for
    # the next try; record why this one failed.
    update_columns(last_error: e.message.truncate(500), updated_at: Time.current)
    "could not renew the token broker's grant for #{authorization_server}: #{e.message}"
  end
end
