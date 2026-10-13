# frozen_string_literal: true

# The rollout switch for widening WarmClonePool from the router root to every
# recently active agent root (WarmPoolPolicy). Off, the pool keeps one clone of
# the router root's repository for router sessions only. Ships off so the deploy
# changes nothing until an operator turns it on from Settings → Experimental.
class AddWarmClonePoolActiveRootsEnabledToAppSettings < ActiveRecord::Migration[8.1]
  def change
    add_column :app_settings, :warm_clone_pool_active_roots_enabled, :boolean, default: false, null: false
  end
end
