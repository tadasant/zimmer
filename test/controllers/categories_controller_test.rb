require "test_helper"
require "mocha/minitest"

class CategoriesControllerTest < ActionDispatch::IntegrationTest
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

  test "create makes a category and returns the turbo stream section" do
    assert_difference -> { Category.count }, 1 do
      post categories_url, params: { name: "grocery shopping" }, as: :turbo_stream
    end

    assert_response :success
    category = Category.last
    assert_equal "grocery shopping", category.name
    # The appended section targets the category_sections container and renders the section.
    assert_match(/category_sections/, response.body)
    assert_match(/grocery shopping/, response.body)
    # The header count badge renders 0 for the brand-new empty category. This also guards
    # the render path: the partial calls sessions.total_count, so the section must be
    # handed a Kaminari relation (Session.none.page(1)), not a bare Array.
    assert_select "[data-category-count-id='#{category.id}']", text: "0"
  end

  test "create strips surrounding whitespace from the name" do
    post categories_url, params: { name: "  backlog  " }, as: :turbo_stream
    assert_response :success
    assert_equal "backlog", Category.last.name
  end

  test "create returns 422 json for a blank name" do
    assert_no_difference -> { Category.count } do
      post categories_url(format: :json), params: { name: "" }
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "Name"
  end

  test "create returns 422 json for a duplicate name" do
    Category.create!(name: "Existing")

    assert_no_difference -> { Category.count } do
      post categories_url(format: :json), params: { name: "existing" }
    end

    assert_response :unprocessable_entity
  end

  test "create answers turbo_stream requests on failure with 422 (not 406)" do
    Category.create!(name: "Existing")

    # The "+" button posts with a Turbo Stream Accept header. A duplicate name must
    # come back as 422 with the validation message, not a 406 empty body.
    assert_no_difference -> { Category.count } do
      post categories_url, params: { name: "existing" }, as: :turbo_stream
    end

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "Name"
  end

  test "create returns id and name as json" do
    post categories_url(format: :json), params: { name: "ingestion" }

    assert_response :created
    body = JSON.parse(response.body)
    assert body["success"]
    assert_equal "ingestion", body["name"]
    assert_equal Category.last.id, body["id"]
  end

  test "reorder rewrites each category position to its index in the id list" do
    a = Category.create!(name: "A", position: 0)
    b = Category.create!(name: "B", position: 1)
    c = Category.create!(name: "C", position: 2)

    post reorder_categories_url(format: :json), params: { ids: [ c.id, a.id, b.id ] }

    assert_response :no_content
    assert_equal 0, c.reload.position
    assert_equal 1, a.reload.position
    assert_equal 2, b.reload.position
    assert_equal [ c, a, b ], Category.ordered.to_a
  end

  test "reorder ignores unknown and zero ids" do
    a = Category.create!(name: "A", position: 0)
    b = Category.create!(name: "B", position: 1)

    post reorder_categories_url(format: :json), params: { ids: [ b.id, 0, 999_999, a.id ] }

    assert_response :no_content
    # Zero ids are dropped before indexing; the surviving order is [b, 999999, a], so
    # b -> 0 and a -> 2 (the unknown id at index 1 simply touches no rows).
    assert_equal 0, b.reload.position
    assert_equal 2, a.reload.position
  end

  test "reorder leaves categories omitted from the list at their existing position" do
    a = Category.create!(name: "A", position: 0)
    b = Category.create!(name: "B", position: 1)
    c = Category.create!(name: "C", position: 9)

    post reorder_categories_url(format: :json), params: { ids: [ b.id, a.id ] }

    assert_response :no_content
    assert_equal 0, b.reload.position
    assert_equal 1, a.reload.position
    assert_equal 9, c.reload.position
  end

  test "reorder with no ids is a no-op" do
    a = Category.create!(name: "A", position: 5)

    post reorder_categories_url(format: :json), params: {}

    assert_response :no_content
    assert_equal 5, a.reload.position
  end

  test "reorder persists the uncategorized sentinel to AppSetting#uncategorized_position" do
    a = Category.create!(name: "A", position: 0)
    b = Category.create!(name: "B", position: 1)

    # Drag Uncategorized below A but above B: [A, uncategorized, B].
    post reorder_categories_url(format: :json), params: { ids: [ a.id, "uncategorized", b.id ] }

    assert_response :no_content
    assert_equal 0, a.reload.position
    assert_equal 2, b.reload.position
    # The sentinel's index (1) is written to the singleton AppSetting row.
    assert_equal 1, AppSetting.current.uncategorized_position
  end

  test "reorder can push uncategorized to the bottom of the stack" do
    a = Category.create!(name: "A", position: 0)
    b = Category.create!(name: "B", position: 1)

    post reorder_categories_url(format: :json), params: { ids: [ a.id, b.id, "uncategorized" ] }

    assert_response :no_content
    assert_equal 0, a.reload.position
    assert_equal 1, b.reload.position
    assert_equal 2, AppSetting.current.uncategorized_position
  end

  test "reorder updates the existing AppSetting row rather than inserting a second" do
    AppSetting.create!(uncategorized_position: 0)
    a = Category.create!(name: "A", position: 0)

    assert_no_difference -> { AppSetting.count } do
      post reorder_categories_url(format: :json), params: { ids: [ a.id, "uncategorized" ] }
    end

    assert_response :no_content
    assert_equal 1, AppSetting.current.uncategorized_position
  end

  test "update changes name and description and returns them as json" do
    category = Category.create!(name: "old name", description: "old desc")

    patch category_url(category, format: :json), params: { category: { name: "new name", description: "new desc" } }

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert_equal "new name", body["name"]
    assert_equal "new desc", body["description"]
    category.reload
    assert_equal "new name", category.name
    assert_equal "new desc", category.description
  end

  test "update sets is_frozen and echoes it as json" do
    category = Category.create!(name: "backlog")
    assert_not category.is_frozen?

    patch category_url(category, format: :json), params: { category: { is_frozen: true } }

    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert_equal true, body["is_frozen"]
    assert category.reload.is_frozen?
  end

  test "update can unfreeze a frozen category" do
    category = Category.create!(name: "backlog", is_frozen: true)

    patch category_url(category, format: :json), params: { category: { is_frozen: false } }

    assert_response :success
    assert_equal false, JSON.parse(response.body)["is_frozen"]
    assert_not category.reload.is_frozen?
  end

  test "update strips whitespace from name and stores a blank description as null" do
    category = Category.create!(name: "spacey", description: "had one")

    patch category_url(category, format: :json), params: { category: { name: "  trimmed  ", description: "   " } }

    assert_response :success
    category.reload
    assert_equal "trimmed", category.name
    assert_nil category.description
  end

  test "update with a blank name returns 422" do
    category = Category.create!(name: "keep me")

    patch category_url(category, format: :json), params: { category: { name: "" } }

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "Name"
    assert_equal "keep me", category.reload.name
  end

  test "update with a duplicate name returns 422" do
    Category.create!(name: "Existing")
    category = Category.create!(name: "Mine")

    patch category_url(category, format: :json), params: { category: { name: "existing" } }

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "Name"
    assert_equal "Mine", category.reload.name
  end

  test "update html format redirects back with a notice on success" do
    category = Category.create!(name: "html old")

    patch category_url(category), params: { category: { name: "html new" } }, headers: { "Referer" => root_url }

    assert_redirected_to root_url
    assert_equal "html new", category.reload.name
    assert_match(/updated/i, flash[:notice])
  end

  test "update html format redirects back with an alert on failure" do
    Category.create!(name: "Existing")
    category = Category.create!(name: "html mine")

    patch category_url(category), params: { category: { name: "existing" } }, headers: { "Referer" => root_url }

    assert_redirected_to root_url
    assert_match(/already been taken/i, flash[:alert])
    assert_equal "html mine", category.reload.name
  end

  test "destroy removes the category and nullifies its sessions" do
    category = Category.create!(name: "temp")
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", category: category)

    assert_difference -> { Category.count }, -1 do
      delete category_url(category, format: :json)
    end

    assert_response :success
    assert_nil session.reload.category_id
  end

  test "destroy turbo stream removes the section and re-homes its sessions to Uncategorized" do
    category = Category.create!(name: "temp")
    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Test", title: "Re-home me", category: category)

    delete category_url(category), as: :turbo_stream

    assert_response :success
    # Section is removed and the orphaned card is appended into the Uncategorized grid.
    assert_match(/turbo-stream action="remove" target="#{ActionView::RecordIdentifier.dom_id(category)}"/, response.body)
    assert_match(/turbo-stream action="append" target="sessions_grid"/, response.body)
    assert_match(/session_#{session.id}/, response.body)
    assert_nil session.reload.category_id
  end
end
