# frozen_string_literal: true

# Remembers whether the account pool could serve a request the last time anything
# looked.
#
# The `quota_available` trigger event is an EDGE — quota-full to quota-available —
# and an edge needs a previous level to be an edge at all. Without somewhere to
# keep it, the periodic check could only report the current level, which is true
# every fifteen minutes for as long as the pool is healthy and would spawn a fleet
# session each time.
#
# NULL is "nobody has looked yet". The first observation records the level and
# fires nothing, so a deploy landing while the pool happens to be healthy does not
# read as a recovery.
class AddQuotaPoolAvailableToAppSettings < ActiveRecord::Migration[8.0]
  def change
    add_column :app_settings, :quota_pool_available, :boolean
    add_column :app_settings, :quota_pool_available_changed_at, :datetime
  end
end
