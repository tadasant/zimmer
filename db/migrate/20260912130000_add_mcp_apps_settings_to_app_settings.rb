# frozen_string_literal: true

# The two knobs that decide whether Zimmer renders MCP App (`ui://`) fragments in
# the session detail page, and for which MCP servers.
#
# Both default to the closed position. `mcp_apps_enabled` is the master switch and
# ships off; `mcp_apps_allowed_servers` is the per-server opt-in and ships empty,
# so turning the master switch on by itself still renders nothing. A fragment is
# third-party HTML executing in an operator's browser, and the only thing that can
# say a given MCP server is trusted enough for that is a human naming it.
class AddMcpAppsSettingsToAppSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :app_settings, :mcp_apps_enabled, :boolean, default: false, null: false
    add_column :app_settings, :mcp_apps_allowed_servers, :jsonb, default: [], null: false
  end
end
