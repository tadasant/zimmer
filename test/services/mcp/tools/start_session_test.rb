# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::StartSessionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tool = Mcp::Tools::StartSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
    @root = AgentRootsConfig.find!("zimmer")
  end

  test "creates a session from an agent root and queues the agent job" do
    result = nil

    assert_difference "Session.count", 1 do
      assert_enqueued_with(job: AgentSessionJob) do
        result = @tool.call("agent_root" => "zimmer", "prompt" => "Fix the thing", "title" => "Fix the thing")
      end
    end

    session = Session.order(:id).last
    assert_equal "zimmer", session.metadata["agent_root_key"]
    assert_equal @root.url, session.git_root
    assert_equal @root.default_mcp_servers || [], session.mcp_servers
    assert session.config["model"].present?
    assert session.job_id.present?

    assert_includes result, "## Session Started Successfully"
    assert_includes result, "- **ID:** #{session.id}"
    assert_includes result, "- **Job ID:** #{session.job_id}"
    assert_includes result, "The agent job has been queued"
  end

  test "creates a clone-only session when no prompt is given" do
    result = @tool.call("agent_root" => "zimmer", "title" => "Clone only")

    session = Session.order(:id).last
    assert_nil session.job_id
    assert_includes result, "No prompt was provided"
  end

  test "resolves a goal id to its catalog description" do
    @tool.call("agent_root" => "zimmer", "title" => "Goal test", "goal" => "codebase-question")

    session = Session.order(:id).last
    assert_equal GoalsConfig.find("codebase-question").description, session.goal
  end

  test "explicit skills and mcp_servers override the root defaults" do
    @tool.call(
      "agent_root" => "zimmer",
      "title" => "Explicit config",
      "mcp_servers" => [ "context7" ],
      "config" => { "model" => "sonnet" }
    )

    session = Session.order(:id).last
    assert_equal [ "context7" ], session.mcp_servers
    assert_equal "sonnet", session.config["model"]
  end

  test "raises for an unknown agent root" do
    error = assert_raises(Mcp::ToolError) { @tool.call("agent_root" => "nope", "title" => "x") }
    assert_match(/Invalid agent_root/, error.message)
  end

  test "raises when a required attribute is missing" do
    assert_raises(ActiveRecord::RecordInvalid) { @tool.call("title" => "No root, no git_root") }
  end

  test "a restricted connection requires an allowed agent root" do
    tool = restricted_tool

    missing = assert_raises(Mcp::ToolError) { tool.call("title" => "x") }
    assert_match(/agent_root is required/, missing.message)

    forbidden = assert_raises(Mcp::ToolError) { tool.call("agent_root" => "general-agent", "title" => "x") }
    assert_match(/not permitted/, forbidden.message)
  end

  test "a restricted connection must use the root's exact default mcp servers" do
    error = assert_raises(Mcp::ToolError) do
      restricted_tool.call("agent_root" => "zimmer", "title" => "x", "mcp_servers" => [ "context7" ])
    end

    assert_match(/must use its exact default MCP servers/, error.message)
  end

  test "a restricted connection succeeds with the root's default mcp servers" do
    result = restricted_tool.call(
      "agent_root" => "zimmer",
      "title" => "Allowed spawn",
      "mcp_servers" => @root.default_mcp_servers || []
    )

    assert_includes result, "## Session Started Successfully"
  end

  private

  def restricted_tool
    Mcp::Tools::StartSession.new(
      context: Mcp::Context.new(tool_groups: "sessions", allowed_agent_roots: "zimmer")
    )
  end
end
