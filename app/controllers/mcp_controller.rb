# frozen_string_literal: true

require "mcp"

# Zimmer's native MCP endpoint (streamable HTTP transport).
#
#   POST /mcp                                    → the default surface: every base group
#   POST /mcp?tool_groups=sessions               → session orchestration only
#   POST /mcp?tool_groups=self_session           → the self-management subset
#   POST /mcp?tool_groups=sessions&allowed_agent_roots=zimmer
#   POST /mcp?tool_groups=self_session&session_id=42
#
# `session_id` names the session the entry was written for, so a tool that acts
# on "the calling session" can default to it. It is a default, never a scope:
# tool_groups and allowed_agent_roots remain the only things that govern reach.
#
# The protocol itself (JSON-RPC framing, version negotiation, tools/list,
# tools/call, ping, notifications) is the official MCP Ruby SDK's. This controller
# supplies the two things the SDK cannot know: who is allowed to call (the API
# key), and what this connection may see (the scoped tool list).
#
# Auth is the same API key the rest of the API uses: an `X-API-Key` header matched
# against the API_KEYS env var and the minted keys (see Api::BaseController and
# ApiKey). MCP clients that only speak `Authorization: Bearer …` are accepted too —
# the bearer token is matched against the same keys, so there is exactly one
# credential to provision.
#
# The second credential is an OAuth access token from Zimmer's own authorization
# server (OauthServer): what a remote MCP client such as a Claude.ai custom
# connector holds after a human approved it at /oauth/authorize. It opens exactly
# what an `api` key opens here — every tool group, `?tool_groups=` honoured the
# same way — and nothing outside /mcp. An unauthenticated request is answered 401
# with a `WWW-Authenticate` header naming the protected-resource metadata
# (RFC 9728), which is how such a client discovers where to get a token.
#
# The transport runs stateless: each POST is a complete JSON-RPC message and gets
# a complete JSON response, so no Mcp-Session-Id is issued and any Puma worker can
# serve any request. A server built per request is also what lets the same
# endpoint serve every scoped variant.
class McpController < Api::BaseController
  def handle
    status, headers, body = transport.handle_request(request)

    headers.each { |key, value| response.set_header(key, value) }

    # A JSON-RPC notification is answered with an empty 202, and a cancelled
    # request with no body at all.
    payload = Array(body).first
    return head(status) if payload.blank?

    render json: payload, status: status
  end

  private

  # An OAuth access token (it carries a prefix no API key does) is checked as
  # one; anything else takes the API-key path, unchanged. Either refusal carries
  # the WWW-Authenticate challenge an OAuth client starts from.
  def authenticate_api_key
    token = bearer_token
    if oauth_access_tokens_accepted? && token&.start_with?(OauthServer::ACCESS_TOKEN_PREFIX)
      authenticate_oauth_access_token(token)
    else
      super
    end

    challenge_oauth_client if performed? && response.status == 401
  end

  def authenticate_oauth_access_token(token)
    config = OauthServer::Config.current
    lookup = if config.configured?
      OauthServer::Token.authenticate_access(token, resource: config.resource)
    else
      OauthServer::Token::Lookup.new(token: nil, refusal: :server_not_configured)
    end

    if lookup.ok?
      @oauth_grant = lookup.grant
      Rails.logger.info("[oauth_server] #{request.request_method} #{request.path} authenticated as grant #{@oauth_grant.id} " \
        "(#{@oauth_grant.user_email}, client #{@oauth_grant.client.client_id.inspect})")
    else
      Rails.logger.info("[oauth_server] #{request.request_method} #{request.path} refused from #{request.remote_ip}: access token #{lookup.refusal}")
      @oauth_token_refused = true
      render_api_error("Unauthorized", "Invalid or expired access token", status: :unauthorized)
    end
  end

  # RFC 6750 §3 / RFC 9728 §5.1. `error="invalid_token"` only when a credential
  # was presented: a request with none is told where to get one, not that it
  # sent a bad one.
  def challenge_oauth_client
    return unless oauth_access_tokens_accepted?

    config = OauthServer::Config.current
    parts = [ 'realm="zimmer"' ]
    parts << 'error="invalid_token"' if @oauth_token_refused || api_key_from_request.present?
    parts << %(resource_metadata="#{config.protected_resource_metadata_url}") if config.configured?
    parts << %(scope="#{OauthServer::SCOPE}")
    response.set_header("WWW-Authenticate", "Bearer #{parts.join(', ')}")
  end

  # Whether this endpoint takes OAuth access tokens at all. /mcp does; a Zimmer
  # plugin's endpoint (ExternalAppMcpController) takes only its plugin's key.
  def oauth_access_tokens_accepted?
    true
  end

  def transport
    MCP::Server::Transports::StreamableHTTPTransport.new(
      mcp_server,
      stateless: true,
      # Respond with plain JSON rather than an SSE frame, and accept a client that
      # asks only for `Accept: application/json`. Nothing this server does needs a
      # stream: there are no long-running tools, no progress notifications, and no
      # server-initiated messages.
      enable_json_response: true,
      # The SDK's Host/Origin check defends a locally-bound server against DNS
      # rebinding by a browser. Zimmer is a deployed Rails app: Rails' own
      # `config.hosts` validates Host, requests carry no ambient credential (the
      # API key is an explicit header, never a cookie), and the allow-list would
      # have to be maintained per deployment host. Rely on those instead.
      dns_rebinding_protection: false
    )
  end

  def mcp_server
    MCP::Server.new(
      name: Mcp::SERVER_NAME,
      title: Mcp::SERVER_TITLE,
      version: Mcp::SERVER_VERSION,
      instructions: instructions,
      tools: mcp_context.tools,
      server_context: mcp_context
    )
  end

  def instructions
    text = "Zimmer's native MCP server. Tools operate on this Zimmer instance's sessions, " \
      "notifications, triggers, system health, the agent gates' decision ledger, the work backlog, " \
      "and the Settings page's global defaults. " \
      "Enabled tool groups: #{mcp_context.tool_groups.join(', ')}."
    return text unless mcp_context.tools.any? { |tool| tool.tool_name == Mcp::Tools::QuickRouter.tool_name }

    # Said first, because a client that does not know Zimmer reads this before
    # any tool description and otherwise starts with get_configs.
    "#{Mcp::Tools::QuickRouter::SERVER_INSTRUCTIONS} #{text}"
  end

  # Scoping is read from the query string, never from `params` — Rails merges a
  # JSON body's top-level keys into params, so a client could otherwise widen its
  # own tool_groups by putting them in the JSON-RPC envelope.
  def mcp_context
    @mcp_context ||= begin
      query = request.query_parameters

      Mcp::Context.new(
        tool_groups: query["tool_groups"],
        allowed_agent_roots: query["allowed_agent_roots"],
        base_url: request.base_url,
        caller_fingerprint: HealthActionCooldown.fingerprint(@oauth_grant ? "oauth_grant:#{@oauth_grant.id}" : api_key_from_request),
        # Which session this connection was written for, so the self-management
        # tools can default their "which session is asking" argument instead of
        # making the agent restate an id it cannot see. Read from the query string
        # for the same reason as the two above: a JSON body must not be able to
        # set it.
        session_id: query["session_id"],
        # Which credential authenticated: an OAuth grant is a remote client a human
        # approved (Claude.ai), an API key is the fleet's. quick_router reads it to
        # pick a default scheduling class; nothing reads it as a scope.
        oauth_grant_id: @oauth_grant&.id
      )
    end
  end

  # MCP clients configured with a bearer token send `Authorization: Bearer <key>`
  # rather than X-API-Key. Both carry the same API key.
  def api_key_from_request
    super.presence || bearer_token
  end

  def bearer_token
    header = request.headers["Authorization"].to_s
    header[/\ABearer\s+(.+)\z/i, 1]&.strip
  end
end
