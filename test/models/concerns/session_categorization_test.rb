require "test_helper"

# The single seam every category write passes through (tadasant/zimmer#16).
#
# The asymmetry this closes: the auto path always logged "Auto-assigned to
# category X" and the manual path logged nothing, so after one drag the two were
# indistinguishable. These tests pin the note, the correction row, and — the part
# that actually keeps working as surfaces are added — that the hook fires on the
# COLUMN rather than on any one controller.
class SessionCategorizationTest < ActiveSupport::TestCase
  setup do
    CategoryFeedbackEvent.delete_all
    Category.delete_all
    @bugs = Category.create!(name: "Bugs", description: "Defects")
    @research = Category.create!(name: "Research", description: "Spikes")
    @session = sessions(:waiting)
    @session.update!(category_id: nil)
  end

  def record_inference(category)
    CategoryFeedbackEvent.record_inference_outcome!(
      session: @session,
      category: category,
      raw_answer: "CATEGORY: #{category&.name || 'NONE'}",
      context: "what the model saw",
      context_source: "transcript",
      title_requested: true,
      model: "haiku",
      prompt_version: CategorizationService::PROMPT_VERSION,
      candidates: [ @bugs, @research ]
    )
  end

  test "a manual move writes the timeline note the manual path never had" do
    @session.update!(category_id: @bugs.id)

    @session.category_change_source = CategoryFeedbackEvent::WEB_UI
    @session.update!(category_id: @research.id)

    note = @session.logs.order(:id).last
    assert_equal "Moved to category \"Research\" (was \"Bugs\")", note.content
    assert_equal "info", note.level
  end

  test "a move to Uncategorized says so in both halves of the note" do
    @session.update!(category_id: @bugs.id)
    @session.update!(category_id: nil)

    assert_equal "Moved to Uncategorized (was \"Bugs\")", @session.logs.order(:id).last.content
  end

  test "a first manual assignment names Uncategorized as where it came from" do
    @session.update!(category_id: @bugs.id)

    assert_equal "Moved to category \"Bugs\" (was Uncategorized)", @session.logs.order(:id).last.content
  end

  test "the categorizer's own write is not logged as a human correction" do
    record_inference(@bugs)

    assert_no_difference "CategoryFeedbackEvent.corrections.count" do
      assert_no_difference "@session.logs.count" do
        @session.category_change_source = SessionCategorization::CATEGORY_CHANGE_BY_INFERENCE
        @session.update!(category_id: @bugs.id)
      end
    end
  end

  test "a manual move records a correction against what the categorizer answered" do
    record_inference(@bugs)
    @session.category_change_source = SessionCategorization::CATEGORY_CHANGE_BY_INFERENCE
    @session.update!(category_id: @bugs.id)

    @session.category_change_source = CategoryFeedbackEvent::WEB_UI
    @session.update!(category_id: @research.id)

    correction = CategoryFeedbackEvent.corrections.last
    assert_equal @bugs.id, correction.auto_category_id
    assert_equal @research.id, correction.corrected_category_id
    assert_equal "what the model saw", correction.context_snapshot
    assert_equal CategoryFeedbackEvent::WEB_UI, correction.source
  end

  test "a surface that names no source is recorded as unattributed rather than dropped" do
    record_inference(@bugs)

    @session.update!(category_id: @research.id)

    assert_equal CategoryFeedbackEvent::UNATTRIBUTED, CategoryFeedbackEvent.corrections.last.source
  end

  test "the attribution does not leak into the next change on the same record" do
    record_inference(@bugs)

    @session.category_change_source = CategoryFeedbackEvent::MCP
    @session.update!(category_id: @bugs.id)
    @session.update!(category_id: @research.id)

    assert_equal CategoryFeedbackEvent::UNATTRIBUTED, CategoryFeedbackEvent.corrections.last.source
  end

  test "a cross-section drag through reorder_cards! is a correction like any other" do
    record_inference(@bugs)
    @session.category_change_source = SessionCategorization::CATEGORY_CHANGE_BY_INFERENCE
    @session.update!(category_id: @bugs.id)

    Session.reorder_cards!(
      [ @session.id ],
      category_id: @research.id,
      moved_session_id: @session.id,
      source: CategoryFeedbackEvent::WEB_UI
    )

    correction = CategoryFeedbackEvent.corrections.last
    assert_equal @research.id, correction.corrected_category_id
    assert_equal @research.id, @session.reload.category_id
    assert_equal "Moved to category \"Research\" (was \"Bugs\")", @session.logs.order(:id).last.content
  end

  test "a write that changes nothing but the sort order logs nothing" do
    @session.update!(category_id: @bugs.id)
    before = @session.logs.count

    @session.update!(sort_order: 42)

    assert_equal before, @session.logs.count
  end

  test "deleting a category does not file its orphans as corrections" do
    record_inference(@bugs)
    @session.category_change_source = SessionCategorization::CATEGORY_CHANGE_BY_INFERENCE
    @session.update!(category_id: @bugs.id)

    assert_no_difference "CategoryFeedbackEvent.corrections.count" do
      @bugs.destroy!
    end

    assert_nil @session.reload.category_id
  end
end
