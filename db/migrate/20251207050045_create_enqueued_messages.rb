class CreateEnqueuedMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :enqueued_messages do |t|
      t.bigint :session_id, null: false
      t.text :content, null: false
      t.text :stop_condition
      t.integer :position, null: false
      t.string :status, default: "pending", null: false

      t.timestamps
    end

    add_foreign_key :enqueued_messages, :sessions
    add_index :enqueued_messages, [ :session_id, :position ]
    add_index :enqueued_messages, [ :session_id, :status ]
  end
end
