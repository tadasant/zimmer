# frozen_string_literal: true

# Burst control: a per-trigger cap on how many NEW sessions a trigger may spawn
# per minute, plus the bookkeeping that makes "one burst → exactly one notice"
# possible.
#
# max_sessions_per_minute is nullable on purpose — NULL means unbounded, which is
# exactly how every existing trigger behaves today.
class AddBurstControlToTriggers < ActiveRecord::Migration[8.1]
  def change
    add_column :triggers, :max_sessions_per_minute, :integer
    add_column :triggers, :burst_window_started_at, :datetime
    add_column :triggers, :burst_window_count, :integer, default: 0, null: false
    add_column :triggers, :burst_window_session_ids, :jsonb, default: [], null: false
    add_column :triggers, :burst_active_until, :datetime
  end
end
