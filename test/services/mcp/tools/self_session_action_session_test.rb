# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::SelfSessionActionSessionTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::SelfSessionActionSession.new(context: Mcp::Context.new(tool_groups: "self_session"))
  end

  test "keeps the action_session name but exposes only the self-management actions" do
    definition = Mcp::Tools::SelfSessionActionSession.to_h
    schema = definition[:inputSchema]

    assert_equal "action_session", definition[:name]
    assert_equal %w[update_notes update_title set_heartbeat archive], schema[:properties][:action][:enum]
    assert_equal %w[session_id action], schema[:required]
    assert_match(/self-management/, definition[:description])
  end

  test "refuses an action outside the self-management subset" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "follow_up", "session_id" => sessions(:needs_input).id, "prompt" => "hi")
    end

    assert_match(/Unknown action "follow_up"/, error.message)
    assert_equal "needs_input", sessions(:needs_input).reload.status
  end

  test "archives the session" do
    session = sessions(:needs_input)

    result = @tool.call("action" => "archive", "session_id" => session.id)

    assert_includes result, "## Session Archived"
    assert_equal "archived", session.reload.status
  end

  test "names the self-session server as the surface, and the session when it declares itself" do
    session = sessions(:needs_input)

    @tool.call("action" => "archive", "session_id" => session.id, "acting_session_id" => session.id)

    line = session.reload.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_equal "[State Machine] Session moved to trash by session ##{session.id} via the self-session MCP server", line
  end

  test "does not claim a self-archive when the caller did not declare itself" do
    session = sessions(:needs_input)

    @tool.call("action" => "archive", "session_id" => session.id)

    line = session.reload.logs.where("content LIKE ?", "%Session moved to trash%").sole.content
    assert_equal "[State Machine] Session moved to trash by an undeclared self-session MCP server caller", line
  end

  test "updates notes, title, and the heartbeat" do
    session = sessions(:needs_input)

    assert_includes @tool.call("action" => "update_notes", "session_id" => session.id, "session_notes" => "Progress"), "## Session Notes Updated"
    assert_equal "Progress", session.reload.session_notes

    assert_includes @tool.call("action" => "update_title", "session_id" => session.id, "title" => "Self title"), "## Session Title Updated"
    assert_equal "Self title", session.reload.title

    result = @tool.call("action" => "set_heartbeat", "session_id" => session.id, "enabled" => false)
    assert_includes result, "- **Heartbeat Enabled:** No"
    assert_not session.reload.heartbeat_enabled
  end

  test "still requires session_id" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "archive") }
    assert_match(/"session_id" parameter is required/, error.message)
  end

  # The self-management surface deliberately withholds capability/config
  # reconfiguration — the same reason it excludes change_model and
  # change_mcp_servers. A session must not be able to rewrite its own skills,
  # plugins, goal, or category through the server injected into it.
  test "refuses capability/config edits that belong only to the full surface" do
    session = sessions(:needs_input)
    session.update!(catalog_skills: [ "sync-docs" ])

    %w[change_skills change_hooks change_plugins change_goal change_auto_compact_window change_category toggle_push_notifications].each do |action|
      error = assert_raises(Mcp::ToolError) do
        @tool.call("action" => action, "session_id" => session.id, "skills" => [ "open-pr" ], "goal" => "x")
      end
      assert_match(/Unknown action "#{action}"/, error.message)
    end

    # Nothing leaked through.
    assert_equal [ "sync-docs" ], session.reload.catalog_skills
  end

  # The self-archiving session is the caller that meets the queued-message
  # refusal most often, so it is the one caller that must not be trapped by it.
  test "self archive refuses a session with a queued message" do
    session = sessions(:running)
    session.enqueued_messages.create!(content: "add the onion back", position: 1, status: "pending")

    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "archive", "session_id" => session.id) }

    assert_includes error.message, "1 queued message has not been delivered"
    assert_equal "running", session.reload.status
  end

  test "self archive takes force, so the narrowed schema is not a trap" do
    session = sessions(:running)
    queued = session.enqueued_messages.create!(content: "deliberately discarded", position: 1, status: "pending")

    @tool.call("action" => "archive", "session_id" => session.id, "force" => true)

    assert_equal "archived", session.reload.status
    assert_equal "undelivered", queued.reload.status
  end

  test "force is declared on the self-session schema" do
    properties = Mcp::Tools::SelfSessionActionSession.input_schema.to_h.deep_symbolize_keys[:properties]

    assert properties.key?(:force), "a self-archiving session cannot pass what the schema does not declare"
    description = properties[:force][:description]
    assert_includes description, "NOT archive", "the description has to talk the caller out of it first"
    assert_not_includes description, "bulk_archive", "this surface has no bulk_archive action to describe"
  end
end
