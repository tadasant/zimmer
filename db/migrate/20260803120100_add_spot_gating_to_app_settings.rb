# The app-level spot gate: whether spot sessions are held when Claude Code
# headroom is forecast to run short, and the two thresholds that decide it.
#
# `genesis_class_overrides` is the one-click promotion store. It follows the
# `extension_states` pattern already on this table: a JSONB map keyed by genesis
# kind, merged over the in-code defaults, so promoting a genesis needs no new
# column and no migration. Only kinds that differ from their default are stored.
class AddSpotGatingToAppSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :app_settings, :spot_gating_enabled, :boolean, default: false, null: false
    add_column :app_settings, :spot_gate_five_hour_threshold_pct, :integer, default: 80, null: false
    add_column :app_settings, :spot_gate_weekly_threshold_pct, :integer, default: 80, null: false
    add_column :app_settings, :genesis_class_overrides, :jsonb, default: {}, null: false
  end
end
