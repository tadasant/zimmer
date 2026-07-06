# frozen_string_literal: true

# API controller for exposing all static configurations.
#
# Provides read-only access to application configuration metadata including:
#   - MCP servers (name, title, description only - no sensitive fields)
#   - Agent roots (preconfigured repository settings)
#   - Goals (session completion criteria)
#
# All endpoints require API key authentication via X-API-Key header.
class Api::V1::ConfigsController < Api::BaseController
  # GET /api/v1/configs
  # Returns all static configuration data in a single response.
  #
  # Response structure:
  #   {
  #     mcp_servers: [...],      # Available MCP server options
  #     agent_roots: [...],      # Preconfigured agent repository roots
  #     goals: [...]             # Available session goals
  #   }
  def index
    render json: {
      mcp_servers: mcp_servers_data,
      agent_roots: agent_roots_data,
      goals: goals_data
    }
  end

  private

  # Returns MCP server metadata (non-sensitive fields only)
  def mcp_servers_data
    ServersConfig.all.map do |server|
      {
        name: server.name,
        title: server.title,
        description: server.description
      }
    end
  end

  # Returns agent root configurations
  def agent_roots_data
    AgentRootsConfig.all.map(&:to_h)
  end

  # Returns goal configurations
  def goals_data
    GoalsConfig.all.map(&:to_h)
  end
end
