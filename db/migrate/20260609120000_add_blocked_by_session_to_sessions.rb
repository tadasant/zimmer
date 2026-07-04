class AddBlockedBySessionToSessions < ActiveRecord::Migration[8.0]
  def change
    add_reference :sessions, :blocked_by_session, null: true, index: true

    add_foreign_key :sessions, :sessions, column: :blocked_by_session_id, on_delete: :nullify
  end
end
