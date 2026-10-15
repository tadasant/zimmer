# frozen_string_literal: true

# What a refresh needs to tell a client that never received its rotated pair
# from a thief replaying a spent refresh token (OauthServer::TokensController):
#
# - `rotated_from_id` — the refresh token whose rotation issued this token, so a
#   spent refresh token presented again can find the pair it was traded for.
# - `used_at` — when an access token was first presented. A rotated pair neither
#   half of which was ever used never reached its client.
class AddRotationLineageToOauthServerTokens < ActiveRecord::Migration[8.1]
  def change
    add_column :oauth_server_tokens, :rotated_from_id, :bigint
    add_column :oauth_server_tokens, :used_at, :datetime
    add_index :oauth_server_tokens, :rotated_from_id
  end
end
