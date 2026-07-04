# frozen_string_literal: true

require "test_helper"

class Api::V1::CategoriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key

    Category.delete_all
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  # Authentication ----------------------------------------------------------

  test "index returns 401 without API key" do
    get api_v1_categories_path
    assert_response :unauthorized
  end

  test "create returns 401 without API key" do
    post api_v1_categories_path, params: { name: "x" }
    assert_response :unauthorized
  end

  # Index -------------------------------------------------------------------

  test "index returns categories ordered by position with session counts" do
    b = Category.create!(name: "B", position: 1)
    a = Category.create!(name: "A", position: 0)
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "p1", category: a)
    Session.create!(git_root: "https://github.com/test/repo.git", prompt: "p2", category: a)

    get api_v1_categories_path, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)
    names = json["categories"].map { |c| c["name"] }
    assert_equal [ "A", "B" ], names, "categories should be ordered by position"

    a_json = json["categories"].find { |c| c["id"] == a.id }
    b_json = json["categories"].find { |c| c["id"] == b.id }
    assert_equal 2, a_json["session_count"]
    assert_equal 0, b_json["session_count"]
    assert_equal [ "id", "name", "description", "position", "is_frozen", "session_count", "created_at", "updated_at" ].sort,
      a_json.keys.sort
  end

  # Create ------------------------------------------------------------------

  test "create makes a category and returns it" do
    assert_difference -> { Category.count }, 1 do
      post api_v1_categories_path, params: { name: "ingestion", description: "data in" }, headers: @headers
    end

    assert_response :created
    json = JSON.parse(response.body)["category"]
    assert_equal "ingestion", json["name"]
    assert_equal "data in", json["description"]
    assert_equal 0, json["session_count"]
    assert_equal false, json["is_frozen"]
  end

  test "create strips whitespace from the name" do
    post api_v1_categories_path, params: { name: "  backlog  " }, headers: @headers
    assert_response :created
    assert_equal "backlog", Category.last.name
  end

  test "create returns 422 for a blank name" do
    assert_no_difference -> { Category.count } do
      post api_v1_categories_path, params: { name: "" }, headers: @headers
    end
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["messages"].join, "Name"
  end

  test "create returns 422 for a duplicate name" do
    Category.create!(name: "Existing")
    assert_no_difference -> { Category.count } do
      post api_v1_categories_path, params: { name: "existing" }, headers: @headers
    end
    assert_response :unprocessable_entity
  end

  # Update ------------------------------------------------------------------

  test "update changes name and description" do
    category = Category.create!(name: "old", description: "old desc")

    patch api_v1_category_path(category), params: { name: "new", description: "new desc" }, headers: @headers
    assert_response :success

    json = JSON.parse(response.body)["category"]
    assert_equal "new", json["name"]
    assert_equal "new desc", json["description"]
    category.reload
    assert_equal "new", category.name
    assert_equal "new desc", category.description
  end

  test "update can freeze and unfreeze a category" do
    category = Category.create!(name: "backlog")
    assert_not category.is_frozen?

    patch api_v1_category_path(category), params: { is_frozen: true }, headers: @headers
    assert_response :success
    assert_equal true, JSON.parse(response.body)["category"]["is_frozen"]
    assert category.reload.is_frozen?

    patch api_v1_category_path(category), params: { is_frozen: false }, headers: @headers
    assert_response :success
    assert_equal false, JSON.parse(response.body)["category"]["is_frozen"]
    assert_not category.reload.is_frozen?
  end

  test "update with only is_frozen leaves name and description untouched" do
    category = Category.create!(name: "keep", description: "keep desc")

    patch api_v1_category_path(category), params: { is_frozen: true }, headers: @headers
    assert_response :success
    category.reload
    assert_equal "keep", category.name
    assert_equal "keep desc", category.description
  end

  test "update stores a blank description as null" do
    category = Category.create!(name: "spacey", description: "had one")

    patch api_v1_category_path(category), params: { description: "   " }, headers: @headers
    assert_response :success
    assert_nil category.reload.description
  end

  test "update with a blank name returns 422" do
    category = Category.create!(name: "keep me")
    patch api_v1_category_path(category), params: { name: "" }, headers: @headers
    assert_response :unprocessable_entity
    assert_equal "keep me", category.reload.name
  end

  test "update with a duplicate name returns 422" do
    Category.create!(name: "Existing")
    category = Category.create!(name: "Mine")
    patch api_v1_category_path(category), params: { name: "existing" }, headers: @headers
    assert_response :unprocessable_entity
    assert_equal "Mine", category.reload.name
  end

  test "update returns 404 for an unknown category" do
    patch api_v1_category_path(999_999), params: { name: "x" }, headers: @headers
    assert_response :not_found
  end

  # Destroy -----------------------------------------------------------------

  test "destroy removes the category and nullifies its sessions" do
    category = Category.create!(name: "temp")
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", category: category)

    assert_difference -> { Category.count }, -1 do
      delete api_v1_category_path(category), headers: @headers
    end

    assert_response :no_content
    assert_nil session.reload.category_id
  end

  test "destroy returns 404 for an unknown category" do
    delete api_v1_category_path(999_999), headers: @headers
    assert_response :not_found
  end

  # Reorder -----------------------------------------------------------------

  test "reorder rewrites positions and returns the new order" do
    a = Category.create!(name: "A", position: 0)
    b = Category.create!(name: "B", position: 1)
    c = Category.create!(name: "C", position: 2)

    post reorder_api_v1_categories_path, params: { ids: [ c.id, a.id, b.id ] }, headers: @headers
    assert_response :success

    assert_equal 0, c.reload.position
    assert_equal 1, a.reload.position
    assert_equal 2, b.reload.position

    json = JSON.parse(response.body)
    assert_equal [ c.id, a.id, b.id ], json["categories"].map { |x| x["id"] }
  end

  test "reorder leaves omitted categories at their existing position" do
    a = Category.create!(name: "A", position: 0)
    b = Category.create!(name: "B", position: 1)
    c = Category.create!(name: "C", position: 9)

    post reorder_api_v1_categories_path, params: { ids: [ b.id, a.id ] }, headers: @headers
    assert_response :success
    assert_equal 0, b.reload.position
    assert_equal 1, a.reload.position
    assert_equal 9, c.reload.position
  end
end
