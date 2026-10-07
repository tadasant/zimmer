# frozen_string_literal: true

module OauthServer
  # The code /oauth/authorize hands back after the human consents. Single use,
  # sixty seconds, bound to the client, the redirect URI, the PKCE challenge and
  # the resource. Only its digest is stored.
  class AuthorizationCode < ApplicationRecord
    TTL = 60.seconds

    belongs_to :client, class_name: "OauthServer::Client", foreign_key: :oauth_server_client_id,
      inverse_of: :authorization_codes

    # @return [Array(AuthorizationCode, String)] the row and the only plaintext copy of the code
    def self.issue!(client:, redirect_uri:, code_challenge:, resource:, user_email:)
      code = SecureRandom.urlsafe_base64(32)
      row = create!(
        client: client,
        code_digest: OauthServer.digest(code),
        redirect_uri: redirect_uri,
        code_challenge: code_challenge,
        resource: resource,
        scope: OauthServer::SCOPE,
        user_email: user_email,
        expires_at: TTL.from_now
      )
      [ row, code ]
    end

    # Spend the code. A conditional UPDATE, so of two concurrent redemptions
    # exactly one wins.
    #
    # @return [AuthorizationCode, nil] the row, when this call was the one that spent it
    def self.consume(code)
      row = find_by(code_digest: OauthServer.digest(code))
      return nil if row.nil? || row.expires_at <= Time.current

      claimed = where(id: row.id, consumed_at: nil).update_all(consumed_at: Time.current, updated_at: Time.current)
      claimed == 1 ? row : nil
    end
  end
end
