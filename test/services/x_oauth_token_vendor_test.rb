# frozen_string_literal: true

require "test_helper"

class XOauthTokenVendorTest < ActiveSupport::TestCase
  test "returns nil for a non-X variable without touching the database" do
    # If this hit the DB it would still return nil, but the prefix guard is what
    # keeps the common (per-var, per-session) path cheap.
    XOauthCredential.expects(:find_by).never
    assert_nil XOauthTokenVendor.resolve("SOME_OTHER_VAR")
  end

  test "returns nil when no credential is registered for the variable" do
    assert_nil XOauthTokenVendor.resolve("X_OAUTH_ACCESS_TOKEN")
  end

  test "vends the credential's current access token" do
    cred = XOauthCredential.create!(
      account_key: "tadasayy",
      access_token_env_var: "X_OAUTH_ACCESS_TOKEN",
      access_token: "vended-token",
      refresh_token: "r",
      expires_at: 1.hour.from_now,
      token_endpoint: XOauthCredential::DEFAULT_TOKEN_ENDPOINT
    )
    assert_equal "vended-token", XOauthTokenVendor.resolve("X_OAUTH_ACCESS_TOKEN")
    assert_equal cred.id, XOauthCredential.find_by(access_token_env_var: "X_OAUTH_ACCESS_TOKEN").id
  end

  test "returns nil (never raises) when vending blows up" do
    XOauthCredential.create!(
      account_key: "tadasayy",
      access_token_env_var: "X_OAUTH_ACCESS_TOKEN",
      access_token: "t",
      token_endpoint: XOauthCredential::DEFAULT_TOKEN_ENDPOINT
    )
    XOauthCredential.any_instance.stubs(:current_access_token).raises(StandardError, "boom")
    assert_nil XOauthTokenVendor.resolve("X_OAUTH_ACCESS_TOKEN")
  end
end
