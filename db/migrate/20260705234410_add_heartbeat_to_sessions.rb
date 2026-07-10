# frozen_string_literal: true

# Per-session heartbeat: an opt-in, user-toggleable nudge that resumes a
# needs_input session on a fixed cadence so it keeps working toward its goal.
#
# - heartbeat_enabled: off by default on every session.
# - heartbeat_interval_seconds: how often the heart "beats" (default 60s).
# - heartbeat_last_beat_at: when the sweep last beat this session; used to
#   decide whether a session is due for its next beat. Null until the first beat.
class AddHeartbeatToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :heartbeat_enabled, :boolean, default: false, null: false
    add_column :sessions, :heartbeat_interval_seconds, :integer, default: 60, null: false
    add_column :sessions, :heartbeat_last_beat_at, :datetime

    # Partial index so the recurring sweep can cheaply find the (usually small)
    # set of sessions with an active heartbeat.
    add_index :sessions, :heartbeat_enabled, where: "heartbeat_enabled", name: "index_sessions_on_heartbeat_enabled"
  end
end
