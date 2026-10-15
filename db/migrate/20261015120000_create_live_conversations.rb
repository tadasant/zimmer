# frozen_string_literal: true

# Live Mode and Live Voice: one continuous conversation with a fast OpenAI model,
# configured from an agent root's AGENTS.md, that hands real work to Zimmer's own
# MCP surface. Its own table rather than a `sessions` row: a Session is an agent
# process (spawn, heartbeat, stalled-start sweep, clone reaper), and a live
# conversation has no process for any of that machinery to manage.
class CreateLiveConversations < ActiveRecord::Migration[8.1]
  def change
    create_table :live_conversations do |t|
      t.string :mode, null: false
      t.string :status, null: false, default: "preparing"
      t.string :agent_root, null: false
      t.string :model, null: false
      t.string :title
      t.text :instructions
      t.string :instructions_source
      t.jsonb :mcp_servers, null: false, default: []
      t.jsonb :mcp_tool_cache, null: false, default: {}
      t.text :error_message
      t.datetime :responding_since
      t.datetime :last_activity_at
      t.datetime :ended_at
      t.timestamps
    end
    add_index :live_conversations, [ :mode, :status ]
    # "It's a single session": at most one open conversation per mode. Starting a
    # new one ends the old one first (LiveConversations::Start); this makes a race
    # between two starts fail loudly instead of leaving two "current" threads.
    add_index :live_conversations, :mode, unique: true,
      where: "status IN ('preparing', 'active')", name: "index_live_conversations_one_open_per_mode"
    add_index :live_conversations, :updated_at

    create_table :live_conversation_turns do |t|
      t.references :live_conversation, null: false, foreign_key: { on_delete: :cascade }
      t.string :role, null: false
      t.string :source
      t.text :content
      t.string :tool_name
      t.string :call_id
      t.jsonb :tool_arguments
      t.text :tool_output
      t.boolean :tool_error, null: false, default: false
      t.timestamps
    end
    add_index :live_conversation_turns, [ :live_conversation_id, :id ]
  end
end
