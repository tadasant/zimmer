# frozen_string_literal: true

# The rollout switch for WarmProcessPool: an idle Claude Code process kept booted
# for the router root, so a Quick Router request skips process start, CLI boot
# and MCP connect. Ships off, so the deploy changes nothing until an operator
# turns it on from Settings → Experimental.
class AddWarmRouterProcessEnabledToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :warm_router_process_enabled, :boolean, default: false, null: false
  end
end
