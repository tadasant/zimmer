# frozen_string_literal: true

# Phase 3, the last, of moving `sessions`' five queryable `json` columns to
# `jsonb` (#847). `20260905193000_add_jsonb_shadow_columns_to_sessions` added the
# shadows and `20260912140000_swap_sessions_jsonb_shadows_into_place` renamed
# them over the originals, leaving two dead names per conversion:
#
#   * `<name>_json_legacy` — the original `json` column, renamed aside as the undo
#     for that migration's convergence.
#   * `<name>_jsonb` — re-added empty, for #1018's containers to write into for
#     the length of that swap window.
#
# #1179's image put all ten in `Session.ignored_columns`, and that image is live,
# so no running container selects or inserts any of them. Dropping them is
# catalog-only: `DROP COLUMN` marks the attribute dropped and rewrites nothing.
#
# `transcript` stays `json` — that is the intended end state, not unfinished
# work. The reasoning is in the phase-1 migration's comment.
#
# `down` restores the column shapes, not the values: the legacy columns come back
# empty. The values they held were the pre-swap copy of what `config`,
# `mcp_servers`, `mcp_server_env`, `mcp_server_headers` and `metadata` still hold.
#
# two-phase-drop: phase 2 of #1179
class DropDeadJsonColumnsFromSessions < ActiveRecord::Migration[8.0]
  COLUMNS = %i[config mcp_servers mcp_server_env mcp_server_headers metadata].freeze

  def up
    COLUMNS.each do |name|
      remove_column :sessions, :"#{name}_json_legacy"
      remove_column :sessions, :"#{name}_jsonb"
    end
  end

  def down
    COLUMNS.each do |name|
      add_column :sessions, :"#{name}_json_legacy", :json
      add_column :sessions, :"#{name}_jsonb", :jsonb
    end
  end
end
