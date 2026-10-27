class AddPoolOutageAlertedAtToAppSettings < ActiveRecord::Migration[8.1]
  # When PoolOutageAlert last told the operator that a session could not spawn
  # because the Claude Code pool had no account holding a usable access token.
  # Claimed by one conditional UPDATE, so a fleet of sessions refused in the same
  # minute produces one page and one push rather than one each.
  def change
    add_column :app_settings, :pool_outage_alerted_at, :datetime
  end
end
