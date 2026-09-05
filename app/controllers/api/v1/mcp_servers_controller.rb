# frozen_string_literal: true

# API controller for listing available MCP servers.
#
# Provides read-only access to MCP server metadata from the configuration catalog.
# Only exposes non-sensitive fields (name, title, description, availability).
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::McpServersController < Api::BaseController
  # GET /api/v1/mcp_servers
  # List all available MCP servers with their metadata.
  #
  # Returns only non-sensitive fields:
  #   - name: Machine-readable server identifier
  #   - title: Human-readable display name
  #   - description: Brief description of the server's purpose
  #   - unavailable: true when Zimmer cannot start this server right now
  #   - unavailable_reason: why, in a few words; nil unless `unavailable`
  #
  # The list is never filtered. An unavailable server exists and should not be
  # re-registered — it is flagged so a caller does not attach one, since an
  # unresolved `${VAR}` fails the whole session at prepare time. Same list, same
  # flags, as the session form's picker; see McpServerOptions.
  def index
    render json: { mcp_servers: McpServerOptions.all }
  end
end
