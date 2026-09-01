# frozen_string_literal: true

# Storage for the `no_sessions_in_progress` system event's edge.
#
# The event fires when the fleet has had nothing in `running` for five continuous
# minutes, and "the fleet is idle" is a LEVEL — true on every check for as long as
# nothing is running. Firing on the level would spawn a session every sweep while
# the deployment sits still, so FleetIdleMonitor turns it into an edge with these
# two columns:
#
#   fleet_idle_since          when the fleet was first observed with nothing
#                             running. NULL means something was running at the
#                             last observation. This is the clock the five-minute
#                             threshold is measured against.
#   fleet_idle_event_fired_at when the event was last fired for the CURRENT idle
#                             stretch. NULL means the latch is armed. Both columns
#                             are cleared the moment a session runs again, which is
#                             what re-arms the event.
class AddFleetIdleTrackingToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :fleet_idle_since, :datetime
    add_column :app_settings, :fleet_idle_event_fired_at, :datetime
  end
end
