require "test_helper"
require "mocha/minitest"

# Sessions::TogglePushNotifications is the single writer behind both surfaces
# (the web bell and the `toggle_push_notifications` MCP action). What matters
# here is that the flip negates the COMMITTED value rather than the caller's
# in-memory copy, so two toggles from callers that loaded the same row add up
# to two flips instead of cancelling into one.
class Sessions::TogglePushNotificationsTest < ActiveSupport::TestCase
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
      branch: "main"
    }.merge(attrs))
  end

  test "enables push notifications and returns the same instance" do
    session = make_session(push_notifications_enabled: false)

    returned = Sessions::TogglePushNotifications.call(session: session)

    assert_same session, returned
    assert_equal true, session.push_notifications_enabled
    assert_equal true, session.reload.push_notifications_enabled
  end

  test "disables push notifications" do
    session = make_session(push_notifications_enabled: true)

    Sessions::TogglePushNotifications.call(session: session)

    assert_equal false, session.push_notifications_enabled
    assert_equal false, session.reload.push_notifications_enabled
  end

  # The lost update the lock closes. Two callers load the row while it is off;
  # the first toggles it on. A read-then-negate on the second caller's stale
  # copy would write `true` again, losing the second toggle.
  test "two toggles from callers holding the same stale row both land" do
    session = make_session(push_notifications_enabled: false)
    first = Session.find(session.id)
    second = Session.find(session.id)

    Sessions::TogglePushNotifications.call(session: first)
    assert_equal true, session.reload.push_notifications_enabled

    Sessions::TogglePushNotifications.call(session: second)

    assert_equal false, second.push_notifications_enabled
    assert_equal false, session.reload.push_notifications_enabled
  end

  test "reads the current value under a row lock" do
    session = make_session(push_notifications_enabled: false)
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end

    begin
      Sessions::TogglePushNotifications.call(session: session)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    lock_index = statements.index { |sql| sql.match?(/FROM "sessions".*FOR UPDATE/m) }
    update_index = statements.index { |sql| sql.match?(/UPDATE "sessions" SET .*"push_notifications_enabled"/m) }
    assert lock_index, "expected a SELECT … FOR UPDATE on sessions, got: #{statements.inspect}"
    assert update_index, "expected an UPDATE of push_notifications_enabled, got: #{statements.inspect}"
    assert_operator lock_index, :<, update_index
  end

  test "discards unsaved changes on the caller's instance" do
    session = make_session(push_notifications_enabled: false, title: "Kept")
    session.title = "Unsaved"

    Sessions::TogglePushNotifications.call(session: session)

    assert_equal "Kept", session.title
    assert_equal "Kept", session.reload.title
    assert_equal true, session.push_notifications_enabled
  end

  test "flips only the push flag" do
    session = make_session(push_notifications_enabled: false, title: "Stays", session_notes: "notes")

    Sessions::TogglePushNotifications.call(session: session)

    session.reload
    assert_equal "Stays", session.title
    assert_equal "notes", session.session_notes
    assert_equal true, session.push_notifications_enabled
  end
end
