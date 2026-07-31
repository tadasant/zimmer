# frozen_string_literal: true

# RuntimeLoginJob stamps this every few seconds while it holds the login CLI
# open, so a login stranded by a worker that died without running Ruby (deploy
# SIGKILL, crash, container replacement) is detectable as a stale heartbeat
# instead of only as an elapsed 14-minute verification window.
class AddHeartbeatAtToRuntimeLoginAttempts < ActiveRecord::Migration[8.0]
  def change
    add_column :runtime_login_attempts, :heartbeat_at, :datetime
  end
end
