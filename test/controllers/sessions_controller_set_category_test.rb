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

  # tadasant/zimmer#16: the manual path used to log nothing, so a human
  # correction and an auto-assignment were indistinguishable after the fact.
  test "a manual move writes a timeline note and records the correction" do
    CategoryFeedbackEvent.delete_all
    bugs = Category.create!(name: "Bugs")
    research = Category.create!(name: "Research")
    session = build_session(category_id: bugs.id)
    CategoryFeedbackEvent.record_inference_outcome!(
      session: session, category: bugs, raw_answer: "CATEGORY: Bugs", context: "snapshot",
      context_source: "transcript", title_requested: true, model: "haiku",
      prompt_version: CategorizationService::PROMPT_VERSION, candidates: [ bugs, research ]
    )

    patch set_category_session_path(session, format: :json), params: { category_id: research.id }

    assert_response :success
    assert_equal "Moved to category \"Research\" (was \"Bugs\")", session.logs.order(:id).last.content
    correction = CategoryFeedbackEvent.corrections.last
    assert_equal bugs.id, correction.auto_category_id
    assert_equal research.id, correction.corrected_category_id
    assert_equal CategoryFeedbackEvent::WEB_UI, correction.source
  end

  test "a cross-section drag records the correction as web_ui" do
    CategoryFeedbackEvent.delete_all
    bugs = Category.create!(name: "Bugs")
    research = Category.create!(name: "Research")
    session = build_session(category_id: bugs.id)
    CategoryFeedbackEvent.record_inference_outcome!(
      session: session, category: bugs, raw_answer: "CATEGORY: Bugs", context: "snapshot",
      context_source: "transcript", title_requested: true, model: "haiku",
      prompt_version: CategorizationService::PROMPT_VERSION, candidates: [ bugs, research ]
    )

    post reorder_sessions_path, params: { ids: [ session.id ], category_id: research.id, session_id: session.id }, as: :json

    assert_response :no_content
    assert_equal research.id, session.reload.category_id
    assert_equal CategoryFeedbackEvent::WEB_UI, CategoryFeedbackEvent.corrections.last.source
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
