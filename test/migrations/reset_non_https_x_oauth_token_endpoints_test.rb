# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260904090000_reset_non_https_x_oauth_token_endpoints")

# XOauthCredential's https-only validation would make a pre-existing bad row
# unsavable, and #refresh! saves — so this migration is the only thing standing
# between a legacy row and a refresh that leaks the client secret and then loses
# the rotated token on the way to persisting it. Its predicate is worth pinning:
# it has to reject exactly what the validation rejects, and a near-miss like
# `LIKE 'https://%'` would leave behind the values that look right and aren't.
class ResetNonHttpsXOauthTokenEndpointsTest < ActiveSupport::TestCase
  DEFAULT = XOauthCredential::DEFAULT_TOKEN_ENDPOINT

  setup { @migration = ResetNonHttpsXOauthTokenEndpoints.new }

  # suppress_messages rather than `verbose = false`: verbose is a cattr, so the
  # writer would silence migration logging for the rest of the worker process.
  def migrate
    ActiveRecord::Migration.suppress_messages { @migration.up }
  end

  # The rows this exists for cannot be created through the model, which is the
  # point — they predate the validation.
  def credential_holding(endpoint, account_key: "tadasayy", env_var: "X_OAUTH_ACCESS_TOKEN")
    XOauthCredential.create!(
      account_key: account_key, access_token_env_var: env_var, token_endpoint: DEFAULT
    ).tap { |cred| cred.update_column(:token_endpoint, endpoint) }
  end

  test "resets every endpoint the validation would refuse, and leaves the rest alone" do
    refused = {
      "plain http" => "http://api.x.com/2/oauth2/token",
      "http loopback" => "http://127.0.0.1:8080/2/oauth2/token",
      "no scheme" => "api.x.com/2/oauth2/token",
      # The four below are why the predicate is the validation's own rather than
      # a LIKE: each starts with the right characters and is still unusable.
      "hostless https" => "https://",
      "single-slash https" => "https:/api.x.com/2/oauth2/token",
      "trailing space" => "https://api.x.com/2/oauth2/token ",
      "embedded credentials" => "https://user:pass@api.x.com/2/oauth2/token"
    }.each_with_index.to_h { |(label, endpoint), i|
      [ label, credential_holding(endpoint, account_key: "refused-#{i}", env_var: "X_OAUTH_REFUSED_#{i}") ]
    }

    kept = {
      "the default" => credential_holding(DEFAULT, account_key: "kept-0", env_var: "X_OAUTH_KEPT_0"),
      "an uppercase scheme" => credential_holding("HTTPS://api.x.com/2/oauth2/token", account_key: "kept-1", env_var: "X_OAUTH_KEPT_1"),
      "another https host" => credential_holding("https://proxy.internal/2/oauth2/token", account_key: "kept-2", env_var: "X_OAUTH_KEPT_2")
    }
    kept_before = kept.transform_values { |cred| cred.token_endpoint }

    migrate

    refused.each do |label, cred|
      assert_equal DEFAULT, cred.reload.token_endpoint, "#{label} was left unrepaired"
      assert_predicate cred, :valid?, "#{label} is still unsavable after the migration"
    end

    kept.each do |label, cred|
      assert_equal kept_before[label], cred.reload.token_endpoint, "#{label} was rewritten and should not have been"
    end
  end

  test "is a no-op on a second run" do
    cred = credential_holding("http://api.x.com/2/oauth2/token")
    migrate
    repaired_at = cred.reload.updated_at

    travel 1.minute do
      migrate
      assert_equal repaired_at.to_i, cred.reload.updated_at.to_i, "the second run rewrote a row it had already fixed"
    end
  end

  test "is a no-op when there is nothing to repair" do
    XOauthCredential.delete_all
    assert_nothing_raised { migrate }
  end

  test "down refuses rather than pretending the old values can come back" do
    assert_raises(ActiveRecord::IrreversibleMigration) do
      ActiveRecord::Migration.suppress_messages { @migration.down }
    end
  end
end
