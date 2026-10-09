# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# quick_router is the Quick Router flow reached over MCP: the same prompt
# composition, the same router root, the same create call. What it must not do
# is attribute anything to a human, or let a fenced connection out of its fence.
class Mcp::Tools::QuickRouterTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def tool(**context)
    Mcp::Tools::QuickRouter.new(context: Mcp::Context.new(tool_groups: "sessions", **context))
  end

  test "starts a router session on the router root and queues it" do
    result = nil
    assert_difference "Session.count", 1 do
      assert_enqueued_with(job: AgentSessionJob) do
        result = tool.call("prompt" => "Is there a WhatsApp server?")
      end
    end

    session = Session.order(:id).last
    assert_equal AgentRootsConfig.router_root_name, session.metadata["agent_root_key"]
    assert_equal "Is there a WhatsApp server?", session.prompt
    assert_equal Mcp::Tools::QuickRouter::SOURCE, session.metadata["source"]
    assert_equal "Is there a WhatsApp server?", session.metadata["original_prompt"]
    assert_equal "api_key", session.metadata["mcp_auth"]

    assert_includes result, "- **ID:** #{session.id}"
    assert_includes result, "/sessions/#{session.id}"
    assert_includes result, "Call `get_session` with id `#{session.id}`"
  end

  # The arguments are written by the calling model, whoever authenticated it.
  test "records no human message, on an API key or an OAuth grant" do
    assert_no_difference "HumanMessage.count" do
      tool.call("prompt" => "from an agent")
      tool(oauth_grant_id: 42).call("prompt" => "from Claude.ai")
    end
  end

  test "context is wrapped in the same data block the chat bubble uses, and the ask goes last" do
    tool.call("prompt" => "summarize this", "context" => "PAGE TEXT", "context_url" => "https://example.com/doc")

    session = Session.order(:id).last
    assert session.prompt.start_with?(QuickRouterPrompt::OPEN_TAG)
    assert_includes session.prompt, "URL: https://example.com/doc"
    assert_includes session.prompt, "PAGE TEXT"
    assert session.prompt.end_with?("\n\nsummarize this")
    assert_equal "summarize this", session.metadata["original_prompt"]
    assert_equal "https://example.com/doc", session.metadata["current_url"]
  end

  test "a parentless API-key call is classified like a parentless start_session" do
    tool.call("prompt" => "hello")

    session = Session.order(:id).last
    assert_equal SessionGenesis::API, session.genesis
    assert_nil session.parent_session_id
    assert_nil session[:scheduling_class]
  end

  test "a call from a session's own connection becomes that session's child and inherits its genesis" do
    parent = Session.create!(agent_runtime: "claude_code", prompt: "p", git_root: "https://github.com/test/repo.git",
                             branch: "main", genesis: SessionGenesis::SLACK)

    tool(session_id: parent.id).call("prompt" => "route this")

    session = Session.order(:id).last
    assert_equal parent.id, session.parent_session_id
    assert_equal SessionGenesis::SLACK, session.genesis
  end

  test "an OAuth caller defaults to priority, and an explicit class wins on either credential" do
    tool(oauth_grant_id: 7).call("prompt" => "a person is waiting")
    session = Session.order(:id).last
    assert_equal SessionGenesis::PRIORITY, session[:scheduling_class]
    assert_equal "oauth", session.metadata["mcp_auth"]
    assert_equal 7, session.metadata["oauth_grant_id"]

    tool(oauth_grant_id: 7).call("prompt" => "no rush", "scheduling_class" => "spot")
    assert_equal SessionGenesis::SPOT, Session.order(:id).last[:scheduling_class]

    tool.call("prompt" => "now please", "scheduling_class" => "priority")
    assert_equal SessionGenesis::PRIORITY, Session.order(:id).last[:scheduling_class]
  end

  test "refuses an unknown scheduling class" do
    error = assert_raises(Mcp::ToolError) { tool.call("prompt" => "x", "scheduling_class" => "urgent") }
    assert_includes error.message, "scheduling_class must be one of"
  end

  test "refuses a blank or over-long prompt, and context that pushes it over" do
    assert_raises(Mcp::ToolError) { tool.call("prompt" => "   ") }
    assert_raises(Mcp::ToolError) { tool.call("prompt" => "a" * (Session::PROMPT_MAX_LENGTH + 1)) }

    error = assert_raises(Mcp::ToolError) do
      tool.call("prompt" => "a" * (Session::PROMPT_MAX_LENGTH - 10), "context" => "page")
    end
    assert_includes error.message, "send less context"
  end

  # The router can start work on any root, so on a fenced connection it would
  # be a way around the fence.
  test "a restricted connection is refused unless the router root is on its allowlist" do
    assert_no_difference "Session.count" do
      error = assert_raises(Mcp::ToolError) { tool(allowed_agent_roots: "zimmer").call("prompt" => "x") }
      assert_includes error.message, "is not permitted"
    end

    assert_difference "Session.count", 1 do
      tool(allowed_agent_roots: "zimmer,#{AgentRootsConfig.router_root_name}").call("prompt" => "x")
    end
  end

  test "an idempotency_key replays the first call's session instead of starting another router" do
    first = nil
    assert_difference "Session.count", 1 do
      first = tool.call("prompt" => "do it", "idempotency_key" => "claude-ai-turn-1")
      tool.call("prompt" => "do it", "idempotency_key" => "claude-ai-turn-1")
    end
    session = Session.order(:id).last
    assert_equal "claude-ai-turn-1", session.idempotency_key
    assert_includes first, "- **ID:** #{session.id}"

    replay = tool.call("prompt" => "do it", "idempotency_key" => "claude-ai-turn-1")
    assert_includes replay, "Existing Quick Router session returned"
    assert_includes replay, "- **ID:** #{session.id}"
  end

  # One request, a chain of routers: a router routes with start_session.
  test "a Quick Router session calling it is refused" do
    tool.call("prompt" => "outer")
    router = Session.order(:id).last

    assert_no_difference "Session.count" do
      error = assert_raises(Mcp::ToolError) { tool(session_id: router.id).call("prompt" => "inner") }
      assert_includes error.message, "Route the request with `start_session`"
    end
  end

  test "says so when the catalog has no router root" do
    Session.stubs(:create_from_agent_root!).raises(AgentRootsConfig::AgentRootNotFoundError, "zimmer-orchestrator")

    error = assert_raises(Mcp::ToolError) { tool.call("prompt" => "x") }
    assert_includes error.message, "Router agent root not configured"
  end
end
