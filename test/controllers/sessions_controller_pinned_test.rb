require "test_helper"
require "mocha/minitest"

# Tests for the "Starred" pinned group on the dashboard: SessionsController#index
# collects every favorited session on the current page into @pinned_sessions, renders
# them in a single group above all category sections, and excludes them from their
# category buckets so each starred session appears exactly once.
class SessionsControllerPinnedTest < ActionDispatch::IntegrationTest
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Session.any_instance.stubs(:broadcast_remove_from_sessions_index)

    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all
    Category.delete_all
    AppSetting.delete_all
  end

  def make_session(favorited:, category: nil, prompt: "p")
    Session.create!(
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: prompt,
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem",
      favorited: favorited,
      category: category
    )
  end

  # Card dom ids ("session_<id>") rendered inside the pinned group.
  def pinned_card_ids
    css_select("#pinned_section [id^='session_']").map { |el| el["id"] }
  end

  # Card dom ids rendered inside the category drag-and-drop stack.
  def category_stack_card_ids
    css_select("#category_sections [id^='session_']").map { |el| el["id"] }
  end

  test "no pinned section renders when nothing is starred" do
    make_session(favorited: false)

    get root_path

    assert_response :success
    assert_select "#pinned_section", false, "pinned section should be absent with no favorites"
  end

  test "starred sessions render in the pinned group above all category sections" do
    cat = Category.create!(name: "Work", position: 0)
    starred_in_cat = make_session(favorited: true, category: cat)
    starred_uncat = make_session(favorited: true, category: nil)
    plain = make_session(favorited: false, category: cat)

    get root_path

    assert_response :success
    assert_select "#pinned_section"

    # Both starred sessions (from different categories) appear in the pinned group.
    assert_includes pinned_card_ids, "session_#{starred_in_cat.id}"
    assert_includes pinned_card_ids, "session_#{starred_uncat.id}"

    # The pinned section renders before the category stack in document order.
    body = response.body
    assert body.index('id="pinned_section"') < body.index('id="category_sections"'),
      "pinned section should render above the category stack"

    # The plain (unstarred) session still renders in its category section.
    assert_includes category_stack_card_ids, "session_#{plain.id}"
  end

  test "starred sessions are excluded from their category buckets (appear once)" do
    cat = Category.create!(name: "Work", position: 0)
    starred = make_session(favorited: true, category: cat)

    get root_path

    assert_response :success
    # Appears in the pinned group...
    assert_includes pinned_card_ids, "session_#{starred.id}"
    # ...and NOT duplicated in the category stack.
    assert_not_includes category_stack_card_ids, "session_#{starred.id}"
  end

  test "pinned cards omit the category drag handle; category cards keep it" do
    cat = Category.create!(name: "Work", position: 0)
    starred = make_session(favorited: true, category: cat)
    plain = make_session(favorited: false, category: cat)

    get root_path

    assert_response :success
    # The pinned (starred) card has no "move to category" drag handle — its category
    # placement is invisible while pinned, so the affordance would be a misleading no-op.
    assert_select "##{ActionView::RecordIdentifier.dom_id(starred)} .session-drag-handle", false,
      "pinned card should not render the category drag handle"
    # The plain category card still has its drag handle.
    assert_select "##{ActionView::RecordIdentifier.dom_id(plain)} .session-drag-handle", true,
      "category card should still render the category drag handle"
  end

  test "pinned sessions are ordered most-recent first" do
    older = make_session(favorited: true)
    older.update_column(:created_at, 2.hours.ago)
    newer = make_session(favorited: true)
    newer.update_column(:created_at, 1.minute.ago)

    get root_path

    assert_response :success
    assert_equal [ "session_#{newer.id}", "session_#{older.id}" ], pinned_card_ids
  end
end
