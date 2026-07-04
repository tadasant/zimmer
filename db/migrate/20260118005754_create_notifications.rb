class CreateNotifications < ActiveRecord::Migration[8.0]
  def change
    create_table :notifications do |t|
      t.references :session, null: false, foreign_key: true
      t.string :notification_type, null: false
      t.boolean :read, null: false, default: false
      t.boolean :stale, null: false, default: false

      t.timestamps
    end

    add_index :notifications, :stale
    add_index :notifications, :read
    add_index :notifications, [ :session_id, :stale ], name: "index_notifications_on_session_id_and_stale"
  end
end
