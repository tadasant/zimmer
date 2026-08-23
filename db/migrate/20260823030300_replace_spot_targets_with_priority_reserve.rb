# frozen_string_literal: true

# Re-frames the spot policy from "fill up to this percentage" to "reserve this
# much capacity for priority work".
#
# The two are complements, so the data migrates exactly: a 65% fill target and a
# 35% priority reserve describe the same line. What changes is what the number
# MEANS — the reserve is the part of the window spot work must not touch, and
# QuotaCapacityModel turns it into the dollar figure the gate and the page
# reason in. The operator still types a percentage; the dollars are derived.
#
# Reversible in both directions, since the transform is its own inverse.
class ReplaceSpotTargetsWithPriorityReserve < ActiveRecord::Migration[8.0]
  def up
    rename_column :app_settings, :spot_gate_five_hour_threshold_pct, :spot_reserve_five_hour_pct
    rename_column :app_settings, :spot_gate_weekly_threshold_pct, :spot_reserve_weekly_pct

    change_column_default :app_settings, :spot_reserve_five_hour_pct, from: 80, to: 20
    change_column_default :app_settings, :spot_reserve_weekly_pct, from: 80, to: 20

    execute(<<~SQL)
      UPDATE app_settings
      SET spot_reserve_five_hour_pct = GREATEST(0, LEAST(100, 100 - spot_reserve_five_hour_pct)),
          spot_reserve_weekly_pct = GREATEST(0, LEAST(100, 100 - spot_reserve_weekly_pct))
    SQL
  end

  def down
    execute(<<~SQL)
      UPDATE app_settings
      SET spot_reserve_five_hour_pct = GREATEST(0, LEAST(100, 100 - spot_reserve_five_hour_pct)),
          spot_reserve_weekly_pct = GREATEST(0, LEAST(100, 100 - spot_reserve_weekly_pct))
    SQL

    change_column_default :app_settings, :spot_reserve_five_hour_pct, from: 20, to: 80
    change_column_default :app_settings, :spot_reserve_weekly_pct, from: 20, to: 80

    rename_column :app_settings, :spot_reserve_five_hour_pct, :spot_gate_five_hour_threshold_pct
    rename_column :app_settings, :spot_reserve_weekly_pct, :spot_gate_weekly_threshold_pct
  end
end
