# frozen_string_literal: true

module OauthServer
  # POST /oauth/token — the `authorization_code` and `refresh_token` grants.
  #
  # Public clients only: the client names itself with `client_id` in the body
  # and proves possession with the PKCE verifier (for a code) or the refresh
  # token itself. Refresh tokens rotate: every refresh spends the one presented
  # and returns a new one. Presenting a spent one again revokes the whole grant
  # (RFC 9700 §4.14.2) — unless the pair it was traded for was never used, which
  # is a client that never received its answer, and gets a new pair (#rotate).
  class TokensController < BaseController
    VERIFIER_FORMAT = /\A[A-Za-z0-9\-._~]{43,128}\z/

    def create
      no_store
      # Nothing is issued by a deployment that cannot say whose tokens they are
      # (503 through BaseController), even a refresh that names no resource.
      oauth_config.issuer
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

      code = OauthServer::AuthorizationCode.consume(params[:code].to_s, client: client)
      raise invalid_grant("the authorization code is invalid, expired, already used, or issued to a different client") if code.nil?
      if params.key?(:redirect_uri) && params[:redirect_uri] != code.redirect_uri
        raise invalid_grant("redirect_uri does not match the authorization request")
      end
      raise invalid_grant("code_verifier does not match the code_challenge") unless pkce_valid?(params[:code_verifier], code.code_challenge)

      check_resource!(code.resource)
      raise invalid_grant("#{code.user_email} is no longer in an allowed domain") unless oauth_config.email_allowed?(code.user_email)

      grant = OauthServer::Grant.create!(client: client, user_email: code.user_email, resource: code.resource,
        scope: code.scope, scope_changed_at: Time.current, scope_change_reason: "consent", last_used_at: Time.current)
      client.touch_last_used!
      Rails.logger.info("[oauth_server] grant #{grant.id} issued to #{client.client_id.inspect} for #{grant.user_email} (#{grant.privilege})")

      render_tokens(grant, grant.issue_tokens!(config: oauth_config))
    end

    def refresh
      client = OauthServer::Client.find_known!(params[:client_id])

      lookup = OauthServer::Token.lookup(params[:refresh_token].to_s, kind: OauthServer::Token::REFRESH)
      raise invalid_grant("the refresh token is #{lookup.refusal}") unless lookup.ok?

      token = lookup.token
      grant = token.grant
      raise invalid_grant("the refresh token was issued to a different client") unless grant.oauth_server_client_id == client.id

      check_resource!(grant.resource)
      check_domain!(grant)

      # One refresh of a connection at a time, so two presentations of one token
      # decide in turn. Nothing raises inside, which would roll back the
      # rotation; the refusal and the revoke happen after the lock.
      pair = grant.with_lock { rotate(token.reload, grant) }
      if pair == :replayed
        raise invalid_grant("the refresh token has already been used") if token.rotated_at > OauthServer::Grant::REPLAY_GRACE.ago

        grant.revoke!("a spent refresh token was presented again")
        raise invalid_grant("the refresh token has already been used; the grant is revoked")
      end

      grant.touch_last_used!
      client.touch_last_used!
      render_tokens(grant, pair)
    end

    # Spend `token` and issue its replacement — or, when it was already spent,
    # tell a lost answer from a replay. A client whose refresh reached the server
    # but whose answer did not (a phone suspended mid-request, a dropped
    # connection) still holds the spent token, and no pair it was traded for has
    # been used: that client gets another pair. Every pair issued for one spent
    # token stays live until one of them is used, and that first use retires the
    # rest (Token#claim_pair!), so the client that refreshed twice at once and
    # the client that lost an answer both end up with exactly one live pair, and
    # presenting a retired refresh token later reads as the replay it would be.
    #
    # @return [Grant::TokenPair, :replayed]
    def rotate(token, grant)
      if token.rotate!
        token.claim_pair!
        return grant.issue_tokens!(config: oauth_config, rotated_from: token)
      end
      return :replayed unless token.successors_unused?

      Rails.logger.warn("[oauth_server] grant #{grant.id} (#{grant.user_email}, client #{grant.client.client_id.inspect}) " \
        "presented a spent refresh token whose rotated pair was never used; issuing another")
      grant.issue_tokens!(config: oauth_config, rotated_from: token)
    end

    # A refresh ends a grant whose human has left the allowed domains. An empty
    # list is not that: it is a store that did not answer, or nothing
    # configured, and either way says nothing about this human — so nothing is
    # issued and nothing is revoked.
    def check_domain!(grant)
      if oauth_config.allowed_domains.empty?
        raise OauthServer::Error.new("temporarily_unavailable", "the allowed domains cannot be read; try again later")
      end
      return if oauth_config.email_allowed?(grant.user_email)

      grant.revoke!("#{grant.user_email} is no longer in an allowed domain")
      raise invalid_grant("#{grant.user_email} is no longer in an allowed domain")
    end

    def render_tokens(grant, pair)
      render json: {
        access_token: pair.access_token,
        token_type: "Bearer",
        expires_in: pair.expires_in,
        refresh_token: pair.refresh_token,
        # The scope the grant holds NOW, which is the human's choice rather than
        # the client's request (RFC 6749 §5.1 requires saying so when they differ).
        scope: grant.scope.presence || OauthServer::SCOPE
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
