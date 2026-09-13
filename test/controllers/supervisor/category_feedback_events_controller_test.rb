require "test_helper"

module Supervisor
  class CategoryFeedbackEventsControllerTest < ActionDispatch::IntegrationTest
    setup do
      CategoryFeedbackEvent.delete_all
      Category.delete_all
      @bugs = Category.create!(name: "Bugs")
      @event = CategoryFeedbackEvent.record_inference_outcome!(
        session: sessions(:waiting), category: @bugs, raw_answer: "CATEGORY: Bugs",
        context: "the snapshot the model saw", context_source: "transcript",
        title_requested: true, model: "haiku",
        prompt_version: CategorizationService::PROMPT_VERSION, candidates: [ @bugs ]
      )
    end

    test "should get index" do
      get supervisor_category_feedback_events_url

      assert_response :success
      assert_match "auto_assigned", response.body
      assert_match "Bugs", response.body
    end

    test "should show an event, snapshot included" do
      get supervisor_category_feedback_event_url(@event)

      assert_response :success
      assert_match "the snapshot the model saw", response.body
    end

    # The corpus is evidence of what a model or a human actually did; a row
    # somebody could hand-author or delete here would not be evidence of anything.
    test "the corpus is read-only" do
      actions = Rails.application.routes.routes
        .select { |route| route.defaults[:controller] == "supervisor/category_feedback_events" }
        .map { |route| route.defaults[:action] }

      assert_equal %w[index show], actions.sort
      assert_empty CategoryFeedbackEventDashboard::FORM_ATTRIBUTES
    end
  end
end
