# frozen_string_literal: true

require "test_helper"

class McpOauthServiceTest < ActiveSupport::TestCase
  setup do
    @service = McpOauthService.new
    @registration_endpoint = "https://auth.example.com/oauth/register"
    @server_url = "https://api.example.com/mcp"
  end

  # --- perform_dcr tests ---

  test "perform_dcr includes scopes from auth server metadata" do
    auth_metadata = {
      "scopes_supported" => [ "user", "forms", "mcp" ],
      "token_endpoint_auth_methods_supported" => [ "none" ]
    }

    posted_body = nil
    mock_http = mock_http_success({ "client_id" => "test-id" }) do |body|
      posted_body = body
    end

    stub_net_http(mock_http) do
      @service.perform_dcr(@registration_endpoint, @server_url, auth_server_metadata: auth_metadata)
    end

    assert_equal "user forms mcp", posted_body["scope"]
  end

  test "perform_dcr prefers client_secret_post over client_secret_basic" do
    auth_metadata = {
      "token_endpoint_auth_methods_supported" => [ "client_secret_basic", "client_secret_post" ]
    }

    posted_body = nil
    mock_http = mock_http_success({ "client_id" => "test-id" }) do |body|
      posted_body = body
    end

    stub_net_http(mock_http) do
      @service.perform_dcr(@registration_endpoint, @server_url, auth_server_metadata: auth_metadata)
    end

    assert_equal "client_secret_post", posted_body["token_endpoint_auth_method"]
  end

  test "perform_dcr falls back to first method when neither none nor client_secret_post available" do
    auth_metadata = {
      "token_endpoint_auth_methods_supported" => [ "client_secret_basic" ]
    }

    posted_body = nil
    mock_http = mock_http_success({ "client_id" => "test-id" }) do |body|
      posted_body = body
    end

    stub_net_http(mock_http) do
      @service.perform_dcr(@registration_endpoint, @server_url, auth_server_metadata: auth_metadata)
    end

    assert_equal "client_secret_basic", posted_body["token_endpoint_auth_method"]
  end

  test "perform_dcr prefers none when it is in the supported methods list" do
    auth_metadata = {
      "token_endpoint_auth_methods_supported" => [ "client_secret_post", "none" ]
    }

    posted_body = nil
    mock_http = mock_http_success({ "client_id" => "test-id" }) do |body|
      posted_body = body
    end

    stub_net_http(mock_http) do
      @service.perform_dcr(@registration_endpoint, @server_url, auth_server_metadata: auth_metadata)
    end

    assert_equal "none", posted_body["token_endpoint_auth_method"]
  end

  test "perform_dcr defaults to none when auth methods list is empty" do
    auth_metadata = {
      "token_endpoint_auth_methods_supported" => []
    }

    posted_body = nil
    mock_http = mock_http_success({ "client_id" => "test-id" }) do |body|
      posted_body = body
    end

    stub_net_http(mock_http) do
      @service.perform_dcr(@registration_endpoint, @server_url, auth_server_metadata: auth_metadata)
    end

    assert_equal "none", posted_body["token_endpoint_auth_method"]
  end

  test "perform_dcr defaults to none when auth methods not specified in metadata" do
    posted_body = nil
    mock_http = mock_http_success({ "client_id" => "test-id" }) do |body|
      posted_body = body
    end

    stub_net_http(mock_http) do
      @service.perform_dcr(@registration_endpoint, @server_url, auth_server_metadata: {})
    end

    assert_equal "none", posted_body["token_endpoint_auth_method"]
  end

  test "perform_dcr defaults to none when no metadata provided" do
    posted_body = nil
    mock_http = mock_http_success({ "client_id" => "test-id" }) do |body|
      posted_body = body
    end

    stub_net_http(mock_http) do
      @service.perform_dcr(@registration_endpoint, @server_url)
    end

    assert_equal "none", posted_body["token_endpoint_auth_method"]
    assert_nil posted_body["scope"]
  end

  test "perform_dcr does not include scope when scopes_supported is empty" do
    auth_metadata = {
      "scopes_supported" => []
    }

    posted_body = nil
    mock_http = mock_http_success({ "client_id" => "test-id" }) do |body|
      posted_body = body
    end

    stub_net_http(mock_http) do
      @service.perform_dcr(@registration_endpoint, @server_url, auth_server_metadata: auth_metadata)
    end

    assert_nil posted_body["scope"]
  end

  test "perform_dcr returns nil on HTTP error" do
    mock_http = mock_http_error(400, '{"error":"invalid_scope"}')

    result = stub_net_http(mock_http) do
      @service.perform_dcr(@registration_endpoint, @server_url, auth_server_metadata: {})
    end

    assert_nil result
  end

  # --- fetch_oauth_metadata integration test ---

  test "fetch_oauth_metadata passes auth server metadata to perform_dcr" do
    auth_server_json = {
      "authorization_endpoint" => "https://auth.example.com/authorize",
      "token_endpoint" => "https://auth.example.com/token",
      "registration_endpoint" => "https://auth.example.com/register",
      "scopes_supported" => [ "read", "write" ],
      "token_endpoint_auth_methods_supported" => [ "client_secret_post" ]
    }

    dcr_response = {
      "client_id" => "dcr-client-id",
      "client_secret" => "dcr-client-secret"
    }

    posted_body = nil
    call_count = 0

    mock_http = Object.new
    mock_http.define_singleton_method(:use_ssl=) { |_| }
    mock_http.define_singleton_method(:open_timeout=) { |_| }
    mock_http.define_singleton_method(:read_timeout=) { |_| }
    mock_http.define_singleton_method(:request) do |req|
      call_count += 1
      if req.is_a?(Net::HTTP::Get)
        # Return auth server metadata for the well-known endpoint
        response = Net::HTTPSuccess.new("1.1", "200", "OK")
        response.define_singleton_method(:code) { "200" }
        response.define_singleton_method(:body) { auth_server_json.to_json }
        response.define_singleton_method(:[]) { |_key| "application/json" }
        response
      else
        # DCR POST request — capture the body
        posted_body = JSON.parse(req.body)
        response = Net::HTTPSuccess.new("1.1", "201", "Created")
        response.define_singleton_method(:code) { "201" }
        response.define_singleton_method(:body) { dcr_response.to_json }
        response.define_singleton_method(:[]) { |_key| "application/json" }
        response
      end
    end

    result = stub_net_http(mock_http) do
      @service.fetch_oauth_metadata("https://api.example.com/mcp")
    end

    # Verify DCR was called with the correct auth method and scopes from server metadata
    assert_not_nil posted_body, "DCR should have been called"
    assert_equal "client_secret_post", posted_body["token_endpoint_auth_method"]
    assert_equal "read write", posted_body["scope"]

    # Verify the returned metadata includes the DCR client credentials
    assert_equal "dcr-client-id", result.client_id
    assert_equal "dcr-client-secret", result.client_secret
  end

  # --- configured (statically pre-registered) client id tests ---

  test "fetch_oauth_metadata uses a configured client id instead of performing DCR" do
    # Slack-shaped server: discovery resolves the authorization/token endpoints
    # AND advertises a registration_endpoint, but the client must be pre-registered.
    # The configured client id must win over DCR so the authorize URL is valid.
    auth_server_json = {
      "authorization_endpoint" => "https://slack.com/oauth/v2_user/authorize",
      "token_endpoint" => "https://slack.com/api/oauth.v2.access",
      "registration_endpoint" => "https://slack.com/oauth/register",
      "scopes_supported" => [ "chat:write" ]
    }

    dcr_called = false
    mock_http = Object.new
    mock_http.define_singleton_method(:use_ssl=) { |_| }
    mock_http.define_singleton_method(:open_timeout=) { |_| }
    mock_http.define_singleton_method(:read_timeout=) { |_| }
    mock_http.define_singleton_method(:request) do |req|
      dcr_called = true if req.is_a?(Net::HTTP::Post)
      response = Net::HTTPSuccess.new("1.1", "200", "OK")
      response.define_singleton_method(:code) { "200" }
      response.define_singleton_method(:body) { auth_server_json.to_json }
      response.define_singleton_method(:[]) { |_key| "application/json" }
      response
    end

    result = stub_net_http(mock_http) do
      @service.fetch_oauth_metadata(
        "https://mcp.slack.com/mcp",
        configured_client_id: "1601185624273.8899143856786"
      )
    end

    assert_equal "1601185624273.8899143856786", result.client_id
    assert_not dcr_called, "DCR must not run when a client id is statically configured"
  end

  test "fetch_oauth_metadata carries a configured client secret through for confidential clients" do
    auth_server_json = {
      "authorization_endpoint" => "https://auth.example.com/authorize",
      "token_endpoint" => "https://auth.example.com/token"
    }

    mock_http = Object.new
    mock_http.define_singleton_method(:use_ssl=) { |_| }
    mock_http.define_singleton_method(:open_timeout=) { |_| }
    mock_http.define_singleton_method(:read_timeout=) { |_| }
    mock_http.define_singleton_method(:request) do |_req|
      response = Net::HTTPSuccess.new("1.1", "200", "OK")
      response.define_singleton_method(:code) { "200" }
      response.define_singleton_method(:body) { auth_server_json.to_json }
      response.define_singleton_method(:[]) { |_key| "application/json" }
      response
    end

    result = stub_net_http(mock_http) do
      @service.fetch_oauth_metadata(
        "https://api.example.com/mcp",
        configured_client_id: "cid-123",
        configured_client_secret: "shh-secret"
      )
    end

    assert_equal "cid-123", result.client_id
    assert_equal "shh-secret", result.client_secret
  end

  test "fetch_oauth_metadata falls back to the zimmer literal only without DCR or a configured client" do
    # No registration_endpoint and no configured client id: the legacy public-client
    # fallback still applies so servers that accept any client id keep working.
    auth_server_json = {
      "authorization_endpoint" => "https://auth.example.com/authorize",
      "token_endpoint" => "https://auth.example.com/token"
    }

    mock_http = Object.new
    mock_http.define_singleton_method(:use_ssl=) { |_| }
    mock_http.define_singleton_method(:open_timeout=) { |_| }
    mock_http.define_singleton_method(:read_timeout=) { |_| }
    mock_http.define_singleton_method(:request) do |_req|
      response = Net::HTTPSuccess.new("1.1", "200", "OK")
      response.define_singleton_method(:code) { "200" }
      response.define_singleton_method(:body) { auth_server_json.to_json }
      response.define_singleton_method(:[]) { |_key| "application/json" }
      response
    end

    result = stub_net_http(mock_http) do
      @service.fetch_oauth_metadata("https://api.example.com/mcp")
    end

    assert_equal "zimmer", result.client_id
  end

  test "fetch_oauth_metadata_from_url uses a configured client id instead of performing DCR" do
    # The 401 / WWW-Authenticate: resource_metadata=… probe path. A Slack-style
    # server that only 401s lands here, so the configured client id must win over
    # the advertised registration_endpoint on this branch too.
    protected_resource_json = {
      "resource" => "https://mcp.slack.com",
      "authorization_servers" => [ "https://slack.com" ]
    }
    auth_server_json = {
      "authorization_endpoint" => "https://slack.com/oauth/v2_user/authorize",
      "token_endpoint" => "https://slack.com/api/oauth.v2.access",
      "registration_endpoint" => "https://slack.com/oauth/register"
    }

    dcr_called = false
    mock_http = Object.new
    mock_http.define_singleton_method(:use_ssl=) { |_| }
    mock_http.define_singleton_method(:open_timeout=) { |_| }
    mock_http.define_singleton_method(:read_timeout=) { |_| }
    mock_http.define_singleton_method(:request) do |req|
      dcr_called = true if req.is_a?(Net::HTTP::Post)
      body = if req.path.include?("oauth-protected-resource")
        protected_resource_json.to_json
      else
        auth_server_json.to_json
      end
      response = Net::HTTPSuccess.new("1.1", "200", "OK")
      response.define_singleton_method(:code) { "200" }
      response.define_singleton_method(:body) { body }
      response.define_singleton_method(:[]) { |_key| "application/json" }
      response
    end

    result = stub_net_http(mock_http) do
      @service.send(:fetch_oauth_metadata_from_url,
        "https://mcp.slack.com/.well-known/oauth-protected-resource",
        server_url: "https://mcp.slack.com/mcp",
        configured_client_id: "1601185624273.8899143856786"
      )
    end

    assert_equal "1601185624273.8899143856786", result.client_id
    assert_not dcr_called, "DCR must not run when a client id is statically configured"
  end

  # --- perform_dcr success/error tests ---

  test "perform_dcr returns response with client_id and client_secret on success" do
    dcr_response = {
      "client_id" => "registered-client-id",
      "client_secret" => "registered-client-secret",
      "client_id_issued_at" => 1234567890
    }

    mock_http = mock_http_success(dcr_response)

    result = stub_net_http(mock_http) do
      @service.perform_dcr(@registration_endpoint, @server_url, auth_server_metadata: {})
    end

    assert_equal "registered-client-id", result["client_id"]
    assert_equal "registered-client-secret", result["client_secret"]
  end

  # --- RFC 8707 resource indicator tests ---

  test "exchange_code_for_tokens includes the RFC 8707 resource parameter" do
    flow = mcp_oauth_pending_flows(:pending_notion) # resource: https://mcp.notion.com
    captured_params = nil

    response = Net::HTTPSuccess.new("1.1", "200", "OK")
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:body) { { access_token: "tok-123" }.to_json }
    response.define_singleton_method(:[]) { |_key| "application/json" }

    Net::HTTP.stub(:post_form, ->(_uri, params) { captured_params = params; response }) do
      @service.exchange_code_for_tokens(flow, "auth-code-abc")
    end

    assert_equal "https://mcp.notion.com", captured_params[:resource]
  end

  test "exchange_code_for_tokens omits resource parameter when flow has no resource" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.update_column(:resource, nil)
    captured_params = nil

    response = Net::HTTPSuccess.new("1.1", "200", "OK")
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:body) { { access_token: "tok-123" }.to_json }
    response.define_singleton_method(:[]) { |_key| "application/json" }

    Net::HTTP.stub(:post_form, ->(_uri, params) { captured_params = params; response }) do
      @service.exchange_code_for_tokens(flow, "auth-code-abc")
    end

    assert_not captured_params.key?(:resource)
  end

  test "fetch_oauth_metadata captures the PRM-advertised resource" do
    protected_resource_json = {
      "resource" => "https://mcp.notion.com",
      "authorization_servers" => [ "https://auth.notion.com" ]
    }
    auth_server_json = {
      "authorization_endpoint" => "https://auth.notion.com/authorize",
      "token_endpoint" => "https://auth.notion.com/token"
    }

    mock_http = Object.new
    mock_http.define_singleton_method(:use_ssl=) { |_| }
    mock_http.define_singleton_method(:open_timeout=) { |_| }
    mock_http.define_singleton_method(:read_timeout=) { |_| }
    mock_http.define_singleton_method(:request) do |req|
      # req.path carries only the path component, so dispatch on the well-known
      # document being requested: PRM (RFC 9728) vs authorization server (RFC 8414).
      body = if req.path.include?("oauth-protected-resource")
        protected_resource_json.to_json
      else
        auth_server_json.to_json
      end
      response = Net::HTTPSuccess.new("1.1", "200", "OK")
      response.define_singleton_method(:code) { "200" }
      response.define_singleton_method(:body) { body }
      response.define_singleton_method(:[]) { |_key| "application/json" }
      response
    end

    result = stub_net_http(mock_http) do
      @service.fetch_oauth_metadata("https://mcp.notion.com/mcp")
    end

    assert_equal "https://mcp.notion.com", result.resource
  end

  test "fetch_oauth_metadata_from_url captures the PRM-advertised resource" do
    # This is the 401 / WWW-Authenticate discovery path: the server points us at
    # its resource_metadata URL. A missing resource here would silently
    # reintroduce the audience-binding bug, so it must be captured too.
    protected_resource_json = {
      "resource" => "https://mcp.notion.com",
      "authorization_servers" => [ "https://auth.notion.com" ]
    }
    auth_server_json = {
      "authorization_endpoint" => "https://auth.notion.com/authorize",
      "token_endpoint" => "https://auth.notion.com/token"
    }

    mock_http = Object.new
    mock_http.define_singleton_method(:use_ssl=) { |_| }
    mock_http.define_singleton_method(:open_timeout=) { |_| }
    mock_http.define_singleton_method(:read_timeout=) { |_| }
    mock_http.define_singleton_method(:request) do |req|
      body = if req.path.include?("oauth-protected-resource")
        protected_resource_json.to_json
      else
        auth_server_json.to_json
      end
      response = Net::HTTPSuccess.new("1.1", "200", "OK")
      response.define_singleton_method(:code) { "200" }
      response.define_singleton_method(:body) { body }
      response.define_singleton_method(:[]) { |_key| "application/json" }
      response
    end

    result = stub_net_http(mock_http) do
      @service.send(:fetch_oauth_metadata_from_url,
        "https://mcp.notion.com/.well-known/oauth-protected-resource",
        server_url: "https://mcp.notion.com/mcp"
      )
    end

    assert_equal "https://mcp.notion.com", result.resource
  end

  test "fetch_oauth_metadata_from_url falls back to the canonical MCP server URL when PRM omits resource" do
    protected_resource_json = {
      "authorization_servers" => [ "https://auth.example.com" ]
    }
    auth_server_json = {
      "authorization_endpoint" => "https://auth.example.com/authorize",
      "token_endpoint" => "https://auth.example.com/token"
    }

    mock_http = Object.new
    mock_http.define_singleton_method(:use_ssl=) { |_| }
    mock_http.define_singleton_method(:open_timeout=) { |_| }
    mock_http.define_singleton_method(:read_timeout=) { |_| }
    mock_http.define_singleton_method(:request) do |req|
      body = if req.path.include?("oauth-protected-resource")
        protected_resource_json.to_json
      else
        auth_server_json.to_json
      end
      response = Net::HTTPSuccess.new("1.1", "200", "OK")
      response.define_singleton_method(:code) { "200" }
      response.define_singleton_method(:body) { body }
      response.define_singleton_method(:[]) { |_key| "application/json" }
      response
    end

    result = stub_net_http(mock_http) do
      @service.send(:fetch_oauth_metadata_from_url,
        "https://mcp.example.com/.well-known/oauth-protected-resource",
        server_url: "https://mcp.example.com/mcp/"
      )
    end

    assert_equal "https://mcp.example.com/mcp", result.resource
  end

  test "canonical_resource prefers the PRM-advertised resource" do
    assert_equal "https://mcp.notion.com",
      @service.canonical_resource("https://mcp.notion.com", "https://mcp.notion.com/mcp")
  end

  test "canonical_resource falls back to the canonical MCP server URL when PRM has none" do
    assert_equal "https://mcp.example.com/mcp",
      @service.canonical_resource(nil, "https://mcp.example.com/mcp/")
    assert_equal "https://mcp.example.com",
      @service.canonical_resource("", "https://mcp.example.com/")
    assert_equal "https://mcp.example.com:8443/path",
      @service.canonical_resource(nil, "https://mcp.example.com:8443/path?foo=bar")
  end

  # --- Public client (no client_secret) token exchange ---

  test "exchange_code_for_tokens omits client_secret when the flow has none" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.update_column(:client_secret, nil)
    captured_params = nil

    response = Net::HTTPSuccess.new("1.1", "200", "OK")
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:body) { { access_token: "tok-123" }.to_json }
    response.define_singleton_method(:[]) { |_key| "application/json" }

    Net::HTTP.stub(:post_form, ->(_uri, params) { captured_params = params; response }) do
      @service.exchange_code_for_tokens(flow, "auth-code-abc")
    end

    assert_not captured_params.key?(:client_secret), "public client must not send client_secret"
    assert_equal flow.code_verifier, captured_params[:code_verifier], "PKCE verifier proves possession"
    assert_equal flow.client_id, captured_params[:client_id]
  end

  test "exchange_code_for_tokens includes client_secret when the flow has one" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.update_column(:client_secret, "shh-secret")
    captured_params = nil

    response = Net::HTTPSuccess.new("1.1", "200", "OK")
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:body) { { access_token: "tok-123" }.to_json }
    response.define_singleton_method(:[]) { |_key| "application/json" }

    Net::HTTP.stub(:post_form, ->(_uri, params) { captured_params = params; response }) do
      @service.exchange_code_for_tokens(flow, "auth-code-abc")
    end

    assert_equal "shh-secret", captured_params[:client_secret]
  end

  # --- extract_tokens (nested Slack authed_user shape) ---

  test "extract_tokens returns a top-level access token verbatim" do
    tokens = @service.extract_tokens(
      "access_token" => "xoxb-top", "refresh_token" => "r1", "scope" => "a b", "expires_in" => 3600
    )
    assert_equal "xoxb-top", tokens["access_token"]
    assert_equal "r1", tokens["refresh_token"]
    assert_equal "a b", tokens["scope"]
    assert_equal 3600, tokens["expires_in"]
  end

  test "extract_tokens unwraps a nested authed_user.access_token (Slack user token)" do
    # Slack oauth.v2.user.access nests the user token under authed_user.
    tokens = @service.extract_tokens(
      "ok" => true,
      "authed_user" => {
        "id" => "U123",
        "access_token" => "xoxp-user",
        "refresh_token" => "xoxe-refresh",
        "scope" => "search:read users:read",
        "expires_in" => 43200
      }
    )
    assert_equal "xoxp-user", tokens["access_token"]
    assert_equal "xoxe-refresh", tokens["refresh_token"]
    assert_equal "search:read users:read", tokens["scope"]
    assert_equal 43200, tokens["expires_in"]
  end

  test "extract_tokens prefers a top-level access token over the nested one" do
    tokens = @service.extract_tokens(
      "access_token" => "xoxb-bot",
      "scope" => "bot:scope",
      "authed_user" => { "access_token" => "xoxp-user", "scope" => "user:scope" }
    )
    assert_equal "xoxb-bot", tokens["access_token"]
    assert_equal "bot:scope", tokens["scope"]
  end

  test "extract_tokens returns nil when no access token is present anywhere" do
    assert_nil @service.extract_tokens("ok" => false, "error" => "invalid_grant")
    assert_nil @service.extract_tokens("authed_user" => { "id" => "U1" })
    assert_nil @service.extract_tokens(nil)
  end

  private

  # Creates a mock HTTP object that captures the posted body and returns a success response
  def mock_http_success(response_body, &body_capture)
    response = Net::HTTPSuccess.new("1.1", "201", "Created")
    response.stubs(:code).returns("201")
    response.stubs(:body).returns(response_body.to_json)

    build_mock_http(response, &body_capture)
  end

  # Creates a mock HTTP object that returns an error response
  def mock_http_error(code, body)
    response = Net::HTTPBadRequest.new("1.1", code.to_s, "Bad Request")
    response.stubs(:code).returns(code.to_s)
    response.stubs(:body).returns(body)

    build_mock_http(response)
  end

  def build_mock_http(response, &body_capture)
    mock_http = Object.new
    mock_http.define_singleton_method(:use_ssl=) { |_| }
    mock_http.define_singleton_method(:open_timeout=) { |_| }
    mock_http.define_singleton_method(:read_timeout=) { |_| }
    mock_http.define_singleton_method(:request) do |req|
      body_capture&.call(JSON.parse(req.body))
      response
    end

    mock_http
  end

  def stub_net_http(mock_http, &block)
    Net::HTTP.stub(:new, mock_http, &block)
  end
end
