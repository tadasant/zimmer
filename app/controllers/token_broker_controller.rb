# frozen_string_literal: true

# The Token broker page (TokenBroker): every authorization server a catalog
# entry opts into brokered auth on, whether Zimmer holds the parent grant for
# it, and the one-time consent that creates that grant.
#
# The consent is the normal OAuth authorize flow as Zimmer's hosted client
# (OauthClientIdentity), finished by the shared `/mcp_oauth/callback` — the one
# redirect URI the client's metadata document lists — which recognizes a broker
# flow by its `broker_authorization_server` and stores an McpBrokerGrant rather
# than a per-entry McpOauthCredential.
#
# No token is ever rendered here: the page shows status, timestamps, counts and
# the last error.
class TokenBrokerController < ApplicationController
  layout "application"

  def show
    declarations = TokenBroker.declarations_by_authorization_server
    grants = McpBrokerGrant.all.index_by(&:authorization_server)
    origins = (declarations.keys + grants.keys).uniq.sort

    @identity_enabled = OauthClientIdentity.enabled?
    @client_id = OauthClientIdentity.client_id
    @invalid_declarations = ServersConfig.all.filter_map { |server| TokenBroker::Declaration.for(server) }.reject(&:valid?)
    @servers = origins.map do |origin|
      grant = grants[origin]
      tokens = grant ? grant.brokered_tokens : McpBrokeredToken.none
      {
        origin: origin,
        declarations: declarations.fetch(origin, []),
        grant: grant,
        live_session_tokens: tokens.for_sessions.live.unexpired.count,
        live_backend_tokens: tokens.for_backend.live.unexpired.count,
        pending_revocations: tokens.revoke_pending.count,
        failing_revocations: tokens.revoke_pending.where("revoke_attempts > 0").count,
        last_revoke_error: tokens.revoke_pending.where.not(last_revoke_error: nil).order(updated_at: :desc).pick(:last_revoke_error)
      }
    end
  end

  # POST /token_broker/connect — start the one-time consent for one
  # authorization server.
  def connect
    origin = TokenBroker.normalize_origin(params[:authorization_server])
    declarations = TokenBroker.declarations_by_authorization_server.fetch(origin, [])

    # Only an authorization server the catalog opts an entry into, or one
    # Zimmer already holds a grant for (a reconnect). A forged POST cannot
    # point discovery anywhere else.
    if origin.nil? || (declarations.empty? && McpBrokerGrant.for_authorization_server(origin).nil?)
      return redirect_with_error("#{params[:authorization_server].to_s.truncate(100)} is not an authorization server any catalog entry opts into brokered auth on.")
    end

    unless OauthClientIdentity.enabled?
      return redirect_with_error("Zimmer's OAuth client identity is not configured on this deployment " \
        "(#{OauthClientIdentity::BASE_URL_ENV} and a signing key), so it cannot be a token broker client yet.")
    end

    resources = declarations.map(&:resource).uniq
    resources = [ McpBrokerGrant.for_authorization_server(origin).resource ] if resources.empty?
    if resources.size != 1
      return redirect_with_error("The entries on #{origin} name more than one resource (#{resources.join(', ')}); one grant can serve only one.")
    end

    metadata = TokenBroker::Client.new.discover(origin)
    problem = consent_problem(origin, metadata)
    return redirect_with_error(problem) if problem

    oauth_service = McpOauthService.new
    redirect_uri = OauthClientIdentity.redirect_uri
    McpOauthPendingFlow.where(session_id: nil, broker_authorization_server: origin).destroy_all
    McpOauthPendingFlow.sweep_expired_session_less!
    pending_flow = McpOauthPendingFlow.start!(
      session: nil,
      server_name: "token-broker #{origin}",
      server_url: resources.first,
      oauth_metadata: {
        authorization_endpoint: metadata.authorization_endpoint,
        token_endpoint: metadata.token_endpoint,
        client_id: OauthClientIdentity.client_id,
        client_secret: nil,
        # The whole ceiling strad's client entry for Zimmer allows; each child
        # narrows to exactly its session's slugs.
        scopes: "mcp",
        resource: resources.first,
        manual: oauth_service.manual_completion_required?(redirect_uri)
      },
      redirect_uri: redirect_uri,
      mcp_server_config: { "type" => "streamable-http", "url" => resources.first },
      broker_authorization_server: origin
    )

    if pending_flow.manual?
      @pending_flow = pending_flow
      render "mcp_oauth/manual"
    else
      redirect_to pending_flow.authorization_url, allow_other_host: true
    end
  rescue TokenBroker::Client::Error => e
    redirect_with_error("Could not start the consent for #{origin}: #{e.message}")
  end

  # DELETE /token_broker/disconnect — revoke the parent grant at the
  # authorization server (which ends every child under it) and forget it.
  def disconnect
    grant = McpBrokerGrant.for_authorization_server(params[:authorization_server])
    return redirect_with_error("Zimmer holds no token broker grant for that server.") unless grant

    origin = grant.authorization_server
    revoked = begin
      grant.refresh_token.present? && TokenBroker::Client.new.revoke(grant, grant.refresh_token, token_type_hint: "refresh_token")
    rescue TokenBroker::Client::Error, OauthClientIdentity::Unavailable => e
      Rails.logger.warn("[TokenBrokerController] revoking the grant for #{origin} failed: #{e.message}")
      false
    end
    grant.destroy!

    if revoked
      flash[:notice] = "Disconnected #{origin}: the grant and every token minted under it are revoked."
    else
      flash[:error] = "Forgot the grant for #{origin}, but #{origin} did not confirm revoking it. " \
        "Revoke it on #{origin}'s own grants page; its child tokens end when it does, or when they expire."
    end
    redirect_to token_broker_path
  end

  private

  # Refuse before the human consents, not after, when the authorization server
  # could not serve the broker anyway.
  def consent_problem(origin, metadata)
    return "#{origin} advertises no authorization endpoint." if metadata.authorization_endpoint.blank?
    unless HttpsTokenEndpoint.secure?(metadata.token_endpoint)
      return "#{origin} advertises a token endpoint Zimmer will not use (#{HttpsTokenEndpoint.describe(metadata.token_endpoint)})."
    end
    return "#{origin} advertises no revocation endpoint, so brokered tokens could not be revoked at rest." if metadata.revocation_endpoint.blank?
    unless metadata.grant_types_supported.include?(TokenBroker::Client::TOKEN_EXCHANGE_GRANT)
      return "#{origin} does not offer token exchange (RFC 8693) yet. Its client entry for Zimmer needs a " \
        "`tokenExchange` block, with grant records on, before a grant there can mint session tokens."
    end

    nil
  end

  def redirect_with_error(message)
    flash[:error] = message
    redirect_to token_broker_path
  end
end
