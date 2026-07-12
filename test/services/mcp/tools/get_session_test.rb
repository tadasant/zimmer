# frozen_string_literal: true

require "test_helper"


class Mcp::Tools::GetSessionTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::GetSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  test "returns session details and the transcript file hint instead of the transcript" do
    session = sessions(:archived)

    output = @tool.call("id" => session.id)

    assert_includes output, "## Session: #{session.title}"
    assert_includes output, "- **ID:** #{session.id}"
    assert_includes output, "- **Status:** archived"
    assert_includes output, "### Transcript File"
    assert_includes output, "`~/.claude/projects/*/#{session.session_id}.jsonl`"
    refute_includes output, "I've completed the task for you."
  end

  test "include_transcript inlines the raw transcript and drops the file hint" do
    session = sessions(:archived)

    output = @tool.call("id" => session.id, "include_transcript" => true)

    assert_includes output, "### Transcript"
    assert_includes output, "I've completed the task for you."
    refute_includes output, "### Transcript File"
  end

  test "transcript_format renders the formatted transcript" do
    session = sessions(:archived)

    output = @tool.call("id" => session.id, "include_transcript" => true, "transcript_format" => "text")

    assert_includes output, "--- User ---"
    assert_includes output, "--- Assistant ---"
    assert_includes output, "I've completed the task for you."
  end

  test "transcript_format raises when there is no transcript" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("id" => sessions(:running).id, "include_transcript" => true, "transcript_format" => "json")
    end
    assert_match(/No transcript available/, error.message)
  end

  test "include_logs paginates the session logs" do
    session = sessions(:running)

    output = @tool.call("id" => session.id, "include_logs" => true)

    assert_includes output, "### Logs (#{session.logs.count} total, page 1 of 1)"
    assert_includes output, "**[INFO]**"
    assert_includes output, "Agent started successfully"

    paged = @tool.call("id" => session.id, "include_logs" => true, "logs_per_page" => 1)
    assert_includes paged, "*More logs available. Use logs_page=2 to see the next page.*"
  end

  test "include_subagent_transcripts reports an empty list" do
    output = @tool.call("id" => sessions(:running).id, "include_subagent_transcripts" => true)

    assert_includes output, "### Subagent Transcripts (0 total, page 1 of 0)"
    assert_includes output, "No subagent transcripts found."
  end

  test "session can be addressed by slug" do
    session = sessions(:running)
    session.update!(slug: "mcp-get-session-slug")

    output = @tool.call("id" => "mcp-get-session-slug")

    assert_includes output, "- **ID:** #{session.id}"
    assert_includes output, "- **Slug:** mcp-get-session-slug"
  end

  test "missing session raises a tool error" do
    assert_raises(Mcp::ToolError) { @tool.call("id" => 999_999) }
    assert_raises(Mcp::ToolError) { @tool.call({}) }
  end
end
