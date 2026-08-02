# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Which entry points may create an uncle edge, and which structurally cannot.
#
# The rule this pins: a HUMAN is never an uncle. A person clicking "Send Now" in
# the browser has no session on the other end, and the way that is guaranteed is
# that the web UI controllers have no way to declare one — not a flag they are
# trusted to set correctly.
class UncleEdgeEntryPointsTest < ActionDispatch::IntegrationTest
  setup do
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)

    @target = sessions(:needs_input)
    @actor = Session.create!(
      agent_runtime: "claude_code",
      prompt: "router work",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      title: "Acting router"
    )
    SessionUncleLink.delete_all

    @previous_api_keys = ENV["API_KEYS"]
    ENV["API_KEYS"] = "test_api_key_12345"
  end

  teardown do
    ENV["API_KEYS"] = @previous_api_keys
    Mocha::Mockery.instance.teardown
  end

  def api_headers
    { "X-API-Key" => "test_api_key_12345" }
  end

  def edge?
    SessionUncleLink.exists?(session_id: @target.id, uncle_session_id: @actor.id)
  end

  # --- The web UI is the human path: no edge, ever ---------------------------

  test "a human queueing a message from the web UI creates no uncle edge" do
    post session_enqueued_messages_url(@target), params: { content: "from a person" }

    assert_equal 0, SessionUncleLink.count
  end

  # The declaration is not merely ignored on this path — the controller never
  # reads it, so a forged parameter cannot smuggle an edge in through the browser.
  test "the web UI ignores an acting_session_id even if one is supplied" do
    post session_enqueued_messages_url(@target),
         params: { content: "from a person", acting_session_id: @actor.id }

    assert_equal 0, SessionUncleLink.count
  end

  # --- REST: self-declared, opt-in -------------------------------------------

  test "a REST follow_up with acting_session_id records an uncle edge" do
    post follow_up_api_v1_session_url(@target),
         params: { prompt: "redirect", acting_session_id: @actor.id },
         headers: api_headers,
         as: :json

    assert_response :success
    assert edge?, "expected an uncle edge from the declared caller"
  end

  test "a REST follow_up without acting_session_id records nothing" do
    post follow_up_api_v1_session_url(@target),
         params: { prompt: "redirect" },
         headers: api_headers,
         as: :json

    assert_response :success
    assert_equal 0, SessionUncleLink.count
  end

  test "a REST enqueued message create with acting_session_id records an uncle edge" do
    post api_v1_session_enqueued_messages_url(@target),
         params: { content: "queued by a session", acting_session_id: @actor.id },
         headers: api_headers,
         as: :json

    assert_response :created
    assert edge?
  end

  # An edge is a record ABOUT a delivery, never a precondition of it.
  test "a REST follow_up still succeeds when the declared caller does not exist" do
    post follow_up_api_v1_session_url(@target),
         params: { prompt: "redirect", acting_session_id: 999_999_999 },
         headers: api_headers,
         as: :json

    assert_response :success
    assert_equal 0, SessionUncleLink.count
  end

  test "a rejected REST follow_up records no edge" do
    @target.update_column(:status, "archived")

    post follow_up_api_v1_session_url(@target),
         params: { prompt: "redirect", acting_session_id: @actor.id },
         headers: api_headers,
         as: :json

    assert_response :unprocessable_entity
    assert_equal 0, SessionUncleLink.count
  end

  # --- MCP: the same declaration, the same rules -----------------------------

  test "an MCP follow_up with acting_session_id records an uncle edge" do
    tool = Mcp::Tools::ActionSession.new(context: Mcp::Context.new(tool_groups: "sessions"))

    tool.call("session_id" => @target.id, "action" => "follow_up",
              "prompt" => "redirect", "acting_session_id" => @actor.id)

    assert edge?
  end

  test "an MCP follow_up without acting_session_id records nothing" do
    tool = Mcp::Tools::ActionSession.new(context: Mcp::Context.new(tool_groups: "sessions"))

    tool.call("session_id" => @target.id, "action" => "follow_up", "prompt" => "redirect")

    assert_equal 0, SessionUncleLink.count
  end

  test "an MCP enqueue with acting_session_id records an uncle edge" do
    tool = Mcp::Tools::ManageEnqueuedMessages.new(context: Mcp::Context.new(tool_groups: "sessions"))

    tool.call("session_id" => @target.id, "action" => "create",
              "content" => "queued", "acting_session_id" => @actor.id)

    assert edge?
  end

  test "an MCP follow_up a session sends to itself records nothing" do
    tool = Mcp::Tools::ActionSession.new(context: Mcp::Context.new(tool_groups: "sessions"))

    tool.call("session_id" => @target.id, "action" => "follow_up",
              "prompt" => "note to self", "acting_session_id" => @target.id)

    assert_equal 0, SessionUncleLink.count
  end

  # The whole point of the edge, end to end: after it exists, the target's
  # hierarchy contains the caller and the caller's hierarchy contains the target.
  test "an edge recorded over MCP shows up in the hierarchy both ways" do
    tool = Mcp::Tools::ActionSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
    tool.call("session_id" => @target.id, "action" => "follow_up",
              "prompt" => "redirect", "acting_session_id" => @actor.id)

    assert_includes SessionHierarchy.new(@target.reload).session_ids, @actor.id
    assert_includes SessionHierarchy.new(@actor.reload).session_ids, @target.id

    node = SessionHierarchy.new(@target).nodes.find { |n| n.id == @target.id }
    assert_equal [ @actor.id ], node.uncles
  end
end
