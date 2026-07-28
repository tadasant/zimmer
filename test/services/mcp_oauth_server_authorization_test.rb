# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class McpOauthServerAuthorizationTest < ActiveSupport::TestCase
  KEY = "authorized-server|deadbeefcafef00d"

  setup do
    @active = McpOauthCredential.create!(
      server_name: "authorized-server",
      server_url: "https://authorized.example.com/mcp",
      credential_key: KEY,
      client_id: "c",
      access_token: "tok",
      refresh_token: "rt",
      token_endpoint: "https://authorized.example.com/oauth/token",
      expires_at: 1.hour.from_now
    )
  end

  test "authorized? is true when an active credential exists for the persisted key" do
    assert McpOauthServerAuthorization.authorized?(
      "server_name" => "authorized-server", "credential_key" => KEY
    )
  end

  test "authorized? is false when the credential is expired" do
    @active.update!(expires_at: 1.hour.ago)
    assert_not McpOauthServerAuthorization.authorized?(
      "server_name" => "authorized-server", "credential_key" => KEY
    )
  end

  test "authorized? is false when no credential exists for the key" do
    assert_not McpOauthServerAuthorization.authorized?(
      "server_name" => "unknown", "credential_key" => "unknown|0000000000000000"
    )
  end

  test "authorized? accepts symbol-keyed entries" do
    assert McpOauthServerAuthorization.authorized?(
      server_name: "authorized-server", credential_key: KEY
    )
  end

  test "credential_key_for prefers the persisted key" do
    assert_equal KEY, McpOauthServerAuthorization.credential_key_for(
      "server_name" => "authorized-server", "credential_key" => KEY
    )
  end

  test "credential_key_for derives the key from the catalog config when none is persisted" do
    config = { type: "streamable-http", url: "https://authorized.example.com/mcp" }
    ServersConfig.stubs(:credential_config).with("authorized-server").returns(config)
    expected = McpOauthCredential.compute_credential_key("authorized-server", config)

    assert_equal expected, McpOauthServerAuthorization.credential_key_for(
      "server_name" => "authorized-server"
    )
  end

  test "credential_key_for falls back to the recorded server_url on a catalog miss" do
    ServersConfig.stubs(:credential_config).with("off-catalog").returns(nil)
    expected = McpOauthCredential.compute_credential_key(
      "off-catalog", { type: "http", url: "https://off.example.com/mcp" }
    )

    assert_equal expected, McpOauthServerAuthorization.credential_key_for(
      "server_name" => "off-catalog", "server_url" => "https://off.example.com/mcp"
    )
  end

  test "credential_key_for returns nil when no key can be derived" do
    ServersConfig.stubs(:credential_config).with("no-url").returns(nil)
    assert_nil McpOauthServerAuthorization.credential_key_for("server_name" => "no-url")
    assert_nil McpOauthServerAuthorization.credential_key_for({})
  end

  test "refresh_token_rejected? matches the grant errors a dead refresh token reports" do
    assert McpOauthServerAuthorization.refresh_token_rejected?(
      "Token refresh failed with invalid_grant: Invalid refresh token\n" \
      "HTTP Connection failed after 759ms: Unauthorized"
    )
    assert McpOauthServerAuthorization.refresh_token_rejected?("Token refresh failed with invalid_client")
    assert McpOauthServerAuthorization.refresh_token_rejected?("token refresh failed: unauthorized_client")
  end

  test "refresh_token_rejected? ignores transport and non-grant auth failures" do
    assert_not McpOauthServerAuthorization.refresh_token_rejected?("HTTP Connection failed: Unauthorized")
    assert_not McpOauthServerAuthorization.refresh_token_rejected?("Connection timed out after 30000ms")
    assert_not McpOauthServerAuthorization.refresh_token_rejected?(nil)
  end

  # A server that brokers a downstream OAuth of its own can report the DOWNSTREAM
  # provider's grant error while Zimmer's credential for the server is healthy.
  # Retiring it there would force a re-auth that cannot fix anything, so the
  # pattern keys on the refresh-failure phrasing rather than a bare error code.
  test "refresh_token_rejected? ignores a grant error a server reports about its own downstream provider" do
    assert_not McpOauthServerAuthorization.refresh_token_rejected?(
      "Tool call failed: the connected Google account returned invalid_grant; reconnect it in the app"
    )
  end

  test "invalidate! force-expires the credential so authorized? flips to false" do
    server_info = { "server_name" => "authorized-server", "credential_key" => KEY }
    assert McpOauthServerAuthorization.authorized?(server_info)

    assert McpOauthServerAuthorization.invalidate!(server_info)

    @active.reload
    assert_nil @active.refresh_token
    assert @active.expires_at <= Time.current
    assert_not McpOauthServerAuthorization.authorized?(server_info)
  end

  # An already-lapsed row is if anything more urgent than an active one: it keeps
  # can_refresh? true, so RefreshMcpOauthTokensJob would go on presenting a
  # refresh token the provider has revoked.
  test "invalidate! drops the revoked refresh token from an already-expired credential" do
    @active.update!(expires_at: 1.hour.ago)
    expired_at = @active.expires_at

    assert McpOauthServerAuthorization.invalidate!(
      "server_name" => "authorized-server", "credential_key" => KEY
    )

    @active.reload
    assert_nil @active.refresh_token
    assert_not @active.can_refresh?
    assert_equal expired_at.to_i, @active.expires_at.to_i, "must not disturb an expiry that already lapsed"
  end

  test "invalidate! is a no-op when there is no credential to invalidate" do
    assert_not McpOauthServerAuthorization.invalidate!(
      "server_name" => "unknown", "credential_key" => "unknown|0000000000000000"
    )

    ServersConfig.stubs(:credential_config).with("no-url").returns(nil)
    assert_not McpOauthServerAuthorization.invalidate!("server_name" => "no-url")
  end

  test "still_needing_authorization drops entries that already have an active credential" do
    entries = [
      { "server_name" => "authorized-server", "credential_key" => KEY },
      { "server_name" => "needs-auth", "credential_key" => "needs-auth|1111111111111111" }
    ]

    remaining = McpOauthServerAuthorization.still_needing_authorization(entries)

    assert_equal [ "needs-auth" ], remaining.map { |e| e["server_name"] }
  end
end
