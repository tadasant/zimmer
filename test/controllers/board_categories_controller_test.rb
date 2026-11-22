# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Your board v2 (`/?view=board_v2`) and the category endpoints it drives.
class BoardCategoriesControllerTest < ActionDispatch::IntegrationTest
  DESKTOP_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36".freeze

  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    Session.any_instance.stubs(:broadcast_remove_from_sessions_index)
    Session.delete_all
  end

  def make_session(title, category: nil, status: :needs_input)
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "p", title: title, status: status)
    session.update_columns(board_category_id: category&.id)
    session
  end

  def get_board(**params)
    get dashboard_board_path(**params.merge(view: "board_v2")), headers: { "User-Agent" => DESKTOP_UA }
  end

  def json_patch(path, body)
    patch path, params: body.to_json, headers: { "Content-Type" => "application/json", "Accept" => "application/json" }
  end

  # ---- The board -------------------------------------------------------------

  test "the v2 tab sits beside Your board, which is unchanged" do
    get root_path(view: "board_v2"), headers: { "User-Agent" => DESKTOP_UA }
    assert_response :success
    assert_select "a[aria-pressed='true']", text: "Your board v2"
    assert_select "a", text: "Your board"

    infra = BoardCategory.create!(name: "Infra")
    make_session("in infra", category: infra)
    get dashboard_board_path(view: "user"), headers: { "User-Agent" => DESKTOP_UA }
    assert_response :success
    assert_select "#user_view_list li", 1
    assert_select "#board_v2", 0
  end

  test "renders Uncategorized, each category in order, and tucked-away categories as headers only" do
    infra = BoardCategory.create!(name: "Infra")
    ui = BoardCategory.create!(name: "UI", collapsed: true)
    parked = BoardCategory.create!(name: "Parked", visibility: SessionVisibility::BACKLOGGED)
    make_session("loose")
    make_session("in infra", category: infra)
    make_session("in ui", category: ui)
    make_session("parked one", category: parked)

    get_board
    assert_response :success

    assert_select "#board_v2 h3", text: "Uncategorized"
    assert_select "#board_v2_list_uncategorized li", text: /loose/
    assert_select "#board_v2_list_#{infra.id} li", text: /in infra/
    assert_select "[data-category-id='#{ui.id}'] [data-board-v2-body].hidden"
    assert_select "[data-board-v2-target='category'] h3", text: /Infra|UI/, count: 2
    assert_select "[data-board-v2-tucked-category='#{parked.id}']", text: /Parked.*1 session.*Backlogged/m
    assert_no_match(/parked one/, response.body)
  end

  test "follows the board's filters" do
    infra = BoardCategory.create!(name: "Infra")
    make_session("waiting one", category: infra, status: :waiting)
    make_session("needs input one", category: infra)

    get_board
    assert_match(/needs input one/, response.body)
    assert_no_match(/waiting one/, response.body)
  end

  # ---- Writes ----------------------------------------------------------------

  test "create, rename and delete from the forms" do
    post board_categories_path, params: { name: "Research" }
    assert_redirected_to root_path(view: "board_v2")
    category = BoardCategory.find_by!(name: "Research")

    patch board_category_path(category), params: { name: "Deep research" }
    assert_equal "Deep research", category.reload.name

    session = make_session("researching", category: category)
    delete board_category_path(category)
    assert_not BoardCategory.exists?(category.id)
    assert_nil session.reload.board_category_id
  end

  test "a refused name comes back as the reason" do
    BoardCategory.create!(name: "Dup")
    post board_categories_path, params: { name: "dup" }, headers: { "Accept" => "application/json" }
    assert_response :unprocessable_entity
    assert_match(/taken/, response.parsed_body["error"])
  end

  test "dragging a session into a category, and back out" do
    category = BoardCategory.create!(name: "Infra")
    session = make_session("drag me")

    json_patch assign_board_category_session_path(session), { board_category_id: category.id }
    assert_response :success
    assert_equal category.id, session.reload.board_category_id

    json_patch assign_board_category_session_path(session), { board_category_id: nil }
    assert_nil session.reload.board_category_id
  end

  test "collapse persists" do
    category = BoardCategory.create!(name: "Infra")
    json_patch board_category_path(category), { collapsed: true }
    assert category.reload.collapsed
    json_patch board_category_path(category), { collapsed: false }
    assert_not category.reload.collapsed
  end

  test "reorder persists" do
    a = BoardCategory.create!(name: "A")
    b = BoardCategory.create!(name: "B")
    json_patch reorder_board_categories_path, { category_ids: [ b.id, a.id ] }
    assert_response :success
    assert_equal [ b, a ], BoardCategory.ordered.to_a
  end

  test "snooze and backlog a whole category, and refuse what a category cannot be" do
    category = BoardCategory.create!(name: "Infra")
    tomorrow = "#{1.day.from_now.to_date.iso8601}T09:00:00"

    json_patch visibility_board_category_path(category), { visibility: "snoozed", snoozed_until: tomorrow, timezone: "UTC" }
    assert_response :success
    assert category.reload.snooze_active?

    json_patch visibility_board_category_path(category), { visibility: "hidden" }
    assert_response :unprocessable_entity
  end
end
