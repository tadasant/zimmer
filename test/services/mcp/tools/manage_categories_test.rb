# frozen_string_literal: true

require "test_helper"

class Mcp::Tools::ManageCategoriesTest < ActiveSupport::TestCase
  setup do
    @tool = Mcp::Tools::ManageCategories.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  test "list with no categories" do
    assert_equal "## Categories\n\nNo categories found.", @tool.call("action" => "list")
  end

  test "list renders categories with session counts" do
    category = Category.create!(name: "Infra", description: "Ops work")
    sessions(:needs_input).update!(category_id: category.id)

    output = @tool.call("action" => "list")

    assert_includes output, "## Categories (1)"
    assert_includes output, "### Infra (ID: #{category.id})"
    assert_includes output, "- **Frozen:** false"
    assert_includes output, "- **Description:** Ops work"
    assert_includes output, "- **Sessions:** 1"
  end

  test "create makes a category" do
    output = @tool.call("action" => "create", "name" => "Docs", "description" => "Writing")

    category = Category.find_by(name: "Docs")
    assert category
    assert_equal "Writing", category.description
    assert_includes output, "## Category Created"
    assert_includes output, "- **Sessions:** 0"
  end

  test "create without a name raises" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "create") }
    assert_includes error.message, '"name" is required'
  end

  test "create with a duplicate name raises a validation error" do
    Category.create!(name: "Docs")

    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "create", "name" => "docs") }
    assert_includes error.message, "Validation failed"
  end

  test "update applies only the supplied fields" do
    category = Category.create!(name: "Infra", description: "Ops work")

    output = @tool.call("action" => "update", "category_id" => category.id, "is_frozen" => true)

    category.reload
    assert category.is_frozen
    assert_equal "Infra", category.name
    assert_equal "Ops work", category.description
    assert_includes output, "## Category Updated"
    assert_includes output, "- **Frozen:** true"
  end

  test "update without any field raises" do
    category = Category.create!(name: "Infra")

    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "update", "category_id" => category.id) }
    assert_includes error.message, "at least one of"
  end

  test "update with an unknown category raises" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "update", "category_id" => 999_999, "name" => "x") }
    assert_includes error.message, "not found"
  end

  test "delete removes the category and clears its sessions" do
    category = Category.create!(name: "Infra")
    session = sessions(:needs_input)
    session.update!(category_id: category.id)

    output = @tool.call("action" => "delete", "category_id" => category.id)

    assert_nil Category.find_by(id: category.id)
    assert_nil session.reload.category_id
    assert_includes output, "## Category Deleted"
  end

  test "delete without a category_id raises" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "delete") }
    assert_includes error.message, '"category_id" is required'
  end

  test "reorder rewrites positions" do
    first = Category.create!(name: "First")
    second = Category.create!(name: "Second")

    output = @tool.call("action" => "reorder", "ids" => [ second.id, first.id ])

    assert_equal 0, second.reload.position
    assert_equal 1, first.reload.position
    assert_includes output, "## Categories Reordered"
    assert_operator output.index("### Second"), :<, output.index("### First")
  end

  test "reorder accepts the uncategorized sentinel" do
    category = Category.create!(name: "Infra")

    @tool.call("action" => "reorder", "ids" => [ "uncategorized", category.id ])

    assert_equal 1, category.reload.position
    assert_equal 0, AppSetting.editable.uncategorized_position
  end

  test "reorder without ids raises" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "reorder", "ids" => []) }
    assert_includes error.message, '"ids"'
  end

  test "set_session_category assigns a session" do
    category = Category.create!(name: "Infra")
    session = sessions(:needs_input)

    output = @tool.call("action" => "set_session_category", "session_id" => session.id, "category_id" => category.id)

    assert_equal category.id, session.reload.category_id
    assert_includes output, "## Session Category Updated"
    assert_includes output, "- **Category:** Infra"
    assert_includes output, "- **Result:** Session assigned to category"
  end

  test "set_session_category with no category clears to uncategorized" do
    category = Category.create!(name: "Infra")
    session = sessions(:needs_input)
    session.update!(category_id: category.id)

    output = @tool.call("action" => "set_session_category", "session_id" => session.id, "category_id" => nil)

    assert_nil session.reload.category_id
    assert_includes output, "- **Category:** Uncategorized"
    assert_includes output, "- **Result:** Session moved to Uncategorized"
  end

  test "set_session_category with an unknown category raises" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "set_session_category", "session_id" => sessions(:needs_input).id, "category_id" => 999_999)
    end
    assert_includes error.message, "not found"
  end

  test "set_session_category without a session_id raises" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "set_session_category") }
    assert_includes error.message, '"session_id" is required'
  end

  test "unknown action raises" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "explode") }
    assert_includes error.message, 'Unknown action "explode"'
  end
end
