# frozen_string_literal: true

# Live Voice folds into Live Mode: one conversation that can switch between
# typing and talking, on the `live-mode` agent root. `mode` stays, and now says
# which of the two the conversation is in right now; `mode_instructions` holds
# the root's per-mode style text, read once when the conversation is prepared.
#
# The one-open-conversation rule was per mode and is now global. Conversations
# still open on the retired `live-voice` root are ended first — ended, not
# deleted, so they stay readable — and then at most one open conversation is
# left, which the new index requires.
class UnifyLiveModes < ActiveRecord::Migration[8.1]
  # The OR spelling, not IN: Postgres dumps an IN list differently after a
  # schema load than after a migration, and schema_verify compares the two.
  OPEN = "status = 'preparing' OR status = 'active'"

  def up
    add_column :live_conversations, :mode_instructions, :jsonb, null: false, default: {}

    execute <<~SQL.squish
      UPDATE live_conversations
         SET status = 'ended', ended_at = NOW(), responding_since = NULL, updated_at = NOW()
       WHERE (#{OPEN})
         AND (agent_root = 'live-voice'
              OR id <> (SELECT id FROM live_conversations
                         WHERE (#{OPEN}) AND agent_root <> 'live-voice' ORDER BY id DESC LIMIT 1))
    SQL

    remove_index :live_conversations, name: "index_live_conversations_one_open_per_mode"
    add_index :live_conversations, "(true)", unique: true, where: OPEN, name: "index_live_conversations_one_open"
  end

  def down
    remove_index :live_conversations, name: "index_live_conversations_one_open"
    add_index :live_conversations, :mode, unique: true, where: OPEN, name: "index_live_conversations_one_open_per_mode"
    remove_column :live_conversations, :mode_instructions
  end
end
