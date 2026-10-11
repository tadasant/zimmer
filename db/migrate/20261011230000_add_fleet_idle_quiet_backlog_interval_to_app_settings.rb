# frozen_string_literal: true

# The fourth number `no_sessions_in_progress` fires on: how long the event waits
# between two fires when the work backlog has nothing new to hand out.
#
# The cooldown (`fleet_idle_min_fire_interval_minutes`) paces a fleet that stays
# quiet, but on its own it fires the backlog top-up on an empty backlog once per
# cooldown forever — each spawned session finds nothing to pull and ends. This
# column is the back-off for that case; the cooldown stays the floor for a
# backlog that does have work. 240 minutes is at most six empty top-ups a day.
# See FleetIdleMonitor, "Why an unchanged backlog backs off".
class AddFleetIdleQuietBacklogIntervalToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :fleet_idle_quiet_backlog_interval_minutes, :integer, default: 240, null: false
  end
end
