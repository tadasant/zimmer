# frozen_string_literal: true

require "test_helper"

# Your board v2 on the REST surface, which the iOS app draws: `view=board_v2` on
# the index (the rows Sessions::BoardV2 shows, in its order, plus the categories),
# and Api::V1::BoardCategoriesController's writes — assign, collapse, visibility.
class Api::V1::SessionsBoardV2Test < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
    Session.delete_all
    BoardCategory.delete_all
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  def make(title, touched:, category: nil)
    session = Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", title: title, status: :needs_input)
    session.update_columns(created_at: 3.days.ago, metadata: session.metadata.merge("last_user_activity_at" => touched.iso8601),
      board_category_id: category&.id)
    session
  end

  def board(**params)
    get "/api/v1/sessions", params: { view: "board_v2" }.merge(params), headers: @headers
    assert_response :success, response.body
    JSON.parse(response.body)
  end

  test "view=board_v2 lists Uncategorized, then each category in order, newest touched first, with the categories" do
    research = BoardCategory.create!(name: "Research")
    infra = BoardCategory.create!(name: "Infra", collapsed: true)
    loose_old = make("loose old", touched: 2.hours.ago)
    loose_new = make("loose new", touched: 1.minute.ago)
    infra_row = make("infra", touched: 3.minutes.ago, category: infra)
    research_old = make("research old", touched: 5.hours.ago, category: research)
    research_new = make("research new", touched: 4.minutes.ago, category: research)

    json = board

    assert_equal [ loose_new.id, loose_old.id, research_new.id, research_old.id, infra_row.id ], json["sessions"].map { |s| s["id"] }
    assert_equal [ nil, nil, research.id, research.id, infra.id ], json["sessions"].map { |s| s["board_category_id"] }
    categories = json["board_categories"]
    assert_equal [ "Research", "Infra" ], categories.map { |c| c["name"] }
    assert_equal [ false, true ], categories.map { |c| c["collapsed"] }
    assert_equal [ true, true ], categories.map { |c| c["on_board"] }
    assert_equal [ 2, 1 ], categories.map { |c| c["session_count"] }
    assert_equal false, json["truncated"]
    assert_equal 1, json["pagination"]["total_pages"]
  end

  test "a snoozed or backlogged category comes last, off the board, with a count and none of its rows" do
    parked = BoardCategory.create!(name: "Parked")
    shown = BoardCategory.create!(name: "Shown")
    parked.update!(visibility: "backlogged")
    make("parked row", touched: 1.minute.ago, category: parked)
    visible = make("shown row", touched: 2.minutes.ago, category: shown)

    json = board

    assert_equal [ visible.id ], json["sessions"].map { |s| s["id"] }
    assert_equal [ [ "Shown", true, 1 ], [ "Parked", false, 1 ] ],
      json["board_categories"].map { |c| [ c["name"], c["on_board"], c["session_count"] ] }
    assert_equal "backlogged", json["board_categories"].last["visibility"]
  end

  test "view=board_v2 follows the index's filters and answers one page" do
    make("asked", touched: 1.minute.ago)
    waiting = make("waiting", touched: 2.minutes.ago)
    waiting.update_columns(status: "waiting")

    assert_equal [ "asked" ], board(status: "needs_input")["sessions"].map { |s| s["title"] }

    get "/api/v1/sessions", params: { view: "board_v2", page: 2 }, headers: @headers
    assert_response :unprocessable_entity
    assert_match(/single page/, JSON.parse(response.body)["message"])
  end

  test "an unknown view names board_v2 among the valid ones" do
    get "/api/v1/sessions", params: { view: "board_v3" }, headers: @headers
    assert_response :unprocessable_entity
    assert_match(/board_v2/, JSON.parse(response.body)["message"])
  end

  test "every session carries its board_category_id" do
    category = BoardCategory.create!(name: "Research")
    session = make("row", touched: 1.minute.ago, category: category)

    get "/api/v1/sessions/#{session.id}", headers: @headers
    assert_equal category.id, JSON.parse(response.body)["session"]["board_category_id"]
  end

  test "assign moves a session into a category and back to Uncategorized, without touching it" do
    category = BoardCategory.create!(name: "Research")
    session = make("row", touched: 1.hour.ago)
    touched_before = session.reload.metadata["last_user_activity_at"]

    patch "/api/v1/sessions/#{session.id}/board_category", params: { board_category_id: category.id }, headers: @headers, as: :json
    assert_response :success, response.body
    assert_equal category.id, JSON.parse(response.body)["session"]["board_category_id"]
    assert_equal category.id, session.reload.board_category_id
    assert_equal touched_before, session.metadata["last_user_activity_at"]

    patch "/api/v1/sessions/#{session.id}/board_category", params: { board_category_id: nil }, headers: @headers, as: :json
    assert_response :success, response.body
    assert_nil session.reload.board_category_id
  end

  test "assign refuses a category that does not exist" do
    session = make("row", touched: 1.hour.ago)

    patch "/api/v1/sessions/#{session.id}/board_category", params: { board_category_id: 999_999 }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_match(/No board category/, JSON.parse(response.body)["message"])
  end

  test "collapse and expand a category" do
    category = BoardCategory.create!(name: "Infra")

    patch "/api/v1/board_categories/#{category.id}", params: { collapsed: true }, headers: @headers, as: :json
    assert_response :success, response.body
    assert_equal true, JSON.parse(response.body)["board_category"]["collapsed"]
    assert category.reload.collapsed

    patch "/api/v1/board_categories/#{category.id}", params: {}, headers: @headers, as: :json
    assert_response :unprocessable_entity

    patch "/api/v1/board_categories/999999", params: { collapsed: true }, headers: @headers, as: :json
    assert_response :not_found
  end

  test "visibility snoozes and wakes a category as a unit" do
    category = BoardCategory.create!(name: "Infra")
    until_time = 2.days.from_now.change(usec: 0)

    patch "/api/v1/board_categories/#{category.id}/visibility",
      params: { visibility: "snoozed", snoozed_until: until_time.iso8601 }, headers: @headers, as: :json
    assert_response :success, response.body
    json = JSON.parse(response.body)["board_category"]
    assert_equal "snoozed", json["visibility"]
    assert_equal false, json["on_board"]

    patch "/api/v1/board_categories/#{category.id}/visibility", params: { visibility: "visible" }, headers: @headers, as: :json
    assert_response :success, response.body
    assert_equal true, JSON.parse(response.body)["board_category"]["on_board"]
    assert_equal "visible", category.reload.visibility

    patch "/api/v1/board_categories/#{category.id}/visibility", params: { visibility: "hidden" }, headers: @headers, as: :json
    assert_response :unprocessable_entity
  end
end
