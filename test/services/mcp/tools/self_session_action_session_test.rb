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
    assert_equal %w[update_notes update_title set_heartbeat pause_into_spot_queue message_parent archive], schema[:properties][:action][:enum]
    assert_equal %w[session_id action], schema[:required]
    assert_match(/self-management/, definition[:description])
  end

  # The narrowed surface carries the same hand-maintained pair as its parent:
  # an executable ACTIONS list and a prose description that has to be edited in
  # step with it. Same drift, same consequence — a self-managing session reads
  # the description and concludes it cannot do something it can.
  test "the action description names every dispatchable action and no others" do
    description = Mcp::Tools::SelfSessionActionSession.input_schema.to_h.dig(:properties, :action, :description)

    Mcp::Tools::SelfSessionActionSession::ACTIONS.each do |action|
      assert_includes description, %("#{action}"),
        "#{action} is dispatchable but missing from the action description"
    end

    assert_equal [], description.scan(/"(\w+)"/).flatten - Mcp::Tools::SelfSessionActionSession::ACTIONS,
      "the action description advertises actions the dispatch does not accept"
  end

  # And the same for the long-form description this surface writes for itself:
  # a narrowed ACTIONS list against its own hand-maintained "- **<name>**:"
  # bullets, drifting the same way for the same reason. Scoped to the Actions
  # block for the same reason too — the "Reporting back to your parent" and
  # "Archive guidelines" sections below it are prose, and their bullets are not
  # claims about what the tool dispatches.
  test "the long-form description explains every dispatchable action and no others" do
    actions_block = Mcp::Tools::SelfSessionActionSession.to_h[:description][/^\*\*Actions.*?(?=\n\n\*\*)/m]
    assert actions_block, "could not find the Actions block in the long-form description"
    bulleted = actions_block.scan(/^- \*\*(\w+)\*\*:/).flatten

    assert_equal [], Mcp::Tools::SelfSessionActionSession::ACTIONS - bulleted,
      "dispatchable actions with no bullet in the long-form description"
    assert_equal [], bulleted - Mcp::Tools::SelfSessionActionSession::ACTIONS,
      "the long-form description explains actions the dispatch does not accept"
    assert_equal bulleted.uniq, bulleted, "an action is explained twice in the long-form description"
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

  # The archive guidelines are read at the exact moment a session decides whether to
  # end, so they have to agree with the system prompt's sanctioned reason 2 rather
  # than restate the older "stay in needs_input until the PR merges" rule it dropped.
  test "the archive guidelines defer a PR session's how-to-rest to the open-pr skill" do
    description = Mcp::Tools::SelfSessionActionSession.to_h[:description]

    assert_includes description, "How it holds is the `open-pr` skill's terminal steps"
    assert_includes description, "asleep in `waiting` on a bounded self-wake while the merge gate is still rating the PR"
    assert_includes description, "at rest in `needs_input` once the gate *holds* it"
    # The exits that do not depend on the gate ever answering.
    assert_includes description, "the wake budget is spent, or the PR state cannot be read"
    # The merge message is still the archive signal, and an unrecorded URL still has a way out.
    assert_includes description, "that message is the signal to archive"
    assert_includes description, "report the URL and archive rather than waiting"

    refute_includes description, "stay in `needs_input` until that PR merges",
      "the guidelines must not park a session for the whole time its PR is open"
  end

  test "force is declared on the self-session schema" do
    properties = Mcp::Tools::SelfSessionActionSession.input_schema.to_h.deep_symbolize_keys[:properties]

    assert properties.key?(:force), "a self-archiving session cannot pass what the schema does not declare"
    description = properties[:force][:description]
    assert_includes description, "NOT archive", "the description has to talk the caller out of it first"
    assert_not_includes description, "bulk_archive", "this surface has no bulk_archive action to describe"
  end
  # The counterpart of wake_me_up_later for a session with no time worth naming.
  # It is on the self-session surface because parking ITSELF is exactly the case:
  # a session waiting on quota rather than on an event.
  test "parks itself in the spot queue with no wake trigger" do
    session = sessions(:needs_input)
    session.update!(scheduling_class: SessionGenesis::PRIORITY)

    result = assert_no_difference "Trigger.count" do
      @tool.call("action" => "pause_into_spot_queue", "session_id" => session.id,
                 "prompt" => "Pick the migration back up at step 4")
    end

    assert_includes result, "Parked In The Spot Queue"
    session.reload
    assert session.waiting?
    assert session.spot?
    assert_equal "Pick the migration back up at step 4", session.metadata[SpotSessionPause::QUEUED_PROMPT]
    assert_not session.awaiting_scheduled_wake?
  end

  # --- message_parent --------------------------------------------------------
  #
  # The one action on this surface that is NOT a narrowing of the full one. It
  # is here because it can only be here: the target is never an argument.

  test "reports to the parent Zimmer resolves, taking no target argument" do
    parent = sessions(:needs_input)
    child = sessions(:waiting)
    child.update!(parent_session_id: parent.id)

    result = @tool.call(
      "action" => "message_parent", "session_id" => child.id,
      "message" => "the deploy scripts live in the infra root", "reason" => "wrong_scope"
    )

    assert_includes result, "## Report Sent to Parent Session"
    assert_includes result, "- **Parent Session ID:** #{parent.id}"
    assert_includes result, "- **Reported by:** session ##{child.id}"
    assert_equal "running", parent.reload.status
    assert_match(/the deploy scripts live in the infra root/, parent.metadata["pending_follow_up_prompt"])

    properties = Mcp::Tools::SelfSessionActionSession.input_schema.to_h.deep_symbolize_keys[:properties]
    assert_not properties.key?(:parent_session_id), "naming the target would make this a general messaging primitive"
    assert_not properties.key?(:target_session_id), "naming the target would make this a general messaging primitive"
  end

  test "a running parent is queued rather than interrupted, and told how deep its queue is" do
    parent = sessions(:running)
    child = sessions(:waiting)
    child.update!(parent_session_id: parent.id)

    result = @tool.call(
      "action" => "message_parent", "session_id" => child.id,
      "message" => "no ssh key on this box", "reason" => "missing_tools"
    )

    assert_includes result, "queued for your parent"
    assert_equal "running", parent.reload.status
    assert_equal "caller", parent.enqueued_messages.sole.origin
  end

  test "refuses a session with no parent, and says what to do instead" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "message_parent", "session_id" => sessions(:waiting).id,
                 "message" => "stuck", "reason" => "other")
    end

    assert_match(/has no parent session/, error.message)
  end

  test "refuses an archived parent, naming the override rather than losing the report" do
    parent = sessions(:archived)
    child = sessions(:waiting)
    child.update!(parent_session_id: parent.id)

    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "message_parent", "session_id" => child.id,
                 "message" => "wrong root", "reason" => "wrong_scope")
    end

    assert_match(/unarchive_parent/, error.message)
    assert_equal "archived", parent.reload.status
    assert_empty parent.enqueued_messages
  end

  # The narrow exception to "the tool group narrows the actions, not the target":
  # this one speaks in the named session's name, to a THIRD session.
  test "refuses to send another session's report when the connection names its own" do
    parent = sessions(:needs_input)
    other_child = sessions(:waiting)
    other_child.update!(parent_session_id: parent.id)

    tool = Mcp::Tools::SelfSessionActionSession.new(
      context: Mcp::Context.new(tool_groups: "self_session", session_id: sessions(:running).id)
    )

    error = assert_raises(Mcp::ToolError) do
      tool.call("action" => "message_parent", "session_id" => other_child.id,
                "message" => "not mine to send", "reason" => "other")
    end

    assert_match(/reports on behalf of the session making the call/, error.message)
    assert_equal "needs_input", parent.reload.status
    assert_empty parent.enqueued_messages
  end

  # Every other message_parent test here drives the shared @tool, whose context
  # carries no session_id — so enforce_self_report! returns on its first line and
  # is never exercised on a success path. This is the one that reports over a
  # connection stamped the way every injected one is, which is the only shape a
  # real caller has.
  test "a connection that names the calling session reports over it normally" do
    parent = sessions(:running)
    child = sessions(:waiting)
    child.update!(parent_session_id: parent.id)

    tool = Mcp::Tools::SelfSessionActionSession.new(
      context: Mcp::Context.new(tool_groups: "self_session", session_id: child.id)
    )

    result = tool.call("action" => "message_parent", "session_id" => child.id,
                       "message" => "the infra root owns this", "reason" => "wrong_scope")

    assert_includes result, "## Report Sent to Parent Session"
    assert_match(/the infra root owns this/, parent.enqueued_messages.sole.content)
  end

  test "the reason enum is the service's, so the two cannot drift" do
    properties = Mcp::Tools::SelfSessionActionSession.input_schema.to_h.deep_symbolize_keys[:properties]

    assert_equal Sessions::MessageParent::REASONS.keys, properties[:reason][:enum]
  end
end
