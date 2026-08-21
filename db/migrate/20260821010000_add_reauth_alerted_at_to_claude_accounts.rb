# frozen_string_literal: true

# The durable half of the needs_reauth alert throttle.
#
# Its predecessor was a Rails.cache key with a 12-hour TTL, and a cache-backed
# suppressor fails OPEN: when Redis is unreachable every account alerts on every
# transition. That mattered more than it sounds, because an account crosses INTO
# needs_reauth far more often than it breaks — `sync_from_filesystem!` writes
# `active` back onto a dead row whose credentials file still parses, and
# `ensure_active_account!` runs it before every session spawn, so the pair can
# cycle many times an hour. Under the new design each of those crossings would
# spawn an agent session.
#
# Nullable, and NULL means "never alerted", which is the right answer for every
# existing row: an account already sitting in needs_reauth alerts once on its next
# crossing rather than staying silent because of a cache key nobody can read.
class AddReauthAlertedAtToClaudeAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :claude_accounts, :reauth_alerted_at, :datetime
  end
end
