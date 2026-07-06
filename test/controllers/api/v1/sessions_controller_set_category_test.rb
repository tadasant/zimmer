# frozen_string_literal: true

require "test_helper"

# Covers the session <-> category surface of the sessions API: the set_category
# member action and the category fields embedded in session JSON.
class Api::V1::SessionsControllerSetCategoryTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key

    @category = Category.create!(name: "Work", position: 0)
    @session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test")
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  test "set_category assigns a session to a category" do
    patch set_category_api_v1_session_path(@session), params: { category_id: @category.id }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_equal @category.id, json["session"]["category_id"]
    assert_equal "Work", json["session"]["category"]["name"]
    assert_equal @category.id, @session.reload.category_id
  end

  test "set_category with blank category_id moves the session to Uncategorized" do
    @session.update!(category: @category)

    patch set_category_api_v1_session_path(@session), params: { category_id: "" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    assert_nil json["session"]["category_id"]
    assert_nil json["session"]["category"]
    assert_nil @session.reload.category_id
  end

  test "set_category with no category_id moves the session to Uncategorized" do
    @session.update!(category: @category)

    patch set_category_api_v1_session_path(@session), headers: @headers
    assert_response :success
    assert_nil @session.reload.category_id
  end

  test "set_category returns 404 for an unknown category" do
    patch set_category_api_v1_session_path(@session), params: { category_id: 999_999 }, headers: @headers
    assert_response :not_found
    assert_nil @session.reload.category_id
  end

  test "set_category requires authentication" do
    patch set_category_api_v1_session_path(@session), params: { category_id: @category.id }
    assert_response :unauthorized
  end

  test "show includes category info" do
    @session.update!(category: @category)

    get api_v1_session_path(@session), headers: @headers
    assert_response :success

    json = JSON.parse(response.body)["session"]
    assert_equal @category.id, json["category_id"]
    assert_equal({ "id" => @category.id, "name" => "Work", "position" => 0, "is_frozen" => false }, json["category"])
  end

  test "index includes category_id and category for sessions" do
    @session.update!(category: @category)

    get api_v1_sessions_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    session_json = json["sessions"].find { |s| s["id"] == @session.id }
    assert_equal @category.id, session_json["category_id"]
    assert_equal "Work", session_json["category"]["name"]
  end
end
