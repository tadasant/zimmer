# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Exercises the real OAuth callback wiring end-to-end: completing the token
# exchange stores the credential and, once every blocking flow is done, the
# session auto-resumes its original intent. The external token endpoint is the
# only thing stubbed (Net::HTTP.post_form); the resume decision runs for real.
class McpOauthControllerTest < ActionDispatch::IntegrationTest
  CONFIG_A = { type: "http", url: "https://a.example.com/mcp", headers: {} }.freeze
  CONFIG_B = { type: "http", url: "https://b.example.com/mcp", headers: {} }.freeze

  setup do
    @key_a = McpOauthCredential.compute_credential_key("server-a", CONFIG_A)
    @key_b = McpOauthCredential.compute_credential_key("server-b", CONFIG_B)

    @session = Session.create!(
      prompt: "Original intent to replay",
      agent_runtime: "claude_code",
      status: :failed,
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      metadata: {
        "failure_reason" => "oauth_required",
        "oauth_required_servers" => [
          { "server_name" => "server-a", "server_url" => CONFIG_A[:url], "credential_key" => @key_a },
          { "server_name" => "server-b", "server_url" => CONFIG_B[:url], "credential_key" => @key_b }
        ]
      }
    )
  end

  def pending_flow_for(server_name, config, state:)
    McpOauthPendingFlow.create!(
      session: @session,
      server_name: server_name,
      server_url: config[:url],
      state: state,
      code_verifier: "v" * 43,
      authorization_endpoint: "https://#{server_name}.example.com/oauth/authorize",
      token_endpoint: "https://#{server_name}.example.com/oauth/token",
      client_id: "test-client",
      redirect_uri: "http://localhost:3000/mcp_oauth/callback",
      mcp_server_config: config.stringify_keys.merge("headers" => {}),
      expires_at: 1.hour.from_now
    )
  end

  def token_response
    response = Net::HTTPSuccess.new("1.1", "200", "OK")
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:body) { { access_token: "tok-#{SecureRandom.hex(4)}" }.to_json }
    response.define_singleton_method(:[]) { |_key| "application/json" }
    response
  end

  test "completing the last OAuth flow stores the credential and auto-resumes the session" do
    # server-a already authorized in a prior step.
    McpOauthCredential.create!(
      server_name: "server-a", server_url: CONFIG_A[:url], credential_key: @key_a,
      client_id: "c", access_token: "a", token_endpoint: "https://a.example.com/oauth/token",
      expires_at: 1.hour.from_now
    )
    flow = pending_flow_for("server-b", CONFIG_B, state: "state-b")

    assert_enqueued_with(job: AgentSessionJob, args: [ @session.id ]) do
      Net::HTTP.stub(:post_form, ->(_uri, _params) { token_response }) do
        get mcp_oauth_callback_path, params: { state: flow.state, code: "auth-code" }
      end
    end

    assert McpOauthCredential.for_credential_key(@key_b).active.exists?, "server-b credential stored"
    assert_not McpOauthPendingFlow.exists?(flow.id), "pending flow cleaned up"

    @session.reload
    assert @session.waiting?, "session auto-resumed into waiting"
    assert_equal true, @session.metadata["oauth_complete"]
    assert_nil @session.metadata["failure_reason"]
    assert_nil @session.metadata["oauth_required_servers"]
    assert_equal "Original intent to replay", @session.prompt
  end

  test "completing one of several OAuth flows keeps the session blocked" do
    flow = pending_flow_for("server-a", CONFIG_A, state: "state-a")

    assert_no_enqueued_jobs do
      Net::HTTP.stub(:post_form, ->(_uri, _params) { token_response }) do
        get mcp_oauth_callback_path, params: { state: flow.state, code: "auth-code" }
      end
    end

    @session.reload
    assert @session.failed?, "session remains blocked while server-b still needs OAuth"
    assert_equal "oauth_required", @session.metadata["failure_reason"]
    assert_equal [ "server-b" ], @session.metadata["oauth_required_servers"].map { |s| s["server_name"] }
  end

  # Slack-shaped server: discovery resolves its endpoints but the client must be
  # pre-registered. The authorize redirect must carry the catalog-configured
  # client id, not the `zimmer` placeholder that Slack rejects.
  # Stubs RFC 8414 discovery so a catalog-configured server resolves its endpoints,
  # then POSTs to initiate for it.
  def initiate_catalog_server(server, server_name: "slack-reframe", server_url: "https://mcp.slack.com/mcp")
    auth_server_json = {
      "authorization_endpoint" => "https://slack.com/oauth/v2_user/authorize",
      "token_endpoint" => "https://slack.com/api/oauth.v2.access"
    }
    discovery_http = Object.new
    discovery_http.define_singleton_method(:use_ssl=) { |_| }
    discovery_http.define_singleton_method(:open_timeout=) { |_| }
    discovery_http.define_singleton_method(:read_timeout=) { |_| }
    discovery_http.define_singleton_method(:request) do |_req|
      response = Net::HTTPSuccess.new("1.1", "200", "OK")
      response.define_singleton_method(:code) { "200" }
      response.define_singleton_method(:body) { auth_server_json.to_json }
      response.define_singleton_method(:[]) { |_key| "application/json" }
      response
    end

    ServersConfig.stub(:find, ->(name) { name == server_name ? server : nil }) do
      Net::HTTP.stub(:new, discovery_http) do
        post mcp_oauth_initiate_path, params: {
          session_id: @session.id, server_name: server_name, server_url: server_url
        }
      end
    end
  end

  test "initiate uses the catalog-configured client id in the authorize redirect" do
    configured_server = ServersConfig::Server.new("slack-reframe", {
      "type" => "streamable-http",
      "url" => "https://mcp.slack.com/mcp",
      "oauth" => { "clientId" => "1601185624273.8899143856786" }
    })

    initiate_catalog_server(configured_server)

    assert_response :redirect
    location = URI(@response.headers["Location"])
    query = URI.decode_www_form(location.query).to_h
    assert_equal "1601185624273.8899143856786", query["client_id"]
    assert_not_equal "zimmer", query["client_id"]

    pending = McpOauthPendingFlow.for_session(@session).find_by(server_name: "slack-reframe")
    assert_equal "1601185624273.8899143856786", pending.client_id

    # No catalog redirectUri: the hosted callback still applies, and the flow still
    # completes automatically rather than by paste-back.
    assert_equal McpOauthService.new.build_redirect_uri, query["redirect_uri"]
    assert_equal McpOauthService.new.build_redirect_uri, pending.redirect_uri
    assert_not pending.manual?, "hosted-callback flow is not paste-back"
  end

  # Slack's public MCP client only permits its own localhost redirect; handing it
  # Zimmer's hosted callback fails at the consent screen with "redirect_uri did not
  # match any configured URIs". The catalog declares the redirect it accepts.
  test "initiate honors a catalog-configured redirect uri and completes by paste-back" do
    configured_server = ServersConfig::Server.new("slack-reframe", {
      "type" => "streamable-http",
      "url" => "https://mcp.slack.com/mcp",
      "oauth" => {
        "clientId" => "1601185624273.8899143856786",
        "redirectUri" => "http://localhost:3118/callback"
      }
    })

    initiate_catalog_server(configured_server)

    # Nothing to redirect to: Zimmer never sees this callback, so it renders paste-back.
    assert_response :success
    assert_select "form[action=?]", mcp_oauth_complete_path
    assert_select "textarea#redirect_response"

    pending = McpOauthPendingFlow.for_session(@session).find_by(server_name: "slack-reframe")
    assert pending.manual?, "flow marked manual"
    assert_equal "http://localhost:3118/callback", pending.redirect_uri

    # The authorize URL the user opens carries the catalog redirect, not the hosted one.
    query = URI.decode_www_form(URI(pending.authorization_url).query).to_h
    assert_equal "http://localhost:3118/callback", query["redirect_uri"]
    assert_not_equal McpOauthService.new.build_redirect_uri, query["redirect_uri"]
    assert_equal "1601185624273.8899143856786", query["client_id"]
    assert_equal "S256", query["code_challenge_method"]
  end

  # Regression guard: the hosted callback must stay the default for ordinary servers.
  test "initiate keeps the hosted callback for a server with no catalog oauth block" do
    plain_server = ServersConfig::Server.new("slack-reframe", {
      "type" => "streamable-http",
      "url" => "https://mcp.slack.com/mcp"
    })

    initiate_catalog_server(plain_server)

    assert_response :redirect
    query = URI.decode_www_form(URI(@response.headers["Location"]).query).to_h
    assert_equal McpOauthService.new.build_redirect_uri, query["redirect_uri"]

    pending = McpOauthPendingFlow.for_session(@session).find_by(server_name: "slack-reframe")
    assert_not pending.manual?
    assert_equal McpOauthService.new.build_redirect_uri, pending.redirect_uri
  end

  # --- Callback with a nested Slack user token (authed_user.access_token) ---

  def slack_nested_token_response
    response = Net::HTTPSuccess.new("1.1", "200", "OK")
    response.define_singleton_method(:code) { "200" }
    response.define_singleton_method(:body) do
      { ok: true, authed_user: { id: "U1", access_token: "xoxp-user-tok", scope: "users:read" } }.to_json
    end
    response.define_singleton_method(:[]) { |_key| "application/json" }
    response
  end

  test "callback stores a nested authed_user.access_token (Slack shape)" do
    flow = pending_flow_for("server-a", CONFIG_A, state: "nested-a")
    # server-b already authorized so completing server-a resumes.
    McpOauthCredential.create!(
      server_name: "server-b", server_url: CONFIG_B[:url], credential_key: @key_b,
      client_id: "c", access_token: "b", token_endpoint: "https://b.example.com/oauth/token",
      expires_at: 1.hour.from_now
    )

    Net::HTTP.stub(:post_form, ->(_uri, _params) { slack_nested_token_response }) do
      get mcp_oauth_callback_path, params: { state: flow.state, code: "auth-code" }
    end

    credential = McpOauthCredential.for_credential_key(@key_a).active.first
    assert credential, "credential stored from nested token"
    assert_equal "xoxp-user-tok", credential.access_token
  end

  # --- Manual (paste-back) mode ---

  def manual_client
    PreregisteredOauthConfig::OAuthClient.new(
      key: "slack",
      client_id: "1601185624273.8899143856786",
      authorization_endpoint: "https://slack.com/oauth/v2_user/authorize",
      token_endpoint: "https://slack.com/api/oauth.v2.user.access",
      scopes: "users:read",
      redirect_uri: "http://localhost:3118/callback",
      manual: true
    )
  end

  # A credentials entry naming a redirect Zimmer does not serve cannot be finished by
  # the hosted callback, whether or not it also sets `manual: true` — before, such an
  # entry redirected to a callback that could never come back.
  test "initiate renders the paste-back page for a pre-registered redirect with no manual flag" do
    client = PreregisteredOauthConfig::OAuthClient.new(
      key: "slack", client_id: "cid",
      authorization_endpoint: "https://slack.com/oauth/v2_user/authorize",
      token_endpoint: "https://slack.com/api/oauth.v2.user.access",
      redirect_uri: "http://localhost:3118/callback"
    )
    assert_not client.manual?, "fixture leaves the manual flag unset"

    PreregisteredOauthConfig.stubs(:find_for_server).returns(client)
    ServersConfig.stubs(:credential_config).returns({ type: "http", url: "https://mcp.slack.com/mcp" })

    post mcp_oauth_initiate_path, params: {
      session_id: @session.id, server_name: "slack", server_url: "https://mcp.slack.com/mcp"
    }

    assert_response :success
    assert_select "form[action=?]", mcp_oauth_complete_path

    flow = McpOauthPendingFlow.for_session(@session).find_by(server_name: "slack")
    assert flow.manual?, "flow marked manual from its redirect alone"
    assert_equal "http://localhost:3118/callback", flow.redirect_uri
  end

  # A credentials entry with no redirect at all keeps the hosted callback and the
  # automatic flow — the ordinary pre-registered case (e.g. BigQuery).
  test "initiate keeps the hosted callback for a pre-registered server with no redirect" do
    client = PreregisteredOauthConfig::OAuthClient.new(
      key: "bigquery-example", client_id: "cid", client_secret: "sec",
      authorization_endpoint: "https://accounts.google.com/o/oauth2/v2/auth",
      token_endpoint: "https://oauth2.googleapis.com/token"
    )
    PreregisteredOauthConfig.stubs(:find_for_server).returns(client)
    ServersConfig.stubs(:credential_config).returns({ type: "http", url: "https://bq.example.com/mcp" })

    post mcp_oauth_initiate_path, params: {
      session_id: @session.id, server_name: "bigquery-example", server_url: "https://bq.example.com/mcp"
    }

    assert_response :redirect
    flow = McpOauthPendingFlow.for_session(@session).find_by(server_name: "bigquery-example")
    assert_not flow.manual?
    assert_equal McpOauthService.new.build_redirect_uri, flow.redirect_uri
  end

  test "initiate renders the paste-back page for a manual-mode pre-registered server" do
    PreregisteredOauthConfig.stubs(:find_for_server).returns(manual_client)
    ServersConfig.stubs(:credential_config).returns({ type: "http", url: "https://mcp.slack.com/mcp" })

    post mcp_oauth_initiate_path, params: {
      session_id: @session.id, server_name: "slack", server_url: "https://mcp.slack.com/mcp"
    }

    assert_response :success
    assert_select "form[action=?]", mcp_oauth_complete_path
    assert_select "textarea#redirect_response"

    flow = McpOauthPendingFlow.for_session(@session).find_by(server_name: "slack")
    assert flow, "pending flow created"
    assert flow.manual?, "flow marked manual"
    assert_equal "http://localhost:3118/callback", flow.redirect_uri
  end

  test "complete finishes the exchange from a pasted redirect URL and stores the token" do
    flow = McpOauthPendingFlow.create!(
      session: @session, server_name: "slack", server_url: "https://mcp.slack.com/mcp",
      state: "slack-state", code_verifier: "v" * 43,
      authorization_endpoint: "https://slack.com/oauth/v2_user/authorize",
      token_endpoint: "https://slack.com/api/oauth.v2.user.access",
      client_id: "cid", redirect_uri: "http://localhost:3118/callback", manual: true,
      mcp_server_config: { "type" => "http", "url" => "https://mcp.slack.com/mcp", "headers" => {} },
      expires_at: 1.hour.from_now
    )

    captured = nil
    Net::HTTP.stub(:post_form, ->(_uri, params) { captured = params; slack_nested_token_response }) do
      post mcp_oauth_complete_path, params: {
        state: "slack-state",
        redirect_response: "http://localhost:3118/callback?code=real-code&state=slack-state"
      }
    end

    assert_response :redirect
    assert_equal "real-code", captured[:code]
    assert_equal "http://localhost:3118/callback", captured[:redirect_uri]
    assert_equal "v" * 43, captured[:code_verifier]

    credential = McpOauthCredential.for_credential_key(flow.credential_key).active.first
    assert credential, "credential stored via paste-back"
    assert_equal "xoxp-user-tok", credential.access_token
    assert_not McpOauthPendingFlow.exists?(flow.id), "pending flow cleaned up"
  end

  test "complete re-renders the paste-back page when the pasted value has no code" do
    flow = McpOauthPendingFlow.create!(
      session: @session, server_name: "slack", server_url: "https://mcp.slack.com/mcp",
      state: "slack-state-2", code_verifier: "v" * 43,
      authorization_endpoint: "https://slack.com/oauth/v2_user/authorize",
      token_endpoint: "https://slack.com/api/oauth.v2.user.access",
      client_id: "cid", redirect_uri: "http://localhost:3118/callback", manual: true,
      mcp_server_config: { "type" => "http", "url" => "https://mcp.slack.com/mcp", "headers" => {} },
      expires_at: 1.hour.from_now
    )

    post mcp_oauth_complete_path, params: {
      state: "slack-state-2",
      redirect_response: "http://localhost:3118/callback?state=slack-state-2"
    }

    assert_response :bad_request
    assert_select "textarea#redirect_response"
    assert McpOauthPendingFlow.exists?(flow.id), "flow preserved for retry"
  end

  test "complete rejects a pasted URL whose state does not match the flow" do
    McpOauthPendingFlow.create!(
      session: @session, server_name: "slack", server_url: "https://mcp.slack.com/mcp",
      state: "real-state", code_verifier: "v" * 43,
      authorization_endpoint: "https://slack.com/oauth/v2_user/authorize",
      token_endpoint: "https://slack.com/api/oauth.v2.user.access",
      client_id: "cid", redirect_uri: "http://localhost:3118/callback", manual: true,
      mcp_server_config: { "type" => "http", "url" => "https://mcp.slack.com/mcp", "headers" => {} },
      expires_at: 1.hour.from_now
    )

    post mcp_oauth_complete_path, params: {
      state: "real-state",
      redirect_response: "http://localhost:3118/callback?code=x&state=forged-state"
    }

    assert_response :bad_request
    assert_not McpOauthCredential.where(server_name: "slack").exists?
  end
end
