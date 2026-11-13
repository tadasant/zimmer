# frozen_string_literal: true

# When an MCP client (an agent with the opt-in `live_conversations` tools) last
# wrote this conversation's scratchpad. Every note is in every turn's
# instructions, so such a write can steer the live model the way an agent-typed
# line can, and it is kept after the note itself is removed: what the note said
# may still be in the thread. LiveConversation#agent_written? reads it, so
# HumanMessageCapture records nothing for the conversation once it is set.
class AddAgentWroteScratchpadAtToLiveConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :live_conversations, :agent_wrote_scratchpad_at, :datetime
  end
end
