# frozen_string_literal: true

require "test_helper"

# `start_session` over the real POST /mcp endpoint, for the rootless spawn path
# added in zimmer#265: a repository named by URL rather than by catalog root.
#
# Driven end to end rather than through the tool object because the two halves
# that matter are connection-level. The scoping this fence reads
# (`allowed_agent_roots`) arrives as a query parameter on the endpoint, and the
# refusals have to come back as tool errors an agent can read — not as a 500, and
# not as the bare `Git root can't be blank` the model used to raise.
class McpRootlessSpawnTest < ActionDispatch::IntegrationTest
  setup do
    @api_key = "test_api_key_12345"
    ENV["API_KEYS"] = @api_key
    @headers = {
      "X-API-Key" => @api_key,
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream"
    }
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  test "a bare git_root spawns a session, with runtime and model from the global defaults" do
    AppSetting.delete_all
    AppSetting.create!(default_runtime: "codex", default_model: "gpt-5.4")

    assert_difference "Session.count", 1 do
      @body = call_start_session({
        "git_root" => "https://github.com/someone/scratch.git",
        "branch" => "trunk",
        "prompt" => "Look at the fork",
        "title" => "Rootless over MCP"
      })
    end

    session = Session.find_by!(title: "Rootless over MCP")
    assert_equal "https://github.com/someone/scratch.git", session.git_root
    assert_equal "trunk", session.branch
    assert_equal "codex", session.agent_runtime
    assert_equal "gpt-5.4", session.config["model"]
    assert_includes text_of(@body), "## Session Started Successfully"
  end

  # The schema an agent actually reads is the one the endpoint renders, not the
  # constant in the class — so the round trip is what pins the new arguments.
  test "tools/list advertises the repository arguments" do
    post "/mcp?tool_groups=sessions",
      params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
      headers: @headers
    assert_response :success

    tool = JSON.parse(response.body).dig("result", "tools").find { |t| t["name"] == "start_session" }
    properties = tool.dig("inputSchema", "properties")

    %w[git_root branch subdirectory].each do |param|
      assert properties.key?(param), "#{param} must reach the caller through tools/list"
    end
    assert_includes properties.dig("git_root", "description"), "Either this or `agent_root` is required"
  end

  test "naming neither agent_root nor git_root is a readable tool error" do
    assert_no_difference "Session.count" do
      @body = call_start_session({ "title" => "Nothing to clone" })
    end

    assert tool_error?(@body), "the call must come back as a tool error: #{@body.inspect}"
    message = error_text(@body)
    assert_includes message, "Name a target repository"
    assert_includes message, "`git_root`"
    refute_includes message, "Git root can't be blank",
      "the bare RecordInvalid naming a field the schema does not have is the #265 defect"
  end

  test "a connection restricted to specific agent roots cannot spawn from a git_root" do
    assert_no_difference "Session.count" do
      @body = call_start_session(
        { "git_root" => "https://github.com/someone/anything.git", "title" => "Fenced out" },
        query: "?tool_groups=sessions&allowed_agent_roots=zimmer"
      )
    end

    assert tool_error?(@body), "the call must come back as a tool error: #{@body.inspect}"
    assert_includes error_text(@body), "\"git_root\" is not allowed"
  end

  test "a restricted connection cannot point an allowed root at another repository" do
    assert_no_difference "Session.count" do
      @body = call_start_session(
        {
          "agent_root" => "zimmer",
          "git_root" => "https://github.com/someone/anything.git",
          "title" => "Fenced out"
        },
        query: "?tool_groups=sessions&allowed_agent_roots=zimmer"
      )
    end

    assert tool_error?(@body), "the call must come back as a tool error: #{@body.inspect}"
    assert_includes error_text(@body), "\"git_root\" is not allowed"
  end

  private

  def call_start_session(arguments, query: "?tool_groups=sessions")
    post "/mcp#{query}",
      params: { jsonrpc: "2.0", id: 1, method: "tools/call",
                params: { "name" => "start_session", "arguments" => arguments } }.to_json,
      headers: @headers
    assert_response :success
    JSON.parse(response.body)
  end

  def text_of(body)
    refute tool_error?(body), "tool call errored: #{body.inspect}"
    body["result"]["content"].first["text"]
  end

  def tool_error?(body)
    body["result"]&.dig("isError") || body.key?("error")
  end

  def error_text(body)
    body.dig("result", "content")&.first&.dig("text") || body.dig("error", "message").to_s
  end
end
