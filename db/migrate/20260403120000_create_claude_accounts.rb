# frozen_string_literal: true

class CreateClaudeAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :claude_accounts do |t|
      t.string :email, null: false
      t.integer :status, default: 0, null: false
      t.jsonb :oauth_config, default: {}
      t.boolean :is_current, default: false, null: false
      t.integer :priority, default: 0, null: false
      t.integer :quota_hit_count, default: 0, null: false
      t.datetime :last_rotated_to_at
      t.timestamps
    end

    add_index :claude_accounts, :email, unique: true
    add_index :claude_accounts, :is_current
    add_index :claude_accounts, [ :status, :priority ]
  end
end
