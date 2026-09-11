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

  # What a drag POSTs: the grid's order after the drop, and the card that moved.
  def drag(ids, moved, category_id: "")
    post reorder_sessions_path, params: { ids: ids, category_id: category_id, session_id: moved }, as: :json
  end

  test "persists a within-section drag" do
    older = build_session(created_at: 2.hours.ago)
    newer = build_session(created_at: 1.hour.ago)

    drag([ older.id, newer.id ], older.id)

    assert_response :no_content
    assert_equal [ older.id, newer.id ], Session.where(category_id: nil).card_ordered.pluck(:id)
  end

  test "the dashboard renders the persisted order after a fresh request" do
    a = build_session(created_at: 3.hours.ago)
    b = build_session(created_at: 2.hours.ago)
    c = build_session(created_at: 1.hour.ago)
    # Rendered c, b, a. Drag a between c and b.
    drag([ c.id, a.id, b.id ], a.id)
    assert_response :no_content

    get root_path

    assert_response :success
    assert_equal [ c.id, a.id, b.id ], rendered_card_ids("sessions_grid")
  end

  test "a cross-section drag persists the category and the position in one request" do
    inbox = Category.create!(name: "Inbox")
    older = build_session(created_at: 3.hours.ago, category_id: inbox.id)
    newer = build_session(created_at: 2.hours.ago, category_id: inbox.id)
    moved = build_session(created_at: 1.hour.ago)

    # Inbox renders newer, older. Dropped between them.
    drag([ newer.id, moved.id, older.id ], moved.id, category_id: inbox.id.to_s)

    assert_response :no_content
    assert_equal inbox.id, moved.reload.category_id

    get root_path

    assert_response :success
    assert_equal [ newer.id, moved.id, older.id ], rendered_card_ids("category_grid_#{inbox.id}")
    assert_empty rendered_card_ids("sessions_grid")
  end

  test "the uncategorized sentinel names the Uncategorized bucket" do
    older = build_session(created_at: 2.hours.ago)
    newer = build_session(created_at: 1.hour.ago)

    drag([ older.id, newer.id ], older.id, category_id: "uncategorized")

    assert_response :no_content
    assert_equal [ older.id, newer.id ], Session.where(category_id: nil).card_ordered.pluck(:id)
  end

  test "returns 404 when the destination category does not exist, and writes nothing" do
    a = build_session(created_at: 2.hours.ago)
    b = build_session(created_at: 1.hour.ago)
    before = Session.where(id: [ a.id, b.id ]).order(:id).pluck(:sort_order)

    drag([ a.id, b.id ], a.id, category_id: 999_999)

    assert_response :not_found
    assert_equal before, Session.where(id: [ a.id, b.id ]).order(:id).pluck(:sort_order)
  end

  test "returns 404 for an unknown moved session, rather than a 2xx that moved nothing" do
    inbox = Category.create!(name: "Inbox")
    a = build_session(created_at: 1.hour.ago, category_id: inbox.id)

    drag([ a.id ], 999_999, category_id: inbox.id.to_s)

    assert_response :not_found
  end

  test "the moved session can be named by slug" do
    inbox = Category.create!(name: "Inbox")
    resident = build_session(created_at: 2.hours.ago, category_id: inbox.id)
    moved = build_session(created_at: 1.hour.ago)
    moved.update_column(:slug, "slugged-card")

    drag([ moved.id, resident.id ], "slugged-card", category_id: inbox.id.to_s)

    assert_response :no_content
    assert_equal inbox.id, moved.reload.category_id
  end

  # The gotcha the issue calls out: each section paginates on its own, so a drop
  # sends one PAGE of ids. If their index in that list were taken as the position,
  # dragging on page 2 would renumber page 1 on top of itself.
  test "a drag on the second page leaves the first page's order alone" do
    with_page_size(2) do
      4.times { |i| build_session(created_at: (10 - i).hours.ago) }
      ordered = Session.where(category_id: nil).card_ordered.pluck(:id)

      page_two = ordered[2, 2]
      drag(page_two.reverse, page_two.last)
      assert_response :no_content

      get root_path, params: { page: { "uncategorized" => 1 } }
      assert_equal ordered[0, 2], rendered_card_ids("sessions_grid")

      get root_path, params: { page: { "uncategorized" => 2 } }
      assert_equal page_two.reverse, rendered_card_ids("sessions_grid")
    end
  end

  # The dashboard draws a filtered subset of each bucket. A card the status filter
  # hides sits between the visible ones in the bucket, and must not be disturbed by a
  # drag among the cards around it.
  test "a card hidden by the status filter keeps its place through a drag around it" do
    a = build_session(created_at: 4.hours.ago)
    hidden = build_session(created_at: 3.hours.ago, status: :running)
    c = build_session(created_at: 2.hours.ago)
    # Bucket: c, hidden, a. The default filter renders c, a.
    get root_path
    assert_equal [ c.id, a.id ], rendered_card_ids("sessions_grid")

    drag([ a.id, c.id ], a.id)

    assert_equal [ a.id, c.id, hidden.id ], Session.where(category_id: nil).card_ordered.pluck(:id),
      "a moved above c; the hidden card stays below c, where it was"
    get root_path
    assert_equal [ a.id, c.id ], rendered_card_ids("sessions_grid")
  end

  test "a starred card is not disturbed by a drag in the section it left behind" do
    a = build_session(created_at: 4.hours.ago)
    star = build_session(created_at: 3.hours.ago)
    c = build_session(created_at: 2.hours.ago)
    star.update!(favorited: true)

    # The section shows c, a; a is dragged above c.
    drag([ a.id, c.id ], a.id)
    star.update!(favorited: false)

    get root_path

    assert_response :success
    assert_equal [ a.id, c.id, star.id ], rendered_card_ids("sessions_grid")
  end

  test "search results are unaffected by the dragged order" do
    a = build_session(created_at: 3.hours.ago, title: "alpha match")
    b = build_session(created_at: 1.hour.ago, title: "beta match")

    drag([ a.id, b.id ], a.id)

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
