class CreateAccountRotationEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :account_rotation_events do |t|
      t.bigint :rotated_from_id
      t.bigint :rotated_to_id, null: false
      t.string :reason
      t.string :source, null: false
      t.string :triggered_by

      t.timestamps
    end

    add_index :account_rotation_events, :created_at, order: :desc
    add_index :account_rotation_events, :source
    add_foreign_key :account_rotation_events, :claude_accounts, column: :rotated_from_id
    add_foreign_key :account_rotation_events, :claude_accounts, column: :rotated_to_id
  end
end
