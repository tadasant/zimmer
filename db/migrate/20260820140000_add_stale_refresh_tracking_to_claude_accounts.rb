# frozen_string_literal: true

# An `invalid_grant` on a refresh token has two meanings and the response body is
# the only thing that separates them: "this credential is finished" and "the value
# you presented is no longer the current one". The second is survivable, so Zimmer
# counts those failures instead of condemning on the first one. These columns hold
# that count. See ClaudeAccount#record_stale_refresh_failure!.
class AddStaleRefreshTrackingToClaudeAccounts < ActiveRecord::Migration[8.0]
  def change
    add_column :claude_accounts, :stale_refresh_failures, :integer, default: 0, null: false
    add_column :claude_accounts, :last_stale_refresh_failure_at, :datetime
  end
end
