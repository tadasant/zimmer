class AddEnqueueMessagesToTriggers < ActiveRecord::Migration[8.0]
  def change
    add_column :triggers, :enqueue_messages, :boolean, default: false, null: false
  end
end
