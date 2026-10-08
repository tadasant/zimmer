# frozen_string_literal: true

# When the runtime refused an account for an organization-level reason —
# Claude Code's `oauth_org_not_allowed` — rather than for a dead credential.
# The account is benched in needs_reauth and this marker keeps the needs_reauth
# auto-recovery sweep from restoring it on a successful token refresh, which
# proves nothing about org access. See ClaudeAccount#disable_access!.
class AddAccessDisabledAtToClaudeAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :claude_accounts, :access_disabled_at, :datetime
  end
end
