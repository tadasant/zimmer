# frozen_string_literal: true

# The switch for delivering a session's provenance context — the session
# hierarchy and the human-message record — through an MCP tool the session calls
# on demand, instead of baking both blocks into every user turn.
#
# Ships ON. The off path is the existing always-injected behaviour, unchanged,
# which is what makes flipping this back the rollback.
class AddProvenanceViaMcpEnabledToAppSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :app_settings, :provenance_via_mcp_enabled, :boolean, default: true, null: false
  end
end
