require "test_helper"
require "mocha/minitest"

# Tests for the set_category member action: assigning a session to a category
# (or back to "Uncategorized") when a card is dragged between dashboard sections.
class SessionsControllerSetCategoryTest < ActionDispatch::IntegrationTest
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
  end

  def build_session(**attrs)
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", title: "Test", **attrs)
  end

  test "assigns a session to a category" do
    category = Category.create!(name: "pipeline")
    session = build_session

    patch set_category_session_path(session, format: :json), params: { category_id: category.id }

    assert_response :success
    assert_equal category.id, session.reload.category_id
    body = JSON.parse(response.body)
    assert body["success"]
    assert_equal category.id, body["category_id"]
  end

  test "clears a session's category when category_id is blank" do
    category = Category.create!(name: "pipeline")
    session = build_session(category: category)

    patch set_category_session_path(session, format: :json), params: { category_id: "" }

    assert_response :success
    assert_nil session.reload.category_id
    assert_nil JSON.parse(response.body)["category_id"]
  end

  test "returns 404 json when the category does not exist" do
    session = build_session

    patch set_category_session_path(session, format: :json), params: { category_id: 999_999 }

    assert_response :not_found
    assert_nil session.reload.category_id
  end

  test "html request redirects back" do
    category = Category.create!(name: "pipeline")
    session = build_session

    patch set_category_session_path(session), params: { category_id: category.id }

    assert_redirected_to root_path
    assert_equal category.id, session.reload.category_id
  end
end
