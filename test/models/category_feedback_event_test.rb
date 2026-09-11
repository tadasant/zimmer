require "test_helper"

# The categorization eval corpus (tadasant/zimmer#16). What matters here is not
# that rows can be written — it is that a correction row is SELF-CONTAINED (it
# carries the context the model saw, so replay never needs the session), that a
# correction with nothing to disagree with is not recorded at all, and that the
# corpus counts one opinion per session rather than one per drag.
class CategoryFeedbackEventTest < ActiveSupport::TestCase
  setup do
    CategoryFeedbackEvent.delete_all
    Category.delete_all
    @bugs = Category.create!(name: "Bugs", description: "Defects")
    @research = Category.create!(name: "Research", description: "Spikes")
    @session = sessions(:waiting)
  end

  def record_inference(category:, session: @session, context: "transcript text")
    CategoryFeedbackEvent.record_inference_outcome!(
      session: session,
      category: category,
      raw_answer: "CATEGORY: #{category&.name || 'NONE'}",
      context: context,
      context_source: "transcript",
      title_requested: true,
      model: "haiku",
      prompt_version: CategorizationService::PROMPT_VERSION,
      candidates: [ @bugs, @research ]
    )
  end

  test "an auto-assignment records the model's answer and the context it saw" do
    event = record_inference(category: @bugs)

    assert_equal CategoryFeedbackEvent::AUTO_ASSIGNED, event.kind
    assert_equal @bugs.id, event.auto_category_id
    assert_equal "Bugs", event.auto_category_name
    assert_equal "transcript text", event.context_snapshot
    assert_equal %w[Bugs Research], event.candidate_names
    assert event.title_requested
  end

  test "a decline is recorded as its own kind, not as a missing row" do
    event = record_inference(category: nil)

    assert_equal CategoryFeedbackEvent::UNCATEGORIZED, event.kind
    assert_nil event.auto_category_id
    assert_equal "transcript text", event.context_snapshot
  end

  test "a correction copies the snapshot forward so the row stands alone" do
    record_inference(category: @bugs)

    correction = CategoryFeedbackEvent.record_correction!(
      session: @session,
      corrected_category: @research,
      source: CategoryFeedbackEvent::WEB_UI
    )

    assert_equal CategoryFeedbackEvent::CORRECTION, correction.kind
    assert_equal @bugs.id, correction.auto_category_id
    assert_equal @research.id, correction.corrected_category_id
    assert_equal "transcript text", correction.context_snapshot
    assert_equal "haiku", correction.model
    assert_equal CategoryFeedbackEvent::WEB_UI, correction.source
    assert correction.title_requested
  end

  test "a correction of a decline is recorded, because a decline is an answer" do
    record_inference(category: nil)

    correction = CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: @bugs)

    refute_nil correction
    assert_nil correction.auto_category_id
    assert_equal @bugs.id, correction.corrected_category_id
  end

  test "no correction is recorded when the categorizer never ruled on the session" do
    assert_no_difference "CategoryFeedbackEvent.count" do
      assert_nil CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: @bugs)
    end
  end

  test "a correction to Uncategorized records a null corrected category, not a missing row" do
    record_inference(category: @bugs)

    correction = CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: nil)

    assert_nil correction.corrected_category_id
    assert_equal "Uncategorized", correction.corrected_label
  end

  test "the corpus keeps one opinion per session, the latest" do
    record_inference(category: @bugs)
    CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: @research)
    latest = CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: @bugs)

    corpus = CategoryFeedbackEvent.eval_corpus

    assert_equal [ latest.id ], corpus.map(&:id)
  end

  test "the corpus survives the session it came from being deleted" do
    record_inference(category: @bugs)
    correction = CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: @research)

    @session.destroy!

    correction.reload
    assert_nil correction.session_id
    assert_equal "transcript text", correction.context_snapshot
    assert_equal [ correction.id ], CategoryFeedbackEvent.eval_corpus.map(&:id)
  end

  test "a correction stays readable after its category is deleted" do
    record_inference(category: @bugs)
    correction = CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: @research)

    @research.destroy!

    correction.reload
    assert_nil correction.corrected_category_id
    assert_equal "Research", correction.corrected_category_name
  end

  test "the scorecard counts only rows that were actually replayed" do
    record_inference(category: @bugs)
    right = CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: @research)
    right.update!(replayed_at: Time.current, replay_category_id: @research.id, replay_category_name: "Research")

    other = sessions(:running)
    record_inference(category: @bugs, session: other)
    CategoryFeedbackEvent.record_correction!(session: other, corrected_category: @research)

    scorecard = CategoryFeedbackEvent.scorecard(CategoryFeedbackEvent.eval_corpus)

    assert_equal 2, scorecard.total
    assert_equal 1, scorecard.replayed
    assert_equal 1, scorecard.correct
    assert_equal 100, scorecard.accuracy_pct
    assert_equal 1, scorecard.unreplayed
  end

  test "a replay that still disagrees scores as wrong" do
    record_inference(category: @bugs)
    correction = CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: @research)
    correction.update!(replayed_at: Time.current, replay_category_id: @bugs.id, replay_category_name: "Bugs")

    refute correction.replay_correct?
    assert_equal 0, CategoryFeedbackEvent.scorecard([ correction ]).accuracy_pct
  end

  test "the decline rate is read off inference outcomes only" do
    record_inference(category: @bugs)
    record_inference(category: nil, session: sessions(:running))
    CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: @research)

    assert_equal({ sampled: 2, declined: 1 }, CategoryFeedbackEvent.decline_rate)
  end

  test "a correction into a since-deleted category is unscorable, not a NULL-equals-NULL hit" do
    record_inference(category: @bugs)
    correction = CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: @research)
    correction.update!(replayed_at: Time.current, replay_category_id: nil, replay_category_name: nil)

    @research.destroy!
    correction.reload

    refute correction.scorable?
    assert_nil correction.replay_correct?
    assert_nil CategoryFeedbackEvent.scorecard([ correction ]).accuracy_pct
  end

  test "a correction into a since-frozen category is unscorable" do
    record_inference(category: @bugs)
    correction = CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: @research)
    correction.update!(replayed_at: Time.current, replay_category_id: @bugs.id)

    @research.update!(is_frozen: true)

    assert_nil correction.reload.replay_correct?
  end

  test "a correction to Uncategorized stays scorable" do
    record_inference(category: @bugs)
    correction = CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: nil)
    correction.update!(replayed_at: Time.current, replay_category_id: nil)

    assert correction.scorable?
    assert correction.replay_correct?
  end

  test "the decline rate counts each session's latest outcome, not every attempt" do
    # One session declined three times (it paused a lot) and was finally placed;
    # another was placed first time. Neither is a decline now.
    3.times { record_inference(category: nil) }
    record_inference(category: @bugs)
    record_inference(category: @bugs, session: sessions(:running))
    record_inference(category: nil, session: sessions(:needs_input))

    assert_equal({ sampled: 3, declined: 1 }, CategoryFeedbackEvent.decline_rate)
  end

  test "the corpus reads only the rows it returns, and can leave the bodies out" do
    record_inference(category: @bugs)
    CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: @research)

    row = CategoryFeedbackEvent.eval_corpus.without_bodies.first

    refute row.has_attribute?(:context_snapshot)
    assert_equal "Research", row.corrected_label
  end

  test "the decline rate is nil before anything has been categorized" do
    assert_nil CategoryFeedbackEvent.decline_rate
  end
end
