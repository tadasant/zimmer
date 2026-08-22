# frozen_string_literal: true

# Promote MCP tool search from a Zimmer Extension to a first-class app setting,
# and default it ON.
#
# The extension-gated version (`mcp_tool_search`, id-keyed in
# `extension_states`) could never take effect in a deployed container:
# `.dockerignore` excludes `/app/extensions/*/`, so the class does not exist in
# the image, `ExtensionRegistry` skips it, and the spawn-env baseline of
# ENABLE_TOOL_SEARCH=false always stood. A column ships in the image like every
# other setting, so the toggle actually does something in production.
#
# Existing rows resolve to ON: Postgres fills the new column with its DEFAULT
# when it is added, so an already-deployed singleton row lands on `true` without
# a separate backfill. The previously-stored `mcp_tool_search` extension state is
# NOT carried over — it was written by a toggle that had no effect in any built
# image, so a stored `false` is the shipped default rather than a deliberate
# choice, and honoring it would silently deny the new default to the one
# deployment this change exists for. An operator who wants it off turns it off
# once, on the same Settings page.
class AddMcpToolSearchEnabledToAppSettings < ActiveRecord::Migration[8.0]
  def up
    add_column :app_settings, :mcp_tool_search_enabled, :boolean, null: false, default: true

    # Retire the superseded extension key so the two controls can't disagree.
    execute <<~SQL.squish
      UPDATE app_settings SET extension_states = extension_states - 'mcp_tool_search'
    SQL
  end

  # Best-effort, and lossy in the same direction `up` is: the restored extension
  # state is whatever the column currently says, so a rollback hands the retired
  # extension the setting's value rather than the value it had before `up` ran.
  def down
    execute <<~SQL.squish
      UPDATE app_settings
      SET extension_states = extension_states || jsonb_build_object('mcp_tool_search', mcp_tool_search_enabled)
    SQL

    remove_column :app_settings, :mcp_tool_search_enabled
  end
end
