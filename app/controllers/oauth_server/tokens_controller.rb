# frozen_string_literal: true

module OauthServer
  # POST /oauth/token — the `authorization_code` and `refresh_token` grants.
  #
  # Public clients only: the client names itself with `client_id` in the body
  # and proves possession with the PKCE verifier (for a code) or the refresh
  # token itself. Refresh tokens rotate: every refresh spends the one presented
  # and returns a new one, and presenting a spent one again later than
  # Grant::REPLAY_GRACE revokes the whole grant (RFC 9700 §4.14.2).
  class TokensController < BaseController
    VERIFIER_FORMAT = /\A[A-Za-z0-9\-._~]{43,128}\z/

    def create
      no_store
      case params[:grant_type]
      when "authorization_code" then exchange_code
      when "refresh_token" then refresh
      when nil, "" then raise OauthServer::Error.new("invalid_request", "grant_type is required")
      else raise OauthServer::Error.new("unsupported_grant_type", "grant_type must be authorization_code or refresh_token")
      end
    end

    private

    def exchange_code
      client = OauthServer::Client.find_known!(params[:client_id])

      code = OauthServer::AuthorizationCode.consume(params[:code].to_s)
      raise invalid_grant("the authorization code is invalid, expired, or already used") if code.nil?
      raise invalid_grant("the authorization code was issued to a different client") unless code.oauth_server_client_id == client.id
      if params.key?(:redirect_uri) && params[:redirect_uri] != code.redirect_uri
        raise invalid_grant("redirect_uri does not match the authorization request")
      end
      raise invalid_grant("code_verifier does not match the code_challenge") unless pkce_valid?(params[:code_verifier], code.code_challenge)

      check_resource!(code.resource)
      raise invalid_grant("#{code.user_email} is no longer in an allowed domain") unless oauth_config.email_allowed?(code.user_email)

      grant = OauthServer::Grant.create!(client: client, user_email: code.user_email, resource: code.resource,
        scope: code.scope, last_used_at: Time.current)
      client.touch_last_used!
      Rails.logger.info("[oauth_server] grant #{grant.id} issued to #{client.client_id.inspect} for #{grant.user_email}")

      render_tokens(grant)
    end

    def refresh
      client = OauthServer::Client.find_known!(params[:client_id])

      lookup = OauthServer::Token.lookup(params[:refresh_token].to_s, kind: OauthServer::Token::REFRESH)
      raise invalid_grant("the refresh token is #{lookup.refusal}") unless lookup.ok?

      token = lookup.token
      grant = token.grant
      raise invalid_grant("the refresh token was issued to a different client") unless grant.oauth_server_client_id == client.id

      if token.rotated_at
        if token.rotated_at > OauthServer::Grant::REPLAY_GRACE.ago
          raise invalid_grant("the refresh token has already been used")
        end

        grant.revoke!("a spent refresh token was presented again")
        raise invalid_grant("the refresh token has already been used; the grant is revoked")
      end

      check_resource!(grant.resource)
      unless oauth_config.email_allowed?(grant.user_email)
        grant.revoke!("#{grant.user_email} is no longer in an allowed domain")
        raise invalid_grant("#{grant.user_email} is no longer in an allowed domain")
      end
      raise invalid_grant("the refresh token has already been used") unless token.rotate!

      grant.touch_last_used!
      client.touch_last_used!
      render_tokens(grant)
    end

    def render_tokens(grant)
      pair = grant.issue_tokens!(config: oauth_config)
      render json: {
        access_token: pair.access_token,
        token_type: "Bearer",
        expires_in: pair.expires_in,
        refresh_token: pair.refresh_token,
        scope: OauthServer::SCOPE
      }
    end

    def pkce_valid?(verifier, challenge)
      return false unless verifier.is_a?(String) && verifier.match?(VERIFIER_FORMAT)

      computed = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      ActiveSupport::SecurityUtils.secure_compare(computed, challenge)
    end

    # RFC 8707: a `resource` on the token request may only name the resource the
    # grant is already bound to.
    def check_resource!(bound)
      return if params[:resource].blank?
      return if oauth_config.resource_matches?(params[:resource]) && bound == oauth_config.resource

      raise OauthServer::Error.new("invalid_target", "resource must be #{bound}")
    end

    def invalid_grant(description)
      OauthServer::Error.new("invalid_grant", description)
    end
  end
end
