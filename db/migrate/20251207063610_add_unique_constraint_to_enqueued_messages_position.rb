class AddUniqueConstraintToEnqueuedMessagesPosition < ActiveRecord::Migration[8.0]
  def change
    # Remove the existing non-unique index
    remove_index :enqueued_messages, [ :session_id, :position ]

    # Add unique constraint on session_id + position to prevent duplicate positions
    add_index :enqueued_messages, [ :session_id, :position ], unique: true
  end
end
