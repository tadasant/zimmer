# frozen_string_literal: true

# What a refresh needs to tell a client that never received its rotated pair
# from a thief replaying a spent refresh token (OauthServer::TokensController):
#
# - `rotated_from_id` — the refresh token whose rotation issued this token, so a
#   spent refresh token presented again can find the pair it was traded for.
# - `used_at` — when a pair first reached its client: its access token's first
#   request, or its refresh token's rotation. A pair without it never arrived.
#
# Both nullable, so containers still on the old code keep inserting tokens
# without them; a token with no lineage is treated exactly as before. The index
# is built concurrently so token writes are never blocked behind it.
class AddRotationLineageToOauthServerTokens < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_column :oauth_server_tokens, :rotated_from_id, :bigint, if_not_exists: true
    add_column :oauth_server_tokens, :used_at, :datetime, if_not_exists: true
    add_index :oauth_server_tokens, :rotated_from_id, algorithm: :concurrently, if_not_exists: true
  end
end
