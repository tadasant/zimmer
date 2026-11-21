# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# The Token broker page and the one-time human consent that creates a parent
# grant, finished by the shared /mcp_oauth/callback.
class TokenBrokerControllerTest < ActionDispatch::IntegrationTest
  include TokenBrokerTestHelpers

  setup do
    @strad = FakeStrad.new
    client = @strad.client
    TokenBroker::Client.stubs(:new).returns(client)
    stub_mcp_catalog("image-diff" => brokered_strad_entry("image-diff"), "granola" => static_strad_entry("granola"))
    # The hosted identity's redirect is Zimmer's own callback only when its base
    # URL is this host; otherwise the flow falls back to paste-back.
    @saved_app_host = ENV["APP_HOST"]
    ENV["APP_HOST"] = "zimmer.example.com"
  end

  teardown do
    @saved_app_host.nil? ? ENV.delete("APP_HOST") : ENV["APP_HOST"] = @saved_app_host
  end

  test "the page lists each authorization server an entry opts into, and renders no token" do
    with_oauth_client_identity do
      grant = @strad.create_grant!
      get token_broker_path

      assert_response :success
      assert_select "[data-authorization-server=?]", FakeStrad::ORIGIN
      assert_includes response.body, "image-diff"
      assert_includes response.body, "Connected"
      refute_includes response.body, grant.access_token
      refute_includes response.body, grant.refresh_token
    end
  end

  test "with nothing opted in the page says so" do
    stub_mcp_catalog("granola" => static_strad_entry("granola"))
    get token_broker_path

    assert_response :success
    assert_includes response.body, "No catalog entry opts into brokered auth"
  end

  test "connect sends the human to strad's consent as Zimmer's hosted client" do
    with_oauth_client_identity do
      post connect_token_broker_path, params: { authorization_server: FakeStrad::ORIGIN }

      assert_response :redirect
      location = URI(response.location)
      query = Rack::Utils.parse_query(location.query)
      assert_equal "#{FakeStrad::ORIGIN}/oauth/authorize", "#{location.scheme}://#{location.host}#{location.path}"
      assert_equal OauthClientIdentity.client_id, query["client_id"]
      assert_equal OauthClientIdentity.redirect_uri, query["redirect_uri"]
      assert_equal "mcp", query["scope"]
      assert_equal FakeStrad::RESOURCE, query["resource"]
      assert_equal "S256", query["code_challenge_method"]
      flow = McpOauthPendingFlow.where.not(broker_authorization_server: nil).sole
      assert_equal FakeStrad::ORIGIN, flow.broker_authorization_server
      assert flow.broker_flow?
    end
  end

  test "connect refuses an origin no entry opts into" do
    with_oauth_client_identity do
      post connect_token_broker_path, params: { authorization_server: "https://evil.example.com" }

      assert_redirected_to token_broker_path
      assert_match(/not an authorization server/, flash[:error])
      assert_empty @strad.requests
      assert_equal 0, McpOauthPendingFlow.where.not(broker_authorization_server: nil).count
    end
  end

  test "connect refuses before consent when strad does not offer token exchange yet" do
    @strad.token_exchange_advertised = false
    with_oauth_client_identity do
      post connect_token_broker_path, params: { authorization_server: FakeStrad::ORIGIN }

      assert_redirected_to token_broker_path
      assert_match(/does not offer token exchange/, flash[:error])
      assert_equal 0, McpOauthPendingFlow.where.not(broker_authorization_server: nil).count
    end
  end

  test "connect refuses without the client identity" do
    post connect_token_broker_path, params: { authorization_server: FakeStrad::ORIGIN }

    assert_redirected_to token_broker_path
    assert_match(/client identity is not configured/, flash[:error])
  end

  test "the callback stores the parent grant, not a per-entry credential" do
    with_oauth_client_identity do
      post connect_token_broker_path, params: { authorization_server: FakeStrad::ORIGIN }
      flow = McpOauthPendingFlow.where.not(broker_authorization_server: nil).sole
      McpOauthService.any_instance.expects(:exchange_code_for_tokens).with { |f, code| f.id == flow.id && code == "the-code" }
        .returns("access_token" => "strad_oat_parentnew", "refresh_token" => "strad_ort_parentnew", "expires_in" => 3600, "scope" => "mcp")

      credentials_before = McpOauthCredential.count
      get mcp_oauth_callback_path, params: { state: flow.state, code: "the-code" }

      assert_redirected_to token_broker_path
      grant = McpBrokerGrant.sole
      assert_equal FakeStrad::ORIGIN, grant.authorization_server
      assert_equal FakeStrad::RESOURCE, grant.resource
      assert_equal FakeStrad::REVOKE_ENDPOINT, grant.revocation_endpoint
      assert_equal OauthClientIdentity.client_id, grant.client_id
      assert_equal "strad_ort_parentnew", grant.refresh_token
      assert_equal credentials_before, McpOauthCredential.count, "the grant must never become a credential a runtime writer can see"
      assert_equal 0, McpOauthPendingFlow.where.not(broker_authorization_server: nil).count
    end
  end

  test "a consent that returns no refresh token is refused rather than stored" do
    with_oauth_client_identity do
      post connect_token_broker_path, params: { authorization_server: FakeStrad::ORIGIN }
      flow = McpOauthPendingFlow.where.not(broker_authorization_server: nil).sole
      McpOauthService.any_instance.stubs(:exchange_code_for_tokens).returns("access_token" => "strad_oat_only")

      get mcp_oauth_callback_path, params: { state: flow.state, code: "c" }

      assert_response :bad_request
      assert_equal 0, McpBrokerGrant.count
    end
  end

  test "disconnect revokes the grant's refresh token at strad and forgets it" do
    with_oauth_client_identity do
      grant = @strad.create_grant!
      refresh_token = grant.refresh_token

      delete disconnect_token_broker_path, params: { authorization_server: FakeStrad::ORIGIN }

      assert_redirected_to token_broker_path
      assert_equal [ refresh_token ], @strad.revoked
      assert_equal "refresh_token", @strad.revocations.sole.params["token_type_hint"]
      assert_equal 0, McpBrokerGrant.count
    end
  end

  test "/supervisor shows a grant and its tokens without rendering a secret" do
    with_oauth_client_identity do
      grant = @strad.create_grant!
      child = TokenBroker.mint_for_session(sessions(:active_session), %w[image-diff]).tokens["image-diff"]

      [ supervisor_mcp_broker_grant_path(grant), supervisor_mcp_broker_grants_path,
        supervisor_mcp_brokered_token_path(McpBrokeredToken.sole), supervisor_mcp_brokered_tokens_path ].each do |path|
        get path
        assert_response :success, path
        [ grant.access_token, grant.refresh_token, child ].each { |secret| refute_includes response.body, secret, path }
      end
    end
  end
end
