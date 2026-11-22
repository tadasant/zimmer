# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

class Mcp::Tools::ManageBoardCategoriesTest < ActiveSupport::TestCase
  setup do
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
    @tool = Mcp::Tools::ManageBoardCategories.new(context: Mcp::Context.new(tool_groups: "sessions"))
  end

  test "is on the sessions surface" do
    names = Mcp::Registry.tools_for([ "sessions" ]).map(&:tool_name)
    assert_includes names, "manage_board_categories"
  end

  test "every UI action is expressible" do
    assert_match(/No board categories yet/, @tool.call({ "action" => "list" }))

    @tool.call({ "action" => "create", "name" => "Infra" })
    @tool.call({ "action" => "create", "name" => "UI" })
    infra = BoardCategory.find_by!(name: "Infra")
    ui = BoardCategory.find_by!(name: "UI")

    @tool.call({ "action" => "rename", "category_id" => infra.id, "name" => "Infrastructure" })
    assert_equal "Infrastructure", infra.reload.name

    @tool.call({ "action" => "reorder", "category_ids" => [ ui.id, infra.id ] })
    assert_equal [ ui, infra ], BoardCategory.ordered.to_a

    @tool.call({ "action" => "set_collapsed", "category_id" => ui.id, "collapsed" => true })
    assert ui.reload.collapsed

    out = @tool.call({ "action" => "set_visibility", "category_id" => infra.id, "visibility" => "backlogged" })
    assert_match(/Nothing about when its sessions run has changed/, out)
    assert infra.reload.backlogged?

    session = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "p", title: "s")
    @tool.call({ "action" => "assign", "session_id" => session.id, "category_id" => ui.id })
    assert_equal ui.id, session.reload.board_category_id
    @tool.call({ "action" => "assign", "session_id" => session.id })
    assert_nil session.reload.board_category_id

    listing = @tool.call({ "action" => "list" })
    assert_match(/1\. \*\*UI\*\*.*collapsed/, listing)
    assert_match(/Backlogged/, listing)

    @tool.call({ "action" => "delete", "category_id" => ui.id })
    assert_not BoardCategory.exists?(ui.id)
  end

  test "refusals are tool errors" do
    assert_raises(Mcp::ToolError) { @tool.call({ "action" => "explode" }) }
    assert_raises(Mcp::ToolError) { @tool.call({ "action" => "rename", "category_id" => 999_999, "name" => "x" }) }
    category = BoardCategory.create!(name: "Infra")
    assert_raises(Mcp::ToolError) { @tool.call({ "action" => "set_visibility", "category_id" => category.id, "visibility" => "hidden" }) }
    assert_raises(Mcp::ToolError) { @tool.call({ "action" => "create", "name" => "infra" }) }
  end
end
