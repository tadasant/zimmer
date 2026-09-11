require "test_helper"
require "mocha/minitest"

# Replay is the tight loop from tadasant/zimmer#16: edit a description, re-score
# the corrections, read the number. It is only worth anything if it is a real dry
# run (no session writes) and hermetic (it scores the stored snapshot, not a live
# transcript).
class CategorizationReplayJobTest < ActiveJob::TestCase
  setup do
    CategoryFeedbackEvent.delete_all
    Category.delete_all
    AppSetting.delete_all
    @bugs = Category.create!(name: "Bugs", description: "Defects")
    @research = Category.create!(name: "Research", description: "Spikes")
    @session = sessions(:waiting)
    @session.update!(category_id: @research.id)

    CategoryFeedbackEvent.record_inference_outcome!(
      session: @session, category: @bugs, raw_answer: "CATEGORY: Bugs",
      context: "the stored snapshot", context_source: "transcript",
      title_requested: true, model: "haiku",
      prompt_version: CategorizationService::PROMPT_VERSION, candidates: [ @bugs, @research ]
    )
    @correction = CategoryFeedbackEvent.record_correction!(session: @session, corrected_category: @research)
    @inference = mock("HeadlessInferenceService")
  end

  test "it runs on the inference lane" do
    assert_equal "inference", CategorizationReplayJob.new.queue_name
  end

  test "it re-scores the stored snapshot and records the verdict on the correction" do
    @inference.expects(:generate).with(includes("the stored snapshot"), anything).returns("TITLE: x\nCATEGORY: Research")

    CategorizationReplayJob.perform_now(10, inference_service: @inference)

    @correction.reload
    refute_nil @correction.replayed_at
    assert_equal @research.id, @correction.replay_category_id
    assert_equal "Research", @correction.replay_category_name
    assert_equal CategorizationService::PROMPT_VERSION, @correction.replay_prompt_version
    assert @correction.replay_correct?
  end

  test "it asks the same shape of question the live answer came from" do
    # The live call requested a title, so the replay prompt must too.
    @inference.expects(:generate).with(includes("- TITLE:"), anything).returns("TITLE: x\nCATEGORY: Bugs")

    CategorizationReplayJob.perform_now(10, inference_service: @inference)

    refute @correction.reload.replay_correct?
  end

  test "it writes no session: not the category, not the title, not a timeline note" do
    @session.update!(title: "The title a human gave it")
    title_before = @session.title
    logs_before = @session.logs.count
    @inference.expects(:generate).returns("TITLE: A brand new title\nCATEGORY: Bugs")

    CategorizationReplayJob.perform_now(10, inference_service: @inference)

    @session.reload
    assert_equal @research.id, @session.category_id
    assert_equal title_before, @session.title
    assert_equal logs_before, @session.logs.count
  end

  test "it needs no transcript and no session at all" do
    @session.destroy!
    @inference.expects(:generate).returns("CATEGORY: Research")

    CategorizationReplayJob.perform_now(10, inference_service: @inference)

    assert @correction.reload.replay_correct?
  end

  test "the current guidance reaches the replayed prompt" do
    AppSetting.create!(category_guidance: "Spikes are always Research.")
    @inference.expects(:generate).with(includes("Spikes are always Research."), anything).returns("CATEGORY: Research")

    CategorizationReplayJob.perform_now(10, inference_service: @inference)
  end

  test "a backend that did not answer leaves the previous verdict alone" do
    @correction.update!(replayed_at: 1.day.ago, replay_category_id: @research.id, replay_category_name: "Research")
    @inference.expects(:generate).returns(nil)

    CategorizationReplayJob.perform_now(10, inference_service: @inference)

    assert_in_delta 1.day.ago.to_f, @correction.reload.replayed_at.to_f, 5
  end

  test "one row that raises does not abandon the batch" do
    other = sessions(:running)
    CategoryFeedbackEvent.record_inference_outcome!(
      session: other, category: @bugs, raw_answer: "CATEGORY: Bugs", context: "other snapshot",
      context_source: "prompt", title_requested: false, model: "haiku",
      prompt_version: CategorizationService::PROMPT_VERSION, candidates: [ @bugs, @research ]
    )
    other_correction = CategoryFeedbackEvent.record_correction!(session: other, corrected_category: @research)

    @inference.stubs(:generate).with(includes("other snapshot"), anything).raises(StandardError, "boom")
    @inference.stubs(:generate).with(includes("the stored snapshot"), anything).returns("TITLE: x\nCATEGORY: Research")

    CategorizationReplayJob.perform_now(10, inference_service: @inference)

    assert_nil other_correction.reload.replayed_at
    assert @correction.reload.replay_correct?
  end

  test "a correction into a since-frozen category is not replayed" do
    @research.update!(is_frozen: true)
    @inference.expects(:generate).never

    CategorizationReplayJob.perform_now(10, inference_service: @inference)

    assert_nil @correction.reload.replayed_at
  end

  test "enqueue reports a refused enqueue as not started" do
    refused = CategorizationReplayJob.new(10)
    refused.successfully_enqueued = false
    CategorizationReplayJob.stubs(:perform_later).returns(refused)

    refute CategorizationReplayJob.enqueue(10)
  end

  test "only one replay may be queued or running at a time" do
    config = CategorizationReplayJob.good_job_concurrency_config

    assert_equal 1, config[:total_limit]
  end

  test "the batch size is clamped" do
    assert_equal CategorizationReplayJob::MAX_LIMIT, CategorizationReplayJob.clamp_limit(10_000)
    assert_equal 1, CategorizationReplayJob.clamp_limit(0)
    assert_equal CategorizationReplayJob::DEFAULT_LIMIT, CategorizationReplayJob.clamp_limit("junk")
  end
end
