# frozen_string_literal: true

require "test_helper"

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
  # client id, not the `agent-orchestrator` placeholder that Slack rejects.
  test "initiate uses the catalog-configured client id in the authorize redirect" do
    configured_server = ServersConfig::Server.new("slack-reframe", {
      "type" => "streamable-http",
      "url" => "https://mcp.slack.com/mcp",
      "oauth" => { "clientId" => "1601185624273.8899143856786" }
    })

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

    ServersConfig.stub(:find, ->(name) { name == "slack-reframe" ? configured_server : nil }) do
      Net::HTTP.stub(:new, discovery_http) do
        post mcp_oauth_initiate_path, params: {
          session_id: @session.id,
          server_name: "slack-reframe",
          server_url: "https://mcp.slack.com/mcp"
        }
      end
    end

    assert_response :redirect
    location = URI(@response.headers["Location"])
    query = URI.decode_www_form(location.query).to_h
    assert_equal "1601185624273.8899143856786", query["client_id"]
    assert_not_equal "agent-orchestrator", query["client_id"]

    pending = McpOauthPendingFlow.for_session(@session).find_by(server_name: "slack-reframe")
    assert_equal "1601185624273.8899143856786", pending.client_id
  end
end
