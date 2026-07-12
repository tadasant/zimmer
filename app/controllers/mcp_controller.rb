# frozen_string_literal: true

# Zimmer's native MCP endpoint (streamable HTTP transport).
#
#   POST /mcp                                    → the full tool surface
#   POST /mcp?tool_groups=sessions               → session orchestration only
#   POST /mcp?tool_groups=self_session           → the self-management subset
#   POST /mcp?tool_groups=sessions&allowed_agent_roots=zimmer
#
# Auth is the same API key the rest of the API uses: an `X-API-Key` header
# matched against the API_KEYS env var (see Api::BaseController). MCP clients
# that only speak `Authorization: Bearer …` are accepted too — the bearer token
# is matched against the same key list, so there is exactly one credential to
# provision.
#
# The transport is stateless: each POST is a complete JSON-RPC message and gets a
# complete JSON response, so no Mcp-Session-Id is issued and any web worker can
# serve any request. GET (server-initiated SSE) is not supported, which the spec
# permits a server to signal with 405.
class McpController < Api::BaseController
  # A JSON-RPC notification (a message with no `id`) gets an empty 202, per the
  # streamable-HTTP transport.
  def handle
    messages, batch = parse_body

    server = Mcp::Server.new(context: mcp_context)
    responses = messages.map { |message| server.handle(message) }.compact

    if responses.empty?
      head :accepted
    elsif batch
      render json: responses
    else
      render json: responses.first
    end
  rescue JSON::ParserError => e
    render json: Mcp::JsonRpc.error(nil, Mcp::JsonRpc::PARSE_ERROR, "Parse error: #{e.message}"), status: :bad_request
  end

  # The spec lets a server that does not offer server-initiated streams reject
  # GET; DELETE only applies to stateful sessions, which this transport does not
  # issue.
  def unsupported
    render json: Mcp::JsonRpc.error(nil, Mcp::JsonRpc::METHOD_NOT_FOUND, "Method Not Allowed: this MCP endpoint only accepts POST"),
           status: :method_not_allowed
  end

  private

  def parse_body
    raw = request.raw_post
    raise JSON::ParserError, "empty request body" if raw.blank?

    parsed = JSON.parse(raw)
    parsed.is_a?(Array) ? [ parsed, true ] : [ [ parsed ], false ]
  end

  def mcp_context
    Mcp::Context.new(
      tool_groups: params[:tool_groups],
      allowed_agent_roots: params[:allowed_agent_roots],
      base_url: request.base_url
    )
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
