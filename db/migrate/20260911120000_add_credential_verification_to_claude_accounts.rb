# frozen_string_literal: true

# Record what the last non-consuming probe of an account's STORED access token
# learned, so the Inference page can tell a human whether the credentials in a
# row actually work rather than only whether a JSON blob is non-empty (#239).
#
# Three nullable columns, written by the probes Zimmer already takes — no new
# network call, and nothing here ever spends a single-use refresh token (#242).
class AddCredentialVerificationToClaudeAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :claude_accounts, :credential_verified_at, :datetime
    add_column :claude_accounts, :credential_rejected_at, :datetime
    add_column :claude_accounts, :credential_rejection_reason, :string
  end
end
