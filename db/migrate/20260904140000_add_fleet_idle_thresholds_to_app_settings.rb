# frozen_string_literal: true

# The three numbers `no_sessions_in_progress` fires on, moved out of constants
# and into the settings row so they can be retuned without a deploy.
#
#   fleet_idle_max_sessions              the fleet counts as idle ENOUGH while it
#                                        is RUNNING fewer than this many
#                                        sessions. 1 reproduces the boolean this
#                                        replaced ("nothing running").
#   fleet_idle_threshold_minutes         how long it must stay that way first.
#   fleet_idle_min_fire_interval_minutes the floor between two fires.
#
# The defaults preserve the shipped 5 minutes and 1 hour; the ceiling ships at 3
# rather than 1, which is the behaviour change this migration exists for. See
# FleetIdleMonitor.
class AddFleetIdleThresholdsToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :fleet_idle_max_sessions, :integer, default: 3, null: false
    add_column :app_settings, :fleet_idle_threshold_minutes, :integer, default: 5, null: false
    add_column :app_settings, :fleet_idle_min_fire_interval_minutes, :integer, default: 60, null: false
  end
end
