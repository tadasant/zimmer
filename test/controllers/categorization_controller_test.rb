require "test_helper"
require "mocha/minitest"

# The categorization tuning page (tadasant/zimmer#16): the knobs, the corpus,
# and the replay button. No shell on the production box, so this page IS the
# tuning loop for an operator.
class CategorizationControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    CategoryFeedbackEvent.delete_all
    Category.delete_all
    AppSetting.delete_all
    @bugs = Category.create!(name: "Bugs", description: "Defects and regressions")
    @research = Category.create!(name: "Research")
  end

  def record_correction(session: sessions(:waiting))
    CategoryFeedbackEvent.record_inference_outcome!(
      session: session, category: @bugs, raw_answer: "CATEGORY: Bugs", context: "snapshot",
      context_source: "transcript", title_requested: false, model: "haiku",
      prompt_version: CategorizationService::PROMPT_VERSION, candidates: [ @bugs, @research ]
    )
    CategoryFeedbackEvent.record_correction!(session: session, corrected_category: @research, source: "web_ui")
  end

  test "show renders the descriptions, the knobs and an empty corpus" do
    get categorization_url

    assert_response :success
    assert_select "h1", "Categorization"
    assert_select "dd", text: "Defects and regressions"
    # A category with no description says what that costs.
    assert_select "dd", text: /only the name to go on/
    assert_select "textarea[name='app_setting[category_guidance]']"
    assert_select "select[name='app_setting[category_inference_model]'] option[value='haiku']"
    assert_match "No corrections recorded yet", response.body
  end

  test "show lists corrections with their replay verdict" do
    correction = record_correction
    correction.update!(replayed_at: Time.current, replay_category_id: @research.id, replay_category_name: "Research")

    get categorization_url

    assert_response :success
    assert_select "li", text: /Bugs.*Research.*replay: Research/m
    assert_match "100", css_select("#replay dd").map(&:text).join
  end

  test "update saves guidance and the model override" do
    patch categorization_url, params: {
      app_setting: { category_guidance: "  Docs PRs are Docs.  ", category_inference_model: "sonnet" }
    }

    assert_redirected_to categorization_path
    setting = AppSetting.current
    assert_equal "Docs PRs are Docs.", setting.category_guidance
    assert_equal "sonnet", setting.category_inference_model
  end

  test "update clears both knobs with blanks" do
    AppSetting.create!(category_guidance: "x", category_inference_model: "sonnet")

    patch categorization_url, params: { app_setting: { category_guidance: "", category_inference_model: "" } }

    setting = AppSetting.current
    assert_nil setting.category_guidance
    assert_nil setting.category_inference_model
  end

  test "update refuses a model the inference runtime cannot run" do
    patch categorization_url, params: { app_setting: { category_inference_model: "gpt-5.5" } }

    assert_redirected_to categorization_path
    assert_match "not available", flash[:alert]
    assert_nil AppSetting.current.category_inference_model
  end

  test "update refuses guidance past the cap" do
    patch categorization_url, params: {
      app_setting: { category_guidance: "x" * (AppSetting::MAX_CATEGORY_GUIDANCE_CHARS + 1) }
    }

    assert_match "too long", flash[:alert]
  end

  test "replay enqueues a bounded job when there are corrections" do
    record_correction

    assert_enqueued_with(job: CategorizationReplayJob, args: [ 10 ]) do
      post categorization_replay_url, params: { limit: 10 }
    end

    assert_redirected_to categorization_path
    assert_match "Replaying 1 correction", flash[:notice]
  end

  test "replay clamps an oversized limit" do
    record_correction

    assert_enqueued_with(job: CategorizationReplayJob, args: [ CategorizationReplayJob::MAX_LIMIT ]) do
      post categorization_replay_url, params: { limit: 100_000 }
    end
  end

  test "replay with nothing to replay says so and enqueues nothing" do
    assert_no_enqueued_jobs(only: CategorizationReplayJob) do
      post categorization_replay_url
    end

    assert_match "Nothing to replay yet", flash[:alert]
  end
end
