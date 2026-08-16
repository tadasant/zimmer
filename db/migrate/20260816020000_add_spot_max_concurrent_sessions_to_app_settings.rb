# The ceiling on how many sessions run at once, which is what bounds how fast the
# fleet can burn quota. The spot gate admits in parallel up to the concurrency the
# quota can carry, and this is the operator's brake on that: 10 by default, set on
# /quotas beside the gate's two window targets.
#
# The cap counts every running session, priority included, but only holds spot
# ones — priority work is meant to crowd spot work out of the slots.
class AddSpotMaxConcurrentSessionsToAppSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :app_settings, :spot_max_concurrent_sessions, :integer, default: 10, null: false
  end
end
