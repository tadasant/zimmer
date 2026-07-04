# frozen_string_literal: true

# Adds a runtime discriminator to the account pool so AO can hold accounts for
# more than one agent runtime (Claude Code today; Codex via #3780). Existing rows
# are Claude Code accounts, so the column defaults to "claude_code" and the
# default backfills every existing row.
class AddRuntimeToClaudeAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :claude_accounts, :runtime, :string, null: false, default: "claude_code"
    add_index :claude_accounts, :runtime
  end
end
