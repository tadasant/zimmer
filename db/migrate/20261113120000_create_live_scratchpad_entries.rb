# frozen_string_literal: true

# A Live Mode conversation's scratchpad: short notes the live assistant (or the
# person, on the conversation's page) keeps for itself — "session 1234 cannot
# merge yet, stop raising it" — injected into every turn's instructions
# (LiveConversations::SystemPrompt). One row per note so each can be edited or
# removed on its own and carries when it was written.
class CreateLiveScratchpadEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :live_scratchpad_entries do |t|
      t.references :live_conversation, null: false, foreign_key: { on_delete: :cascade }
      t.text :body, null: false
      t.string :written_by, null: false
      t.timestamps
    end
  end
end
