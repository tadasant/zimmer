# frozen_string_literal: true

require "test_helper"

class McpApps::TranscriptToolCallTest < ActiveSupport::TestCase
  # A Claude Code transcript in which the agent calls an MCP tool and gets a
  # result back — the exact shape this feature triggers on.
  TRANSCRIPT = [
    { "type" => "user", "message" => { "role" => "user", "content" => "show me the panel" },
      "timestamp" => "2026-09-11T12:00:00Z" },
    { "type" => "assistant", "message" => { "role" => "assistant", "content" => [
      { "type" => "tool_use", "id" => "toolu_01", "name" => "mcp__notion__open_panel",
        "input" => { "note" => "hello" } }
    ] }, "timestamp" => "2026-09-11T12:00:01Z" },
    { "type" => "user", "message" => { "role" => "user", "content" => [
      { "type" => "tool_result", "tool_use_id" => "toolu_01",
        "content" => [ { "type" => "text", "text" => '{"time":"12:00:02"}' } ] }
    ] }, "timestamp" => "2026-09-11T12:00:02Z" }
  ].freeze

  setup do
    @session = Session.create!(
      agent_runtime: "claude_code",
      prompt: "render an app",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      mcp_servers: [ "notion" ],
      transcript: TRANSCRIPT.map(&:to_json).join("\n")
    )
  end

  def locate(tool_call_id: "toolu_01", transcript_index: 1)
    McpApps::TranscriptToolCall.new(
      session: @session, tool_call_id: tool_call_id, transcript_index: transcript_index
    )
  end

  test "finds the agent's own call and reads its server and tool" do
    call = locate

    assert call.found?
    assert_equal "notion", call.server_name
    assert_equal "open_panel", call.tool
    assert_equal({ "note" => "hello" }, call.arguments)
  end

  test "feeds the view the result the call already returned, as a CallToolResult" do
    result = locate.result

    assert_equal [ { "type" => "text", "text" => '{"time":"12:00:02"}' } ], result["content"]
    assert_equal false, result["isError"]
    assert_equal({ "time" => "12:00:02" }, result["structuredContent"])
  end

  test "a call whose result has not landed yet has no result rather than an empty one" do
    @session.update!(transcript: TRANSCRIPT.first(2).map(&:to_json).join("\n"))

    call = locate
    assert call.found?
    assert_nil call.result
  end

  test "the transcript index in the URL is verified, not trusted" do
    refute locate(transcript_index: 2).found?
    refute locate(transcript_index: 0).found?
    refute locate(transcript_index: -1).found?
  end

  test "an unknown tool call id resolves to nothing" do
    refute locate(tool_call_id: "toolu_does_not_exist").found?
  end

  test "a tool on a server this session does not have is not an MCP App call" do
    @session.update!(mcp_servers: [ "context7" ])

    call = locate
    assert call.found?
    assert_nil call.server_name
  end

  test "a plain non-MCP tool call names no server" do
    @session.update!(transcript: [
      TRANSCRIPT[0],
      { "type" => "assistant", "message" => { "role" => "assistant", "content" => [
        { "type" => "tool_use", "id" => "toolu_01", "name" => "Bash", "input" => { "command" => "ls" } }
      ] }, "timestamp" => "2026-09-11T12:00:01Z" }
    ].map(&:to_json).join("\n"))

    assert_nil locate.server_name
  end
end
