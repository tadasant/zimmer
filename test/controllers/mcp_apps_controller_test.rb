# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class McpAppsControllerTest < ActionDispatch::IntegrationTest
  TRANSCRIPT = [
    { "type" => "assistant", "message" => { "role" => "assistant", "content" => [
      { "type" => "tool_use", "id" => "toolu_01", "name" => "mcp__notion__open_panel", "input" => { "note" => "hi" } }
    ] }, "timestamp" => "2026-09-11T12:00:01Z" },
    { "type" => "user", "message" => { "role" => "user", "content" => [
      { "type" => "tool_result", "tool_use_id" => "toolu_01",
        "content" => [ { "type" => "text", "text" => '{"time":"12:00:02"}' } ] }
    ] }, "timestamp" => "2026-09-11T12:00:02Z" }
  ].freeze

  TOOLS = [
    { "name" => "open_panel", "_meta" => { "ui" => { "resourceUri" => "ui://demo/panel.html" } } },
    { "name" => "roll_dice", "_meta" => { "ui" => { "visibility" => [ "app" ] } } }
  ].freeze

  FRAGMENT_HTML = "<!DOCTYPE html><html><body><script>parent.postMessage({},'*')</script></body></html>"

  setup do
    @session = Session.create!(
      agent_runtime: "claude_code",
      prompt: "render a panel",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      status: :needs_input,
      mcp_servers: [ "notion" ],
      transcript: TRANSCRIPT.map(&:to_json).join("\n")
    )
    AppSetting.create!(mcp_apps_enabled: true, mcp_apps_allowed_servers: [ "notion" ])
    stub_mcp_server
  end

  # Every action resolves its own McpApps::ServerConnection, so the client is
  # stubbed at the class the connection builds rather than on one instance.
  def stub_mcp_server(csp: { "resourceDomains" => [ "https://unpkg.com" ] })
    @client = mock("client")
    @client.stubs(:tools_list).returns(TOOLS)
    @client.stubs(:resources_read).with("ui://demo/panel.html").returns({
      "contents" => [ {
        "uri" => "ui://demo/panel.html",
        "mimeType" => "text/html;profile=mcp-app",
        "text" => FRAGMENT_HTML,
        "_meta" => { "ui" => { "csp" => csp } }
      } ]
    })
    McpApps::ServerConnection.any_instance.stubs(:client).returns(@client)
  end

  def panel_params(index: 0)
    { transcript_index: index }
  end

  test "the panel renders the fragment frame at the agent's own tool call" do
    get session_mcp_app_path(@session, "toolu_01"), params: panel_params

    assert_response :success
    assert_match "turbo-frame", response.body
    assert_match "mcp-app-host", response.body
    assert_match fragment_session_mcp_app_path(@session, "toolu_01", transcript_index: 0), response.body
    assert_match "ui://demo/panel.html", response.body
    # The result already in the transcript is what feeds the view; nothing calls
    # the tool again.
    assert_match "12:00:02", response.body
  end

  test "the fragment is served under a CSP built from the resource's own metadata" do
    get fragment_session_mcp_app_path(@session, "toolu_01"), params: panel_params

    assert_response :success
    csp = response.headers["Content-Security-Policy"]

    assert_includes csp, "default-src 'none'"
    assert_includes csp, "sandbox allow-scripts"
    refute_includes csp, "allow-same-origin"
    assert_includes csp, "https://unpkg.com"
    assert_includes csp, "connect-src 'none'"
    assert_includes csp, "frame-ancestors 'self'"
    assert_equal "nosniff", response.headers["X-Content-Type-Options"]
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal FRAGMENT_HTML, response.body
  end

  test "a resource that declares no CSP still gets the restrictive default" do
    stub_mcp_server(csp: nil)
    @client.stubs(:resources_list).returns([])

    get fragment_session_mcp_app_path(@session, "toolu_01"), params: panel_params

    assert_response :success
    assert_includes response.headers["Content-Security-Policy"], "connect-src 'none'"
    refute_includes response.headers["Content-Security-Policy"], "unpkg"
  end

  test "nothing resolves while the feature is off, and the transcript is not even read" do
    AppSetting.current.update!(mcp_apps_enabled: false)
    # The gate is ahead of the transcript parse on purpose: a URL anyone can
    # request must not make a deployment with the feature off detoast and
    # normalize a multi-megabyte transcript column.
    McpApps::TranscriptToolCall.any_instance.expects(:found?).never

    get session_mcp_app_path(@session, "toolu_01"), params: panel_params
    assert_response :not_found

    get fragment_session_mcp_app_path(@session, "toolu_01"), params: panel_params
    assert_response :not_found

    post rpc_session_mcp_app_path(@session, "toolu_01", transcript_index: 0),
      params: { method_name: "tools/call", params: { name: "roll_dice" } }, as: :json
    assert_response :not_found

    post message_session_mcp_app_path(@session, "toolu_01", transcript_index: 0),
      params: { text: "hi", kind: "message" }, as: :json
    assert_response :not_found
  end

  test "a view that floods the proxy is throttled rather than forwarded" do
    McpApps::RequestThrottle.expects(:allow?).with(@session, "rpc").returns(false)
    @client.expects(:call_tool).never

    post rpc_session_mcp_app_path(@session, "toolu_01", transcript_index: 0),
      params: { method_name: "tools/call", params: { name: "roll_dice" } }, as: :json

    assert_response :success
    assert_match "faster than Zimmer will forward", response.parsed_body.dig("error", "message")
  end

  test "a view that floods the agent is throttled rather than delivered" do
    McpApps::RequestThrottle.expects(:allow?).with(@session, "message").returns(false)
    AgentSessionJob.expects(:enqueue_with_prompt).never

    post message_session_mcp_app_path(@session, "toolu_01", transcript_index: 0),
      params: { text: "roll again", kind: "message" }, as: :json

    assert_response :too_many_requests
  end

  test "nothing resolves for a server nobody opted in" do
    AppSetting.current.update!(mcp_apps_allowed_servers: [])

    get fragment_session_mcp_app_path(@session, "toolu_01"), params: panel_params
    assert_response :not_found
  end

  test "a tool call that is not where the URL claims is a 404" do
    get fragment_session_mcp_app_path(@session, "toolu_01"), params: panel_params(index: 1)
    assert_response :not_found

    get fragment_session_mcp_app_path(@session, "toolu_does_not_exist"), params: panel_params
    assert_response :not_found
  end

  test "the proxy forwards an app-callable tool call" do
    @client.expects(:call_tool).with("roll_dice", {}).returns({ "content" => [ { "type" => "text", "text" => "4" } ] })

    post rpc_session_mcp_app_path(@session, "toolu_01", transcript_index: 0),
      params: { method_name: "tools/call", params: { name: "roll_dice", arguments: {} } }, as: :json

    assert_response :success
    assert_equal "4", response.parsed_body.dig("result", "content", 0, "text")
  end

  test "the proxy refuses a tool the server did not mark app-callable" do
    @client.expects(:call_tool).never

    post rpc_session_mcp_app_path(@session, "toolu_01", transcript_index: 0),
      params: { method_name: "tools/call", params: { name: "open_panel" } }, as: :json

    assert_response :success
    assert_equal McpApps::Proxy::METHOD_NOT_FOUND, response.parsed_body.dig("error", "code")
  end

  test "a widget message becomes an agent turn" do
    AgentSessionJob.expects(:enqueue_with_prompt).once.returns(stub(job_id: "job-1"))
    BroadcastService.any_instance.stubs(:optimistic_user_message)

    post message_session_mcp_app_path(@session, "toolu_01", transcript_index: 0),
      params: { text: "roll again", kind: "message" }, as: :json

    assert_response :success
    assert_equal "delivered", response.parsed_body["status"]
    assert @session.reload.waiting?
  end

  test "a widget message Zimmer cannot deliver answers with a reason" do
    @session.update!(status: :archived)

    post message_session_mcp_app_path(@session, "toolu_01", transcript_index: 0),
      params: { text: "roll again", kind: "message" }, as: :json

    assert_response :unprocessable_entity
    assert_equal "rejected", response.parsed_body["status"]
  end
end
