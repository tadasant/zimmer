require "test_helper"
require "mocha/minitest"

# Sessions::ToggleFavorite is the single writer behind all three surfaces (the
# web star, POST /api/v1/sessions/:id/toggle_favorite, and the `toggle_favorite`
# MCP action). What matters here is that the flip negates the COMMITTED value
# rather than the caller's in-memory copy, so two toggles from callers that
# loaded the same row add up to two flips instead of cancelling into one.
class Sessions::ToggleFavoriteTest < ActiveSupport::TestCase
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

  test "stars an unstarred session and returns the same instance" do
    session = make_session(favorited: false)

    returned = Sessions::ToggleFavorite.call(session: session)

    assert_same session, returned
    assert_equal true, session.favorited
    assert_equal true, session.reload.favorited
  end

  test "unstars a starred session" do
    session = make_session(favorited: true)

    Sessions::ToggleFavorite.call(session: session)

    assert_equal false, session.favorited
    assert_equal false, session.reload.favorited
  end

  # The race the service exists to close. Two callers load the row while it is
  # unstarred; the first toggles it on. A read-then-negate on the second
  # caller's stale copy would write `true` again, losing the second toggle.
  test "two toggles from callers holding the same stale row both land" do
    session = make_session(favorited: false)
    first = Session.find(session.id)
    second = Session.find(session.id)

    Sessions::ToggleFavorite.call(session: first)
    assert_equal true, session.reload.favorited

    Sessions::ToggleFavorite.call(session: second)

    assert_equal false, second.favorited
    assert_equal false, session.reload.favorited
  end

  test "reads the current value under a row lock" do
    session = make_session(favorited: false)
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql]
    end

    begin
      Sessions::ToggleFavorite.call(session: session)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    lock_index = statements.index { |sql| sql.match?(/\ASELECT .*"sessions".* FOR UPDATE\z/m) }
    update_index = statements.index { |sql| sql.match?(/\AUPDATE "sessions" SET .*"favorited"/m) }
    assert lock_index, "expected a SELECT … FOR UPDATE on sessions, got: #{statements.inspect}"
    assert update_index, "expected an UPDATE of favorited, got: #{statements.inspect}"
    assert_operator lock_index, :<, update_index
  end

  test "discards unsaved changes on the caller's instance" do
    session = make_session(favorited: false, title: "Kept")
    session.title = "Unsaved"

    Sessions::ToggleFavorite.call(session: session)

    assert_equal "Kept", session.title
    assert_equal "Kept", session.reload.title
    assert_equal true, session.favorited
  end

  test "flips only the star" do
    session = make_session(favorited: false, title: "Stays", session_notes: "notes")

    Sessions::ToggleFavorite.call(session: session)

    session.reload
    assert_equal "Stays", session.title
    assert_equal "notes", session.session_notes
    assert_equal true, session.favorited
  end
end
