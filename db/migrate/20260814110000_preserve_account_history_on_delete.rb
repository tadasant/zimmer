# Keeps an account's operational history readable after the account row is gone.
#
# Deleting a ClaudeAccount used to cascade into its quota snapshots, its login
# attempts, and every rotation event that targeted it — so the standard operator
# response to a misbehaving account ("delete it and re-authenticate", two
# adjacent buttons on every /quotas card) destroyed exactly the evidence needed
# to tell whether the account had ever been healthy.
#
# Two changes make preservation possible:
#
#   1. The owning foreign keys become nullable, so the child rows can outlive
#      the parent instead of being destroyed with it.
#   2. Each child row carries the account's identity — email, and the runtime
#      that scopes it — denormalized at write time. A nulled FK alone leaves a
#      snapshot attributable to nobody, which preserves bytes and not evidence.
#
# `account_rotation_events.runtime` also carries the /quotas rotation table,
# which filtered by joining to the target account's runtime. An event whose
# target has been deleted has no account to join to, and would vanish from the
# page — the exact history loss this migration exists to stop.
#
# All new columns are nullable and backfilled: rows written before this
# migration have their identity recovered from the accounts that still exist,
# and rows whose account was already deleted stay as they were.
class PreserveAccountHistoryOnDelete < ActiveRecord::Migration[8.0]
  def up
    change_column_null :claude_account_quota_snapshots, :claude_account_id, true
    add_column :claude_account_quota_snapshots, :account_email, :string
    add_column :claude_account_quota_snapshots, :account_runtime, :string

    change_column_null :runtime_login_attempts, :claude_account_id, true
    add_column :runtime_login_attempts, :account_email, :string

    change_column_null :account_rotation_events, :rotated_to_id, true
    add_column :account_rotation_events, :rotated_from_email, :string
    add_column :account_rotation_events, :rotated_to_email, :string
    add_column :account_rotation_events, :runtime, :string
    add_index :account_rotation_events, [ :runtime, :created_at ]

    execute <<~SQL.squish
      UPDATE claude_account_quota_snapshots s
         SET account_email = a.email, account_runtime = a.runtime
        FROM claude_accounts a
       WHERE a.id = s.claude_account_id
    SQL

    execute <<~SQL.squish
      UPDATE runtime_login_attempts l
         SET account_email = a.email
        FROM claude_accounts a
       WHERE a.id = l.claude_account_id
    SQL

    execute <<~SQL.squish
      UPDATE account_rotation_events e
         SET rotated_from_email = a.email
        FROM claude_accounts a
       WHERE a.id = e.rotated_from_id
    SQL

    execute <<~SQL.squish
      UPDATE account_rotation_events e
         SET rotated_to_email = a.email, runtime = a.runtime
        FROM claude_accounts a
       WHERE a.id = e.rotated_to_id
    SQL
  end

  def down
    remove_index :account_rotation_events, [ :runtime, :created_at ]
    remove_column :account_rotation_events, :runtime
    remove_column :account_rotation_events, :rotated_to_email
    remove_column :account_rotation_events, :rotated_from_email
    remove_column :runtime_login_attempts, :account_email
    remove_column :claude_account_quota_snapshots, :account_runtime
    remove_column :claude_account_quota_snapshots, :account_email

    # These can only go back to NOT NULL if nothing was orphaned in the meantime.
    execute "DELETE FROM account_rotation_events WHERE rotated_to_id IS NULL"
    execute "DELETE FROM runtime_login_attempts WHERE claude_account_id IS NULL"
    execute "DELETE FROM claude_account_quota_snapshots WHERE claude_account_id IS NULL"

    change_column_null :account_rotation_events, :rotated_to_id, false
    change_column_null :runtime_login_attempts, :claude_account_id, false
    change_column_null :claude_account_quota_snapshots, :claude_account_id, false
  end
end
