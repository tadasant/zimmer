class AddRefreshTokenUnsupportedToMcpOauthCredentials < ActiveRecord::Migration[8.0]
  # Records the one fact the token response tells us once and never repeats: the
  # server issued this credential without a refresh token, so it cannot be
  # renewed and will need re-authorizing every time the access token lapses.
  # Without it that permanent property resurfaces later as a mystery re-auth.
  #
  # Defaults to false, which is the truth for every existing row that has a
  # refresh token and the safe (quieter) assumption for any that does not — the
  # surfaced predicate also requires refresh_token to be blank, so a backfilled
  # false never claims more than it knows.
  def change
    add_column :mcp_oauth_credentials, :refresh_token_unsupported, :boolean, default: false, null: false
  end
end
