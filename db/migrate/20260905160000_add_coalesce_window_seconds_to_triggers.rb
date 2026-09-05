# frozen_string_literal: true

# `coalesce_window_seconds` — how close together two Slack messages have to land
# before they count as one event rather than two.
#
# NULL is not "off": it means "use Trigger::DEFAULT_COALESCE_WINDOW_SECONDS",
# which is 60 seconds. That is deliberate, and it is the difference between this
# column and `skip_if_pending_session`. That setting can silently stop a trigger
# spawning anything, so it had to be opt-in; this one never drops a message —
# every message in a coalesced group is carried in the surviving session's
# prompt — so shipping it off by default would leave the defect it fixes in place
# on every trigger until someone edited a row, and there is no prod shell to edit
# rows from.
#
# 0 turns it off explicitly: every message spawns its own session, which is the
# behaviour before this column existed.
class AddCoalesceWindowSecondsToTriggers < ActiveRecord::Migration[8.0]
  def change
    add_column :triggers, :coalesce_window_seconds, :integer, null: true
  end
end
