# frozen_string_literal: true

# API controller for listing available MCP servers.
#
# Provides read-only access to MCP server metadata from the configuration catalog.
# Only exposes non-sensitive fields (name, title, description).
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
  def index
    servers = ServersConfig.all.map do |server|
      {
        name: server.name,
        title: server.title,
        description: server.description
      }
    end

    render json: { mcp_servers: servers }
  end
end
