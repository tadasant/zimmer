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

  # --- The tuning loop (tadasant/zimmer#16) ------------------------------------

  def record_correction(bugs, research, session: sessions(:waiting))
    CategoryFeedbackEvent.record_inference_outcome!(
      session: session, category: bugs, raw_answer: "CATEGORY: Bugs", context: "snapshot",
      context_source: "transcript", title_requested: false, model: "haiku",
      prompt_version: CategorizationService::PROMPT_VERSION, candidates: [ bugs, research ]
    )
    CategoryFeedbackEvent.record_correction!(session: session, corrected_category: research)
  end

  test "tuning shows the knobs, the descriptions the inference sees, and the corrections" do
    AppSetting.delete_all
    bugs = Category.create!(name: "Bugs", description: "Defects")
    research = Category.create!(name: "Research")
    record_correction(bugs, research)

    output = @tool.call("action" => "tuning")

    assert_includes output, "- **Model:** haiku (default)"
    assert_includes output, "- **Guidance:** (none)"
    assert_includes output, "- **Bugs:** Defects"
    assert_includes output, "- **Research:** (no description"
    assert_includes output, "Bugs -> Research (not replayed)"
  end

  test "set_tuning writes guidance and model" do
    AppSetting.delete_all

    output = @tool.call("action" => "set_tuning", "guidance" => "Docs PRs are Docs.", "inference_model" => "sonnet")

    assert_includes output, "- **Model:** sonnet"
    assert_equal "Docs PRs are Docs.", AppSetting.current.category_guidance
  end

  test "set_tuning refuses a model the inference runtime cannot run" do
    AppSetting.delete_all

    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "set_tuning", "inference_model" => "gpt-5.5") }
    assert_includes error.message, "not available"
  end

  test "set_tuning with nothing to set raises" do
    assert_raises(Mcp::ToolError) { @tool.call("action" => "set_tuning") }
  end

  test "replay enqueues the replay job" do
    bugs = Category.create!(name: "Bugs")
    research = Category.create!(name: "Research")
    record_correction(bugs, research)

    output = @tool.call("action" => "replay", "limit" => 5)

    assert_includes output, "- **Corrections queued:** 1"
  end

  test "replay says so when one is already queued or running" do
    bugs = Category.create!(name: "Bugs")
    research = Category.create!(name: "Research")
    record_correction(bugs, research)
    CategorizationReplayJob.stubs(:enqueue).returns(false)

    assert_includes @tool.call("action" => "replay"), "already queued or running"
  end

  test "replay with no corrections raises" do
    CategoryFeedbackEvent.delete_all

    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "replay") }
    assert_includes error.message, "nothing to replay"
  end

  test "set_session_category records the move as an MCP correction" do
    bugs = Category.create!(name: "Bugs")
    research = Category.create!(name: "Research")
    session = sessions(:waiting)
    session.update!(category_id: bugs.id)
    record_correction(bugs, research, session: session)
    CategoryFeedbackEvent.corrections.delete_all

    @tool.call("action" => "set_session_category", "session_id" => session.id, "category_id" => research.id)

    assert_equal CategoryFeedbackEvent::MCP, CategoryFeedbackEvent.corrections.last.source
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

  # reorder_sessions ---------------------------------------------------------

  def build_card(created_at:, **attrs)
    Session.create!({
      git_root: "https://github.com/test/repo.git",
      prompt: "Test",
      created_at: created_at
    }.merge(attrs))
  end

  test "reorder_sessions rewrites card positions inside a section" do
    category = Category.create!(name: "Infra")
    a = build_card(created_at: 3.hours.ago, category: category)
    b = build_card(created_at: 2.hours.ago, category: category)

    output = @tool.call("action" => "reorder_sessions", "category_id" => category.id, "session_ids" => [ a.id, b.id ])

    assert_includes output, "## Session Cards Reordered"
    assert_includes output, "- **Section:** Infra"
    assert_equal [ a.id, b.id ], Session.where(category_id: category.id).card_ordered.pluck(:id)
  end

  test "reorder_sessions targets Uncategorized when no category is named" do
    a = build_card(created_at: 3.hours.ago)
    b = build_card(created_at: 2.hours.ago)

    output = @tool.call("action" => "reorder_sessions", "session_ids" => [ a.id, b.id ])

    assert_includes output, "- **Section:** Uncategorized"
    ids = Session.where(category_id: nil).card_ordered.pluck(:id)
    assert_operator ids.index(a.id), :<, ids.index(b.id)
  end

  test "reorder_sessions moves a card in from another section when session_id is given" do
    category = Category.create!(name: "Infra")
    older = build_card(created_at: 3.hours.ago, category: category)
    newer = build_card(created_at: 2.hours.ago, category: category)
    moved = build_card(created_at: 1.hour.ago)

    # The section reads newer, older; the moved card goes between them.
    @tool.call(
      "action" => "reorder_sessions",
      "category_id" => category.id,
      "session_ids" => [ newer.id, moved.id, older.id ],
      "session_id" => moved.id
    )

    assert_equal category.id, moved.reload.category_id
    assert_equal [ newer.id, moved.id, older.id ], Session.where(category_id: category.id).card_ordered.pluck(:id)
  end

  test "reorder_sessions without session_ids raises" do
    error = assert_raises(Mcp::ToolError) { @tool.call("action" => "reorder_sessions", "session_ids" => []) }
    assert_includes error.message, '"session_ids" (a non-empty array) is required'
  end

  test "reorder_sessions with an unknown category raises" do
    error = assert_raises(Mcp::ToolError) do
      @tool.call("action" => "reorder_sessions", "category_id" => 999_999, "session_ids" => [ 1 ])
    end
    assert_includes error.message, "Category #999999 not found"
  end
end
