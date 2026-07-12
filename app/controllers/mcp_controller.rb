# frozen_string_literal: true

require "mcp"

# Zimmer's native MCP endpoint (streamable HTTP transport).
#
#   POST /mcp                                    → the full tool surface
#   POST /mcp?tool_groups=sessions               → session orchestration only
#   POST /mcp?tool_groups=self_session           → the self-management subset
#   POST /mcp?tool_groups=sessions&allowed_agent_roots=zimmer
#
# The protocol itself (JSON-RPC framing, version negotiation, tools/list,
# tools/call, ping, notifications) is the official MCP Ruby SDK's. This controller
# supplies the two things the SDK cannot know: who is allowed to call (the API
# key), and what this connection may see (the scoped tool list).
#
# Auth is the same API key the rest of the API uses: an `X-API-Key` header matched
# against the API_KEYS env var (see Api::BaseController). MCP clients that only
# speak `Authorization: Bearer …` are accepted too — the bearer token is matched
# against the same key list, so there is exactly one credential to provision.
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
    "Zimmer's native MCP server. Tools operate on this Zimmer instance's sessions, " \
      "notifications, triggers, and system health. Enabled tool groups: #{mcp_context.tool_groups.join(', ')}."
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
        base_url: request.base_url
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
