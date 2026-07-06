# frozen_string_literal: true

# Feature flag (default OFF) globally enabling MCP tool search for newly spawned
# Claude Code sessions. When off (the default), spawned sessions run with
# ENABLE_TOOL_SEARCH=false — the historical behavior, where tool search is
# disabled to avoid unnecessary overhead during agent execution. Flipping it on
# from the settings page lets newly spawned sessions use MCP tool search.
class AddEnableToolSearchToAppSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :app_settings, :enable_tool_search, :boolean, null: false, default: false
  end
end
