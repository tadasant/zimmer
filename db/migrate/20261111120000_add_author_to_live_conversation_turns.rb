# frozen_string_literal: true

# Who said a Live Mode `user` turn, stamped at the authenticated boundary that
# accepted it (the web UI behind its sign-in wall, or the iOS app on a grant
# that acts as its person). Nil for a turn nobody authenticated as a person
# typed — `action_live_conversation send_message` over an API key. What
# HumanMessageCapture.record_live_mode_message attributes from.
class AddAuthorToLiveConversationTurns < ActiveRecord::Migration[8.1]
  def change
    add_column :live_conversation_turns, :author, :string
    add_column :live_conversation_turns, :author_provenance, :jsonb, null: false, default: {}
  end
end
