require "test_helper"

module Supervisor
  class TestflightFeedbacksControllerTest < ActionDispatch::IntegrationTest
    setup do
      @crash = TestflightFeedback.create!(
        asc_id: "crash-supervised", kind: "crash", submitted_at: 1.hour.ago, build_number: "212",
        crash_log: AppStoreConnectFixtures::CRASH_LOG, raw_attributes: { "deviceFamily" => "IPHONE" }
      )
    end

    test "should get index" do
      get supervisor_testflight_feedbacks_url

      assert_response :success
      assert_match "crash-supervised", response.body
    end

    test "should show a submission with its crash log" do
      get supervisor_testflight_feedback_url(@crash)

      assert_response :success
      assert_match "EXC_CRASH", response.body
    end

    # A row is what App Store Connect reported; the poller is its only writer.
    test "is read-only" do
      actions = Rails.application.routes.routes
        .select { |route| route.defaults[:controller] == "supervisor/testflight_feedbacks" }
        .map { |route| route.defaults[:action] }

      assert_equal %w[index show], actions.sort
      assert_empty TestflightFeedbackDashboard::FORM_ATTRIBUTES
    end
  end
end
