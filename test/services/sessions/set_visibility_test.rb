require "test_helper"
require "mocha/minitest"

# Sessions::SetVisibility is the single writer behind all three surfaces (web UI,
# REST API, MCP). Two properties matter most: a wall-clock time is read in the
# operator's zone rather than the server's, and writing visibility touches nothing
# else on the session.
class Sessions::SetVisibilityTest < ActiveSupport::TestCase
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  def make_session(**attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    }.merge(attrs))
  end

  test "hides a session" do
    session = make_session

    Sessions::SetVisibility.call(session: session, visibility: "hidden")

    assert_equal SessionVisibility::HIDDEN, session.reload.visibility
    assert_nil session.snoozed_until
  end

  test "snoozes to a wall-clock time in the caller's zone, not the server's" do
    session = make_session
    # 09:00 in New York is 13:00 or 14:00 UTC depending on the season — the point
    # is only that it is NOT read as 09:00 UTC, which is the bug this guards.
    at = Time.use_zone("America/New_York") { 3.days.from_now.change(hour: 9, min: 0) }

    Sessions::SetVisibility.call(
      session: session,
      visibility: "snoozed",
      snoozed_until: at.strftime("%Y-%m-%dT%H:%M:%S"),
      timezone: "America/New_York"
    )

    session.reload
    assert_equal SessionVisibility::SNOOZED, session.visibility
    assert_equal at.to_i, session.snoozed_until.to_i
    assert_equal 9, session.snoozed_until.in_time_zone("America/New_York").hour
  end

  test "clears the snooze time when a session goes back on the board" do
    session = make_session(visibility: SessionVisibility::SNOOZED, snoozed_until: 2.days.from_now)

    Sessions::SetVisibility.call(session: session, visibility: "visible")

    session.reload
    assert_equal SessionVisibility::VISIBLE, session.visibility
    assert_nil session.snoozed_until
  end

  test "rejects an unknown visibility" do
    session = make_session

    error = assert_raises(Sessions::SetVisibility::Error) do
      Sessions::SetVisibility.call(session: session, visibility: "somewhen")
    end
    assert_includes error.message, "Unknown visibility"
    assert_equal SessionVisibility::VISIBLE, session.reload.visibility
  end

  test "rejects a snooze with no time" do
    session = make_session

    assert_raises(Sessions::SetVisibility::Error) do
      Sessions::SetVisibility.call(session: session, visibility: "snoozed")
    end
  end

  test "rejects a snooze in the past" do
    session = make_session

    error = assert_raises(Sessions::SetVisibility::Error) do
      Sessions::SetVisibility.call(
        session: session,
        visibility: "snoozed",
        snoozed_until: 1.hour.ago.strftime("%Y-%m-%dT%H:%M:%S"),
        timezone: "UTC"
      )
    end
    assert_includes error.message, "in the past"
    assert_equal SessionVisibility::VISIBLE, session.reload.visibility
  end

  test "rejects a time carrying its own UTC offset" do
    session = make_session

    assert_raises(Sessions::SetVisibility::Error) do
      Sessions::SetVisibility.call(
        session: session,
        visibility: "snoozed",
        snoozed_until: "2099-01-01T09:00:00+05:00",
        timezone: "UTC"
      )
    end
  end

  test "rejects an unknown timezone" do
    session = make_session

    assert_raises(Sessions::SetVisibility::Error) do
      Sessions::SetVisibility.call(
        session: session,
        visibility: "snoozed",
        snoozed_until: "2099-01-01T09:00:00",
        timezone: "Mars/Olympus_Mons"
      )
    end
  end

  # The orthogonality claim, asserted rather than described. Everything the
  # scheduler reads must come back byte-identical.
  test "changes nothing but the two visibility columns" do
    session = make_session(status: :waiting, scheduling_class: "spot", precedence: 4321)
    before = session.reload.attributes.except("visibility", "snoozed_until", "updated_at")

    Sessions::SetVisibility.call(
      session: session,
      visibility: "snoozed",
      snoozed_until: 2.days.from_now.strftime("%Y-%m-%dT%H:%M:%S"),
      timezone: "UTC"
    )

    assert_equal before, session.reload.attributes.except("visibility", "snoozed_until", "updated_at")
  end

  test "arms no trigger and leaves any existing wake-up alone" do
    session = make_session

    assert_no_difference -> { Trigger.count } do
      Sessions::SetVisibility.call(session: session, visibility: "hidden")
    end
  end
end
