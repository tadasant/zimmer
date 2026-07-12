# frozen_string_literal: true

require "test_helper"


class Mcp::Tools::QuickSearchSessionsTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::QuickSearchSessions.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  test "id returns the single matching session" do
    session = sessions(:router_child_running)

    output = @tool.call("id" => session.id)

    assert_includes output, "## Session Found"
    assert_includes output, "### Configure Hatchbox deployment (ID: #{session.id})"
    assert_includes output, "- **Status:** running"
    assert_includes output, "- **Agent Runtime:** claude_code"
  end

  test "unknown id raises a tool error" do
    error = assert_raises(Mcp::ToolError) { @tool.call("id" => 999_999) }
    assert_match(/Session not found/, error.message)
  end

  test "query matches on title" do
    output = @tool.call("query" => "Configure Hatchbox deployment")

    assert_includes output, "## Agent Sessions"
    assert_includes output, "Found 1 session(s) (page 1 of 1):"
    assert_includes output, "### Configure Hatchbox deployment (ID: #{sessions(:router_child_running).id})"
  end

  test "archived sessions are excluded unless show_archived" do
    assert_equal "No sessions found matching the specified criteria.",
      @tool.call("query" => "Research deployment options")

    output = @tool.call("query" => "Research deployment options", "show_archived" => true)
    assert_includes output, "### Research deployment options (ID: #{sessions(:router_child_archived).id})"
  end

  test "status filter and pagination footer" do
    output = @tool.call("status" => "running", "per_page" => 1)

    assert_includes output, "- **Status:** running"
    assert_includes output, "*More sessions available. Use page=2 to see the next page.*"
  end

  test "invalid status raises a tool error" do
    error = assert_raises(Mcp::ToolError) { @tool.call("status" => "bogus") }
    assert_match(/Invalid status/, error.message)
  end

  test "prompt preview is truncated" do
    session = sessions(:running)
    session.update!(prompt: "x" * 150)

    output = @tool.call("id" => session.id)

    assert_includes output, "- **Prompt:** #{'x' * 100}..."
  end
end
