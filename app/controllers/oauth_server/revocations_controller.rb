# frozen_string_literal: true

module OauthServer
  # POST /oauth/revoke — RFC 7009. Revoking either token revokes the grant it
  # descends from, so the connection ends, refresh and all. The answer is always
  # 200, whether or not the token existed, so the endpoint cannot be used to test
  # which tokens are live.
  class RevocationsController < BaseController
    def create
      no_store
      digest = OauthServer.digest(params[:token].to_s)
      token = OauthServer::Token.includes(:grant).find_by(token_digest: digest) if params[:token].present?
      token&.grant&.revoke!("revoked by the client at /oauth/revoke")
      head :ok
    end
  end
end
