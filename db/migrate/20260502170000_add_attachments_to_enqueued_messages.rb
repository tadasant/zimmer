class AddAttachmentsToEnqueuedMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :enqueued_messages, :images, :jsonb, default: [], null: false
    add_column :enqueued_messages, :files, :jsonb, default: [], null: false
  end
end
