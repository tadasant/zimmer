require "test_helper"

class McpOauthPendingFlowTest < ActiveSupport::TestCase
  test "validates presence of required fields" do
    flow = McpOauthPendingFlow.new

    assert_not flow.valid?
    assert_includes flow.errors[:session], "must exist"
    assert_includes flow.errors[:server_name], "can't be blank"
    assert_includes flow.errors[:server_url], "can't be blank"
    assert_includes flow.errors[:state], "can't be blank"
    assert_includes flow.errors[:code_verifier], "can't be blank"
    assert_includes flow.errors[:authorization_endpoint], "can't be blank"
    assert_includes flow.errors[:token_endpoint], "can't be blank"
    assert_includes flow.errors[:client_id], "can't be blank"
    assert_includes flow.errors[:redirect_uri], "can't be blank"
    assert_includes flow.errors[:expires_at], "can't be blank"
  end

  test "validates uniqueness of state" do
    existing = mcp_oauth_pending_flows(:pending_notion)

    duplicate = McpOauthPendingFlow.new(
      session: sessions(:running),
      server_name: "other-server",
      server_url: "https://other.example.com",
      state: existing.state,
      code_verifier: "unique-verifier-12345678901234567890123",
      authorization_endpoint: "https://other.example.com/auth",
      token_endpoint: "https://other.example.com/token",
      client_id: "other-client",
      redirect_uri: "http://localhost:3000/callback",
      mcp_server_config: {},
      expires_at: 1.hour.from_now
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:state], "has already been taken"
  end

  test "validates mcp_server_config is a hash" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.mcp_server_config = "not a hash"

    assert_not flow.valid?
    assert_includes flow.errors[:mcp_server_config], "must be a valid JSON object"
  end

  test "expired? returns true when expires_at is in the past" do
    flow = mcp_oauth_pending_flows(:expired_flow)

    assert flow.expired?
  end

  test "expired? returns false when expires_at is in the future" do
    flow = mcp_oauth_pending_flows(:pending_notion)

    assert_not flow.expired?
  end

  test "localhost_flow? returns true for localhost redirect_uri" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.redirect_uri = "http://localhost:3000/callback"

    assert flow.localhost_flow?
  end

  test "localhost_flow? returns true for 127.0.0.1 redirect_uri" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.redirect_uri = "http://127.0.0.1:3000/callback"

    assert flow.localhost_flow?
  end

  test "localhost_flow? returns false for non-localhost redirect_uri" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.redirect_uri = "https://example.com/callback"

    assert_not flow.localhost_flow?
  end

  test "code_challenge generates S256 hash of code_verifier" do
    flow = mcp_oauth_pending_flows(:pending_notion)

    challenge = flow.code_challenge

    # Verify it's a base64url encoded string without padding
    assert_match(/\A[A-Za-z0-9_-]+\z/, challenge)
    # Verify the challenge is 43 characters (256 bits / 6 bits per char = ~43)
    assert_operator challenge.length, :>=, 42
    assert_operator challenge.length, :<=, 44
  end

  test "authorization_url includes all required OAuth parameters" do
    flow = mcp_oauth_pending_flows(:pending_notion)

    url = flow.authorization_url
    uri = URI(url)
    params = URI.decode_www_form(uri.query).to_h

    assert_equal "code", params["response_type"]
    assert_equal flow.client_id, params["client_id"]
    assert_equal flow.redirect_uri, params["redirect_uri"]
    assert_equal flow.state, params["state"]
    assert_equal flow.code_challenge, params["code_challenge"]
    assert_equal "S256", params["code_challenge_method"]
  end

  test "authorization_url includes RFC 8707 resource parameter when resource is present" do
    flow = mcp_oauth_pending_flows(:pending_notion)

    url = flow.authorization_url
    uri = URI(url)
    params = URI.decode_www_form(uri.query).to_h

    assert_equal "https://mcp.notion.com", params["resource"]
  end

  test "authorization_url omits resource parameter when resource is blank" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.resource = nil

    url = flow.authorization_url
    uri = URI(url)
    params = URI.decode_www_form(uri.query).to_h

    assert_nil params["resource"]
  end

  test "authorization_url includes scope when scopes is present" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.scopes = "read write"

    url = flow.authorization_url
    uri = URI(url)
    params = URI.decode_www_form(uri.query).to_h

    assert_equal "read write", params["scope"]
  end

  test "authorization_url adds Google params for Google OAuth endpoints" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.authorization_endpoint = "https://accounts.google.com/o/oauth2/v2/auth"

    url = flow.authorization_url
    uri = URI(url)
    params = URI.decode_www_form(uri.query).to_h

    assert_equal "offline", params["access_type"]
    assert_equal "consent", params["prompt"]
  end

  test "authorization_url does not include Google params for non-Google OAuth" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.authorization_endpoint = "https://api.notion.com/v1/oauth/authorize"

    url = flow.authorization_url
    uri = URI(url)
    params = URI.decode_www_form(uri.query).to_h

    assert_nil params["access_type"]
    assert_nil params["prompt"]
  end

  test "google_oauth_provider? returns true for accounts.google.com" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.authorization_endpoint = "https://accounts.google.com/o/oauth2/v2/auth"

    assert flow.google_oauth_provider?
  end

  test "google_oauth_provider? returns true for other Google domains" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.authorization_endpoint = "https://oauth2.google.com/authorize"

    assert flow.google_oauth_provider?
  end

  test "google_oauth_provider? returns false for non-Google providers" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.authorization_endpoint = "https://api.notion.com/v1/oauth/authorize"

    assert_not flow.google_oauth_provider?
  end

  test "google_oauth_provider? returns false for nil authorization_endpoint" do
    flow = McpOauthPendingFlow.new
    flow.authorization_endpoint = nil

    assert_not flow.google_oauth_provider?
  end

  test "google_oauth_provider? returns false for invalid URI" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.authorization_endpoint = "not a valid uri %%"

    assert_not flow.google_oauth_provider?
  end

  test "google_oauth_provider? returns false for spoofed domains like evilgoogle.com" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.authorization_endpoint = "https://evilgoogle.com/oauth"

    assert_not flow.google_oauth_provider?
  end

  test "google_oauth_provider? returns false for domains containing google.com substring" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    flow.authorization_endpoint = "https://not-google.com/oauth"

    assert_not flow.google_oauth_provider?
  end

  test "create_for_session! creates flow with generated values" do
    session = sessions(:running)
    oauth_metadata = {
      authorization_endpoint: "https://example.com/auth",
      token_endpoint: "https://example.com/token",
      client_id: "test-client",
      scopes: "read write"
    }

    flow = McpOauthPendingFlow.create_for_session!(
      session: session,
      server_name: "test-server",
      server_url: "https://test.example.com/mcp",
      oauth_metadata: oauth_metadata,
      redirect_uri: "http://localhost:3000/callback",
      mcp_server_config: { type: "http", url: "https://test.example.com/mcp" }
    )

    assert flow.persisted?
    assert_equal session, flow.session
    assert_equal "test-server", flow.server_name
    assert flow.state.present?
    assert flow.code_verifier.present?
    assert_equal 43, flow.code_verifier.length
    assert flow.expires_at > Time.current
  end

  test "create_for_session! persists the resource from oauth_metadata" do
    session = sessions(:running)
    oauth_metadata = {
      authorization_endpoint: "https://example.com/auth",
      token_endpoint: "https://example.com/token",
      client_id: "test-client",
      resource: "https://mcp.example.com"
    }

    flow = McpOauthPendingFlow.create_for_session!(
      session: session,
      server_name: "test-server",
      server_url: "https://test.example.com/mcp",
      oauth_metadata: oauth_metadata,
      redirect_uri: "http://localhost:3000/callback",
      mcp_server_config: { type: "http", url: "https://test.example.com/mcp" }
    )

    assert_equal "https://mcp.example.com", flow.resource
  end

  test "create_for_session! with Google OAuth endpoint adds Google params to authorization_url" do
    session = sessions(:running)
    oauth_metadata = {
      authorization_endpoint: "https://accounts.google.com/o/oauth2/v2/auth",
      token_endpoint: "https://oauth2.googleapis.com/token",
      client_id: "test-client",
      scopes: "https://www.googleapis.com/auth/bigquery"
    }

    flow = McpOauthPendingFlow.create_for_session!(
      session: session,
      server_name: "bigquery-pulsemcp",
      server_url: "https://bigquery.googleapis.com/mcp",
      oauth_metadata: oauth_metadata,
      redirect_uri: "http://localhost:3000/callback",
      mcp_server_config: { type: "streamable-http", url: "https://bigquery.googleapis.com/mcp" }
    )

    assert flow.persisted?

    # Verify the authorization URL includes Google-specific params for refresh token
    url = flow.authorization_url
    uri = URI(url)
    params = URI.decode_www_form(uri.query).to_h

    assert_equal "offline", params["access_type"]
    assert_equal "consent", params["prompt"]
  end

  # --- manual (paste-back) mode ---

  test "create_for_session! persists the manual flag from oauth_metadata" do
    session = sessions(:running)
    flow = McpOauthPendingFlow.create_for_session!(
      session: session,
      server_name: "slack",
      server_url: "https://mcp.slack.com/mcp",
      oauth_metadata: {
        authorization_endpoint: "https://slack.com/oauth/v2_user/authorize",
        token_endpoint: "https://slack.com/api/oauth.v2.user.access",
        client_id: "cid",
        manual: true
      },
      redirect_uri: "http://localhost:3118/callback",
      mcp_server_config: { type: "http", url: "https://mcp.slack.com/mcp" }
    )

    assert flow.manual?
  end

  test "create_for_session! defaults manual to false" do
    session = sessions(:running)
    flow = McpOauthPendingFlow.create_for_session!(
      session: session,
      server_name: "test-server",
      server_url: "https://test.example.com/mcp",
      oauth_metadata: {
        authorization_endpoint: "https://example.com/auth",
        token_endpoint: "https://example.com/token",
        client_id: "test-client"
      },
      redirect_uri: "http://localhost:3000/callback",
      mcp_server_config: { type: "http", url: "https://test.example.com/mcp" }
    )

    assert_not flow.manual?
  end

  # --- authorization_code_from_pasted (out-of-band completion) ---

  test "authorization_code_from_pasted extracts code from a full redirect URL with matching state" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    url = "http://localhost:3118/callback?code=the-code&state=#{flow.state}"

    assert_equal "the-code", flow.authorization_code_from_pasted(url)
  end

  test "authorization_code_from_pasted accepts a bare authorization code" do
    flow = mcp_oauth_pending_flows(:pending_notion)

    assert_equal "bare-code-123", flow.authorization_code_from_pasted("bare-code-123")
  end

  test "authorization_code_from_pasted accepts a bare query string" do
    flow = mcp_oauth_pending_flows(:pending_notion)

    assert_equal "qcode", flow.authorization_code_from_pasted("code=qcode&state=#{flow.state}")
  end

  test "authorization_code_from_pasted rejects a URL whose state does not match" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    url = "http://localhost:3118/callback?code=the-code&state=some-other-state"

    assert_nil flow.authorization_code_from_pasted(url)
  end

  test "authorization_code_from_pasted accepts a URL that omits state" do
    flow = mcp_oauth_pending_flows(:pending_notion)

    assert_equal "c", flow.authorization_code_from_pasted("http://localhost:3118/callback?code=c")
  end

  test "authorization_code_from_pasted URL-decodes the code and drops fragments" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    url = "http://localhost:3118/callback?state=#{flow.state}&code=a%2Bb%2Fc#_=_"

    assert_equal "a+b/c", flow.authorization_code_from_pasted(url)
  end

  test "authorization_code_from_pasted returns nil for blank or code-less input" do
    flow = mcp_oauth_pending_flows(:pending_notion)

    assert_nil flow.authorization_code_from_pasted("")
    assert_nil flow.authorization_code_from_pasted("   ")
    assert_nil flow.authorization_code_from_pasted(nil)
    assert_nil flow.authorization_code_from_pasted("http://localhost:3118/callback?state=#{flow.state}")
  end

  test "credential_key computes key matching McpOauthCredential format" do
    flow = mcp_oauth_pending_flows(:pending_notion)

    credential_key = flow.credential_key

    assert_match(/\A.+\|[a-f0-9]{16}\z/, credential_key)
  end

  test "active scope excludes expired flows" do
    expired = mcp_oauth_pending_flows(:expired_flow)

    assert_not_includes McpOauthPendingFlow.active, expired
  end

  test "expired scope includes expired flows" do
    expired = mcp_oauth_pending_flows(:expired_flow)

    assert_includes McpOauthPendingFlow.expired, expired
  end

  test "for_session scope filters by session" do
    flow = mcp_oauth_pending_flows(:pending_notion)
    session = flow.session

    flows = McpOauthPendingFlow.for_session(session)

    assert_includes flows, flow
    assert flows.all? { |f| f.session_id == session.id }
  end
end
