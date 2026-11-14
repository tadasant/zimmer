# frozen_string_literal: true

# The engine the conversation's latest voice call ran on, why it is not the one
# the settings asked for when it fell back (a missing key, a client that cannot
# run it, a spend cap), and its mode — the engine with the models it ran on —
# which the call's usage is reported under. Written when the call starts.
class AddVoiceEngineToLiveConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :live_conversations, :voice_engine, :string
    add_column :live_conversations, :voice_engine_fallback, :string
    add_column :live_conversations, :voice_mode, :string
  end
end
