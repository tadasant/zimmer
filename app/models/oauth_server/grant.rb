# frozen_string_literal: true

module OauthServer
  # One human's consent to one client: a connection. Every access and refresh
  # token descends from exactly one grant, through any number of refresh
  # rotations, so revoking the grant (from the API keys page, from
  # `/oauth/revoke`, or because a spent refresh token was replayed) ends the
  # connection on the next request.
  class Grant < ApplicationRecord
    # A spent refresh token presented again inside this window is refused without
    # revoking the grant. The case it is for is a client that refreshes twice at
    # once with the same token (two tabs, two workers): one call rotates it, the
    # other loses the race, and the winner's new pair is still good. Revoking on
    # that would end a working connection. Outside the window a replay revokes the
    # grant (RFC 9700 §4.14.2).
    REPLAY_GRACE = 60.seconds

    belongs_to :client, class_name: "OauthServer::Client", foreign_key: :oauth_server_client_id,
      inverse_of: :grants
    has_many :tokens, class_name: "OauthServer::Token", foreign_key: :oauth_server_grant_id,
      inverse_of: :grant, dependent: :delete_all

    scope :active, -> { where(revoked_at: nil) }
    scope :listed, -> { order(Arel.sql("revoked_at IS NOT NULL"), Arel.sql("COALESCE(last_used_at, created_at) DESC")) }

    TokenPair = Data.define(:access_token, :refresh_token, :expires_in)

    # Why a grant's scope last changed, recorded in `scope_change_reason`.
    SCOPE_CHANGE_REASONS = %w[consent ui_downgrade ui_upgrade backfill].freeze

    validates :scope_change_reason, inclusion: { in: SCOPE_CHANGE_REASONS }, allow_nil: true

    def revoked? = revoked_at.present?

    # Whether this connection acts on behalf of the human who approved it: a
    # message its client delivers into a session is recorded as that human's.
    # Read from the stored scope on every request, so a downgrade on the
    # connections page applies to the very next call without touching a token.
    def acts_as_human?
      !revoked? && OauthServer.scope_tokens(scope).include?(OauthServer::ACT_AS_HUMAN_SCOPE)
    end

    def privilege
      OauthServer.scope_tokens(scope).include?(OauthServer::ACT_AS_HUMAN_SCOPE) ? OauthServer::ACT_AS_HUMAN : OauthServer::RELAY_ONLY
    end

    # The client's own name for itself, or a stand-in. A self-registered client
    # chooses this string, so renderers must still treat it as untrusted.
    def client_label
      client.client_name.presence || "Unnamed client"
    end

    # Move this grant to `privilege` (OauthServer::PRIVILEGES), recording why.
    # A no-op when it is already there, so a double submit writes nothing.
    #
    # @return [Boolean] whether the scope changed
    def change_privilege!(privilege, reason:)
      target = OauthServer.scope_for(privilege)
      return false if scope == target

      update!(scope: target, scope_changed_at: Time.current, scope_change_reason: reason)
      Rails.logger.warn("[oauth_server] grant #{id} (#{user_email}, client #{client.client_id.inspect}) " \
        "privilege set to #{privilege} (#{reason})")
      true
    end

    def revoke!(reason)
      return if revoked?

      update!(revoked_at: Time.current, revocation_reason: reason)
      Rails.logger.warn("[oauth_server] grant #{id} (#{user_email}, client #{client.client_id.inspect}) revoked: #{reason}")
    end

    # Mint an access token and a refresh token for this grant.
    def issue_tokens!(config: OauthServer::Config.current)
      access = "#{OauthServer::ACCESS_TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
      refresh = "#{OauthServer::REFRESH_TOKEN_PREFIX}#{SecureRandom.urlsafe_base64(32)}"
      now = Time.current
      # Spent and expired tokens have nothing left to say; drop them so a
      # connection refreshed hourly for months is not thousands of rows.
      tokens.where(expires_at: ...now).delete_all

      Token.insert_all!([
        { oauth_server_grant_id: id, kind: Token::ACCESS, token_digest: OauthServer.digest(access),
          expires_at: now + config.access_token_ttl, created_at: now, updated_at: now },
        { oauth_server_grant_id: id, kind: Token::REFRESH, token_digest: OauthServer.digest(refresh),
          expires_at: now + config.refresh_token_ttl, created_at: now, updated_at: now }
      ])

      TokenPair.new(access_token: access, refresh_token: refresh, expires_in: config.access_token_ttl.to_i)
    end

    def touch_last_used!
      update_column(:last_used_at, Time.current) if last_used_at.nil? || last_used_at < 1.minute.ago
    end
  end
end
