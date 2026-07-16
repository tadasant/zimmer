# Adds the `manual` flag that marks a pending flow as completed via out-of-band
# ("paste-back") redirect rather than a Zimmer-hosted callback. Manual flows are
# used for public OAuth clients that only permit a localhost/oob redirect URI
# (e.g. the official hosted Slack MCP client).
class AddManualToMcpOauthPendingFlows < ActiveRecord::Migration[8.1]
  def change
    add_column :mcp_oauth_pending_flows, :manual, :boolean, default: false, null: false
  end
end
