require "test_helper"
require "mocha/minitest"

# Tests for the manual "blocked by" feature: index filtering plus the
# mark_blocked / unmark_blocked member actions.
class SessionsControllerBlockedByTest < ActionDispatch::IntegrationTest
  def setup
    Log.any_instance.stubs(:broadcast_append_to_timeline)
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Session.any_instance.stubs(:broadcast_remove_from_sessions_index)

    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all
  end

  def build_session(**attrs)
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      title: "Test",
      **attrs
    )
  end

  test "index hides effectively-blocked sessions by default" do
    blocker = build_session(status: :running, title: "Blocker")
    blocked = build_session(status: :needs_input, title: "Blocked", blocked_by_session: blocker)

    get root_url
    assert_response :success
    assert_match blocker.title, @response.body
    assert_no_match(/Blocked<\/h3>/, @response.body)
    assert_not_includes @response.body, "##{blocked.id}"
  end

  test "index shows blocked sessions when show_blocked=true" do
    blocker = build_session(status: :running, title: "Blocker")
    blocked = build_session(status: :needs_input, title: "Blocked", blocked_by_session: blocker)

    get root_url(show_blocked: "true")
    assert_response :success
    assert_includes @response.body, "##{blocked.id}"
  end

  test "index still shows a session whose blocker is archived" do
    blocker = build_session(status: :archived, title: "Blocker")
    blocked = build_session(status: :needs_input, title: "Blocked", blocked_by_session: blocker)

    get root_url
    assert_response :success
    assert_includes @response.body, "##{blocked.id}"
  end

  test "mark_blocked sets the blocked_by relationship" do
    blocker = build_session(status: :running, title: "Blocker")
    session = build_session(status: :needs_input, title: "Target")

    patch mark_blocked_session_path(session), params: { blocked_by_session_id: blocker.id }
    assert_redirected_to root_path

    assert_equal blocker.id, session.reload.blocked_by_session_id
  end

  test "mark_blocked with missing id is rejected" do
    session = build_session(status: :needs_input, title: "Target")

    patch mark_blocked_session_path(session), params: { blocked_by_session_id: "" }
    assert_redirected_to root_path

    assert_nil session.reload.blocked_by_session_id
  end

  test "mark_blocked with nonexistent blocker is rejected" do
    session = build_session(status: :needs_input, title: "Target")

    patch mark_blocked_session_path(session), params: { blocked_by_session_id: 999999 }
    assert_redirected_to root_path

    assert_nil session.reload.blocked_by_session_id
  end

  test "mark_blocked rejects self-reference" do
    session = build_session(status: :needs_input, title: "Target")

    patch mark_blocked_session_path(session), params: { blocked_by_session_id: session.id }
    assert_redirected_to root_path

    assert_nil session.reload.blocked_by_session_id
  end

  test "mark_blocked returns 404 json when blocker not found" do
    session = build_session(status: :needs_input, title: "Target")

    patch mark_blocked_session_path(session, format: :json), params: { blocked_by_session_id: 999999 }
    assert_response :not_found
  end

  test "mark_blocked returns 422 json on self-reference" do
    session = build_session(status: :needs_input, title: "Target")

    patch mark_blocked_session_path(session, format: :json), params: { blocked_by_session_id: session.id }
    assert_response :unprocessable_entity
  end

  test "unmark_blocked clears the relationship" do
    blocker = build_session(status: :running, title: "Blocker")
    session = build_session(status: :needs_input, title: "Target", blocked_by_session: blocker)

    patch unmark_blocked_session_path(session)
    assert_redirected_to root_path

    assert_nil session.reload.blocked_by_session_id
  end
end
