# frozen_string_literal: true

# ClaudeAccount is the shared pool for every runtime AO authenticates (claude_code
# and codex today), with the `runtime` column discriminating rows. Email
# uniqueness must therefore be per-runtime, not global, so one person can hold a
# separate account on each runtime (e.g. a codex AND a claude_code account for the
# same email). Replace the global unique index on email with a composite unique
# index on [email, runtime].
class ScopeClaudeAccountsEmailUniquenessToRuntime < ActiveRecord::Migration[8.0]
  def change
    # Describe the removed index fully (column + unique) so `change` stays
    # reversible — `db:rollback` can reconstruct the original single-column
    # unique index instead of raising IrreversibleMigration.
    remove_index :claude_accounts, :email,
      unique: true, name: "index_claude_accounts_on_email"
    add_index :claude_accounts, [ :email, :runtime ],
      unique: true, name: "index_claude_accounts_on_email_and_runtime"
  end
end
