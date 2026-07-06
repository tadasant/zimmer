# frozen_string_literal: true

class CreateClaudeAccountQuotaSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :claude_account_quota_snapshots do |t|
      t.references :claude_account, null: false, foreign_key: true
      t.string :subscription_type
      t.string :rate_limit_tier
      t.float :utilization_5h
      t.float :utilization_7d
      t.string :status_5h
      t.string :status_7d
      t.datetime :reset_5h
      t.datetime :reset_7d
      t.string :overage_status
      t.string :overage_disabled_reason
      t.string :trigger
      t.timestamps
    end

    add_index :claude_account_quota_snapshots,
      [ :claude_account_id, :created_at ],
      name: "idx_quota_snapshots_account_time"
  end
end
