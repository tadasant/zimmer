# frozen_string_literal: true

# Zimmer as an OAuth 2.1 authorization server for its own `POST /mcp`.
#
# A remote MCP client — Claude.ai's custom connectors, the MCP Inspector — finds
# this server through `/.well-known/oauth-protected-resource/mcp`, registers itself
# (Dynamic Client Registration, or a Client ID Metadata Document), sends the human
# through `/oauth/authorize`, and calls `/mcp` with the access token it gets back.
# The static API key keeps working beside it.
#
# Not to be confused with McpOauthService and McpOauthCredential, which are the
# other direction: Zimmer as an OAuth *client* of somebody else's MCP server.
#
# docs/src/content/docs/auth/mcp-authorization-server.md is the prose.
module OauthServer
  def self.table_name_prefix
    "oauth_server_"
  end

  # The one scope this server issues. A token opens `/mcp` — what an `api` key
  # opens there — and nothing else, so there is nothing finer to ask for.
  SCOPE = "mcp"

  ACCESS_TOKEN_PREFIX = "zmr_oat_"
  REFRESH_TOKEN_PREFIX = "zmr_ort_"

  def self.digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end
end
