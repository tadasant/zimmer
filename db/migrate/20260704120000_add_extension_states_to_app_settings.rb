# frozen_string_literal: true

# Replace the per-feature boolean flags (pty_headless_inference,
# enable_tool_search) with a single generic JSONB enablement map keyed by AO
# Extension id. A schema-less store means a new extension needs no migration —
# the load-bearing property for a drop-in OSS extension — and the two retired
# experiments simply become the "pty_transport" and "mcp_tool_search" keys.
class AddExtensionStatesToAppSettings < ActiveRecord::Migration[8.0]
  def up
    add_column :app_settings, :extension_states, :jsonb, null: false, default: {}

    # Carry the existing flag values over into the new store so an operator who
    # had either experiment on keeps it on across the migration.
    execute <<~SQL.squish
      UPDATE app_settings
      SET extension_states = jsonb_build_object(
        'pty_transport', COALESCE(pty_headless_inference, false),
        'mcp_tool_search', COALESCE(enable_tool_search, false)
      )
    SQL

    remove_column :app_settings, :pty_headless_inference
    remove_column :app_settings, :enable_tool_search
  end

  def down
    add_column :app_settings, :pty_headless_inference, :boolean, null: false, default: false
    add_column :app_settings, :enable_tool_search, :boolean, null: false, default: false

    execute <<~SQL.squish
      UPDATE app_settings SET
        pty_headless_inference = COALESCE((extension_states ->> 'pty_transport')::boolean, false),
        enable_tool_search = COALESCE((extension_states ->> 'mcp_tool_search')::boolean, false)
    SQL

    remove_column :app_settings, :extension_states
  end
end
