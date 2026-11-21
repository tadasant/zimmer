# frozen_string_literal: true

require "test_helper"
require "jwt"
require "mocha/minitest"

# The outbound OAuth flow with Zimmer's hosted client identity: opted into per
# server, used only where configured, and authenticating the code exchange and
# every refresh with a private_key_jwt assertion instead of a secret. Everything
# that does not opt in is exactly as before.
class McpOauthHostedClientIdentityTest < ActiveSupport::TestCase
  CLIENT_ID = "https://zimmer.example.com/oauth-client/metadata.json"

  def ok_token_response(body)
    response = Net::HTTPSuccess.new("1.1", "200", "OK")
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:body) { body.to_json }
    response.define_singleton_method(:[]) { |_key| "application/json" }
    response
  end

  def decode_assertion(token)
    JWT.decode(token, nil, true, algorithms: %w[ES256 RS256],
      jwks: JWT::JWK::Set.new(JSON.parse(OauthClientIdentity.jwks.to_json))).first
  end

  # --- catalog opt-in ---

  test "a catalog server that opts in presents the hosted identity when it is configured" do
    server = ServersConfig::Server.new("strad", { "type" => "streamable-http", "url" => "https://strad.example.com/mcp",
      "oauth" => { "clientIdentity" => "cimd", "clientId" => "ignored" } })

    with_oauth_client_identity do
      assert_equal({ configured_client_id: CLIENT_ID, configured_client_secret: nil,
        configured_redirect_uri: "https://zimmer.example.com/mcp_oauth/callback" }, server.oauth_client_options)
    end
  end

  test "a catalog server that opts in on a deployment without the identity keeps its static client" do
    server = ServersConfig::Server.new("strad", { "type" => "streamable-http", "url" => "https://strad.example.com/mcp",
      "oauth" => { "clientIdentity" => "cimd", "clientId" => "static-id", "clientSecret" => "s" } })

    assert_equal({ configured_client_id: "static-id", configured_client_secret: "s", configured_redirect_uri: nil },
      server.oauth_client_options)
  end

  test "a catalog server that does not opt in is unchanged even with the identity configured" do
    server = ServersConfig::Server.new("slack", { "type" => "streamable-http", "url" => "https://slack.example.com/mcp",
      "oauth" => { "clientId" => "slack-id", "redirectUri" => "http://localhost:3118/callback" } })

    with_oauth_client_identity do
      assert_equal({ configured_client_id: "slack-id", configured_client_secret: nil,
        configured_redirect_uri: "http://localhost:3118/callback" }, server.oauth_client_options)
    end
  end

  test "an opted-in server skips Dynamic Client Registration" do
    service = McpOauthService.new
    as_metadata = { "authorization_endpoint" => "https://as.example.com/authorize",
      "token_endpoint" => "https://as.example.com/token", "registration_endpoint" => "https://as.example.com/register" }

    with_oauth_client_identity do
      service.stub(:fetch_json, nil) do
        service.stub(:fetch_authorization_server_metadata, as_metadata) do
          service.stub(:perform_dcr, ->(*) { flunk "DCR must not run for the hosted identity" }) do
            metadata = service.fetch_oauth_metadata("https://as.example.com/mcp",
              configured_client_id: OauthClientIdentity.client_id)
            assert_equal CLIENT_ID, metadata.client_id
            assert_nil metadata.client_secret
          end
        end
      end
    end
  end

  # --- token exchange ---

  test "the code exchange authenticates with a signed assertion and sends no secret" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    captured = nil

    with_oauth_client_identity do
      flow.update_columns(client_id: CLIENT_ID, client_secret: "must-not-be-sent")
      service = McpOauthService.new
      service.stub(:post_form, ->(_uri, params) { captured = params; ok_token_response(access_token: "tok") }) do
        assert_equal "tok", service.exchange_code_for_tokens(flow, "code")["access_token"]
      end

      assert_nil captured[:client_secret]
      assert_equal CLIENT_ID, captured[:client_id]
      assert_equal OauthClientIdentity::ASSERTION_TYPE, captured[:client_assertion_type]
      claims = decode_assertion(captured[:client_assertion])
      assert_equal flow.token_endpoint, claims["aud"]
      assert_equal CLIENT_ID, claims["sub"]
    end
  end

  test "the code exchange for any other client is unchanged" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.update_columns(client_secret: "shh")
    captured = nil

    with_oauth_client_identity do
      service = McpOauthService.new
      service.stub(:post_form, ->(_uri, params) { captured = params; ok_token_response(access_token: "tok") }) do
        service.exchange_code_for_tokens(flow, "code")
      end
    end

    assert_equal "shh", captured[:client_secret]
    assert_nil captured[:client_assertion]
  end

  test "the assertion audience never carries userinfo from the token endpoint" do
    with_oauth_client_identity do
      params = McpOauthService.new.client_assertion_params("https://id:secret@as.example.com/token")
      assert_equal "https://as.example.com/token", decode_assertion(params[:client_assertion])["aud"]
    end
  end

  # --- refresh ---

  test "a hosted-identity credential refreshes with a fresh assertion and no secret" do
    credential = mcp_oauth_credentials(:notion)
    with_oauth_client_identity do
      credential.update!(client_id: CLIENT_ID, client_secret: nil, refresh_token: "rt-1")
      captured = stub_token_post(ok_token_response(access_token: "new-at", refresh_token: "rt-2", expires_in: 3600)) do
        assert credential.refresh!
      end

      assert_equal "rt-1", captured[:refresh_token]
      assert_nil captured[:client_secret]
      assert_equal credential.token_endpoint, decode_assertion(captured[:client_assertion])["aud"]
      assert_equal "new-at", credential.reload.access_token
    end
  end

  test "with the identity switched off, a hosted-identity credential is not refreshable and keeps its refresh token" do
    credential = mcp_oauth_credentials(:notion)
    credential.update!(client_id: CLIENT_ID, refresh_token: "rt-keep")

    assert_not credential.can_refresh?
    stub_token_post(->(*) { flunk "must not post" }) do
      assert_raises(OauthClientIdentity::Unavailable) { credential.refresh! }
    end
    assert_equal "rt-keep", credential.reload.refresh_token

    with_oauth_client_identity { assert credential.can_refresh? }
  end

  # --- pre-registered config ---

  test "a pre-registered entry may omit client_id only where the hosted identity is configured" do
    config = { strad: { client_identity: "cimd", authorization_endpoint: "https://as.example.com/a",
      token_endpoint: "https://as.example.com/t" } }

    PreregisteredOauthConfig.stub(:oauth_clients_config, config) do
      assert_nil PreregisteredOauthConfig.find_for_server("strad")
      with_oauth_client_identity do
        client = PreregisteredOauthConfig.find_for_server("strad")
        assert_equal "cimd", client.client_identity
      end
    end
  end
end
