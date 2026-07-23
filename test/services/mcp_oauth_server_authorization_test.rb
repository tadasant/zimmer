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

  test "still_needing_authorization drops entries that already have an active credential" do
    entries = [
      { "server_name" => "authorized-server", "credential_key" => KEY },
      { "server_name" => "needs-auth", "credential_key" => "needs-auth|1111111111111111" }
    ]

    remaining = McpOauthServerAuthorization.still_needing_authorization(entries)

    assert_equal [ "needs-auth" ], remaining.map { |e| e["server_name"] }
  end
end
