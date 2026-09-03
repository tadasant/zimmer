require "test_helper"
require "mocha/minitest"

# Board visibility on the MCP surface: the `set_visibility` action, and how
# quick_search_sessions reports and (optionally) filters on it.
#
# The default of quick_search_sessions is the one to protect. Zimmer's own agents
# call it to check whether work is already in flight; a session a human snoozed
# off their board is still that work, so it must still come back.
class Mcp::Tools::VisibilityTest < ActiveSupport::TestCase
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Session.delete_all

    @action = Mcp::Tools::ActionSession.new(context: Mcp::Context.new(tool_groups: "sessions"))
    @search = Mcp::Tools::QuickSearchSessions.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  def make_session(**attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      title: "A session",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    }.merge(attrs))
  end

  # ---- action_session: set_visibility ----------------------------------------

  test "set_visibility hides a session" do
    session = make_session

    result = @action.call(
      "action" => "set_visibility", "session_id" => session.id, "visibility" => "hidden"
    )

    assert_includes result, "Board Visibility Set"
    assert_equal SessionVisibility::HIDDEN, session.reload.visibility
  end

  test "set_visibility snoozes in the caller's timezone" do
    session = make_session
    at = Time.use_zone("America/Chicago") { 2.days.from_now.change(hour: 9, min: 0) }

    @action.call(
      "action" => "set_visibility",
      "session_id" => session.id,
      "visibility" => "snoozed",
      "snoozed_until" => at.strftime("%Y-%m-%dT%H:%M:%S"),
      "timezone" => "America/Chicago"
    )

    assert_equal 9, session.reload.snoozed_until.in_time_zone("America/Chicago").hour
  end

  test "set_visibility refuses a past snooze without changing anything" do
    session = make_session

    assert_raises(Mcp::ToolError) do
      @action.call(
        "action" => "set_visibility",
        "session_id" => session.id,
        "visibility" => "snoozed",
        "snoozed_until" => "2020-01-01T09:00:00",
        "timezone" => "UTC"
      )
    end

    assert_equal SessionVisibility::VISIBLE, session.reload.visibility
  end

  test "set_visibility touches nothing the scheduler reads" do
    session = make_session(status: :waiting, scheduling_class: "spot", precedence: 4242)

    assert_no_difference -> { Trigger.count } do
      @action.call(
        "action" => "set_visibility", "session_id" => session.id, "visibility" => "hidden"
      )
    end

    session.reload
    assert_equal "waiting", session.status
    assert_equal "spot", session.scheduling_class
    assert_equal 4242, session.precedence
  end

  test "the set_visibility description says it does not affect scheduling" do
    description = Mcp::Tools::ActionSession.rendered_description.to_s

    assert_includes description, "set_visibility"
    assert_match(/visual-organization device and nothing else/i, description)
  end

  # The self-session variant must NOT gain this: a session tidying its own card
  # off the human's board is not self-management, it is editing their view.
  test "the self-session tool does not expose set_visibility" do
    assert_not_includes Mcp::Tools::SelfSessionActionSession::ACTIONS, "set_visibility"
  end

  # ---- quick_search_sessions -------------------------------------------------

  test "search returns snoozed sessions by default" do
    snoozed = make_session(title: "issue-4242 work",
                           visibility: SessionVisibility::SNOOZED, snoozed_until: 3.days.from_now)

    result = @search.call("query" => "issue-4242")

    assert_includes result, "ID: #{snoozed.id}"
  end

  test "search says a tucked-away session is presentation only" do
    make_session(title: "issue-4242 work", visibility: SessionVisibility::HIDDEN)

    result = @search.call("query" => "issue-4242")

    assert_includes result, "**Visibility:**"
    assert_includes result, "presentation only"
  end

  test "search filters on visibility when explicitly asked" do
    on_board = make_session(title: "issue-4242 on board")
    hidden = make_session(title: "issue-4242 tidied", visibility: SessionVisibility::HIDDEN)

    on = @search.call("query" => "issue-4242", "visibility" => "on_board")
    assert_includes on, "ID: #{on_board.id}"
    assert_not_includes on, "ID: #{hidden.id}"

    off = @search.call("query" => "issue-4242", "visibility" => "off_board")
    assert_includes off, "ID: #{hidden.id}"
    assert_not_includes off, "ID: #{on_board.id}"
  end

  test "search rejects an unknown visibility filter" do
    assert_raises(Mcp::ToolError) do
      @search.call("visibility" => "everything-please")
    end
  end

  test "the search description warns against filtering it for duplicate checks" do
    description = Mcp::Tools::QuickSearchSessions.rendered_description.to_s

    assert_match(/unfiltered on that axis by default/i, description)
  end
end
