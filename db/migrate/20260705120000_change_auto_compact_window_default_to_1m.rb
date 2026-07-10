# frozen_string_literal: true

# Raise the default Claude Code auto-compact (context) window for NEW sessions
# from 200k to 1M tokens so a large transcript loads before Claude Code
# compacts, avoiding compaction thrashing on long-running sessions. Only the
# column default changes here — existing session rows keep their stored value.
class ChangeAutoCompactWindowDefaultTo1m < ActiveRecord::Migration[8.0]
  def up
    change_column_default :sessions, :auto_compact_window, from: 200_000, to: 1_000_000
  end

  def down
    change_column_default :sessions, :auto_compact_window, from: 1_000_000, to: 200_000
  end
end
