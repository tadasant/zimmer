# Adds the RFC 8707 resource indicator (the canonical resource identifier the MCP
# server expects, discovered via RFC 9728 Protected Resource Metadata) to the
# OAuth tables. The value is captured during discovery and persisted so it can be
# sent on the authorize request, the token exchange, AND later refreshes (which
# run from cron without re-running discovery). Servers that enforce audience
# binding (e.g. Notion) reject tokens minted without it.
class AddResourceToMcpOauthTables < ActiveRecord::Migration[8.0]
  def change
    add_column :mcp_oauth_pending_flows, :resource, :string
    add_column :mcp_oauth_credentials, :resource, :string
  end
end
