require "test_helper"
require "mocha/minitest"

# Tests for POST /sessions/reorder: the write behind a card drag on the dashboard,
# and for the read side that renders the resulting order back out.
class SessionsControllerReorderTest < ActionDispatch::IntegrationTest
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

  # The dashboard opens on `needs_input` only, so a card has to be in that state to
  # be rendered at all.
  def build_session(created_at:, **attrs)
    Session.create!({
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      title: "Test",
      status: :needs_input,
      created_at: created_at
    }.merge(attrs))
  end

  # The ids of the cards rendered inside one section's grid, top to bottom.
  def rendered_card_ids(grid_id)
    css_select("##{grid_id} turbo-frame[id^='session_']").map { |el| el["id"].delete_prefix("session_").to_i }
  end

  test "persists a within-section reorder" do
    a = build_session(created_at: 3.hours.ago)
    b = build_session(created_at: 2.hours.ago)
    c = build_session(created_at: 1.hour.ago)

    post reorder_sessions_path, params: { ids: [ a.id, c.id, b.id ], category_id: "" }, as: :json

    assert_response :no_content
    assert_equal [ a.id, c.id, b.id ], Session.where(category_id: nil).card_ordered.pluck(:id)
  end

  test "the dashboard renders the persisted order after a fresh request" do
    a = build_session(created_at: 3.hours.ago)
    b = build_session(created_at: 2.hours.ago)
    c = build_session(created_at: 1.hour.ago)

    post reorder_sessions_path, params: { ids: [ b.id, c.id, a.id ], category_id: "" }, as: :json
    assert_response :no_content

    get root_path

    assert_response :success
    assert_equal [ b.id, c.id, a.id ], rendered_card_ids("sessions_grid")
  end

  test "a cross-section drag persists the category and the position in one request" do
    inbox = Category.create!(name: "Inbox")
    a = build_session(created_at: 3.hours.ago, category_id: inbox.id)
    b = build_session(created_at: 2.hours.ago, category_id: inbox.id)
    moved = build_session(created_at: 1.hour.ago)

    post reorder_sessions_path,
      params: { ids: [ a.id, moved.id, b.id ], category_id: inbox.id.to_s, session_id: moved.id },
      as: :json

    assert_response :no_content
    assert_equal inbox.id, moved.reload.category_id

    get root_path

    assert_response :success
    assert_equal [ a.id, moved.id, b.id ], rendered_card_ids("category_grid_#{inbox.id}")
    assert_empty rendered_card_ids("sessions_grid")
  end

  test "the uncategorized sentinel names the Uncategorized bucket" do
    a = build_session(created_at: 2.hours.ago)
    b = build_session(created_at: 1.hour.ago)

    post reorder_sessions_path, params: { ids: [ a.id, b.id ], category_id: "uncategorized" }, as: :json

    assert_response :no_content
    assert_equal [ a.id, b.id ], Session.where(category_id: nil).card_ordered.pluck(:id)
  end

  test "returns 404 json when the destination category does not exist" do
    a = build_session(created_at: 2.hours.ago)
    b = build_session(created_at: 1.hour.ago)

    post reorder_sessions_path, params: { ids: [ a.id, b.id ], category_id: 999_999 }, as: :json

    assert_response :not_found
    assert_equal [ 0, 0 ], Session.where(id: [ a.id, b.id ]).pluck(:sort_order)
  end

  # The gotcha the issue calls out: each section paginates on its own, so a drop
  # sends one PAGE of ids. If their index in that list were taken as the position,
  # dragging on page 2 would renumber page 1 on top of itself.
  test "a reorder on the second page leaves the first page's order alone" do
    with_page_size(2) do
      ids = 4.times.map { |i| build_session(created_at: (10 - i).hours.ago).id }
      # Newest first, so page 1 is the two newest.
      ordered = Session.where(category_id: nil).card_ordered.pluck(:id)
      assert_equal ids.reverse, ordered

      page_two = ordered[2, 2]
      post reorder_sessions_path, params: { ids: page_two.reverse, category_id: "" }, as: :json
      assert_response :no_content

      get root_path, params: { page: { "uncategorized" => 1 } }
      assert_equal ordered[0, 2], rendered_card_ids("sessions_grid")

      get root_path, params: { page: { "uncategorized" => 2 } }
      assert_equal page_two.reverse, rendered_card_ids("sessions_grid")
    end
  end

  test "a starred card is not renumbered by a drag in the section it left behind" do
    a = build_session(created_at: 4.hours.ago)
    star = build_session(created_at: 3.hours.ago)
    c = build_session(created_at: 2.hours.ago)

    post reorder_sessions_path, params: { ids: [ a.id, star.id, c.id ], category_id: "" }, as: :json
    star.update!(favorited: true)

    # The section now shows a and c only; a drag there names just those two.
    post reorder_sessions_path, params: { ids: [ c.id, a.id ], category_id: "" }, as: :json
    star.update!(favorited: false)

    get root_path

    assert_response :success
    assert_equal [ c.id, star.id, a.id ], rendered_card_ids("sessions_grid")
  end

  test "search results are unaffected by the dragged order" do
    a = build_session(created_at: 3.hours.ago, title: "alpha match")
    b = build_session(created_at: 1.hour.ago, title: "beta match")

    post reorder_sessions_path, params: { ids: [ a.id, b.id ], category_id: "" }, as: :json

    get root_path, params: { q: "match" }

    assert_response :success
    # The flat search list keeps favorites-then-newest; it is not draggable.
    rendered = css_select("turbo-frame[id^='session_']")
      .map { |el| el["id"].delete_prefix("session_") }
      .grep(/\A\d+\z/).map(&:to_i)
    assert_equal [ b.id, a.id ], rendered
  end

  private

  def with_page_size(size)
    original = SessionsController::SESSIONS_PER_PAGE
    SessionsController.send(:remove_const, :SESSIONS_PER_PAGE)
    SessionsController.const_set(:SESSIONS_PER_PAGE, size)
    yield
  ensure
    SessionsController.send(:remove_const, :SESSIONS_PER_PAGE)
    SessionsController.const_set(:SESSIONS_PER_PAGE, original)
  end
end
