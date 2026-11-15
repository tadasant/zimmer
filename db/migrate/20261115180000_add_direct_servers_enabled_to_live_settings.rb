# frozen_string_literal: true

# Whether the Live Mode assistant may attach catalog MCP servers to itself and
# call their tools directly (LiveConversations::ToolBridge). NULL is the shipped
# default, as for every other LiveSetting column: "off".
class AddDirectServersEnabledToLiveSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :live_settings, :direct_servers_enabled, :string
  end
end
