# frozen_string_literal: true

# When and why an OAuth grant's scope last changed — the audit trail for its
# privilege level (OauthServer::ACT_AS_HUMAN_SCOPE). The scope itself already has
# a column; these say whether the level on it was chosen at consent, changed on
# the connections page, or set by the one-time backfill.
class AddScopeChangeToOauthServerGrants < ActiveRecord::Migration[8.1]
  def change
    add_column :oauth_server_grants, :scope_changed_at, :datetime
    add_column :oauth_server_grants, :scope_change_reason, :string
  end
end
