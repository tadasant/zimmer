require "test_helper"

module Supervisor
  class PostDeployTaskRunsControllerTest < ActionDispatch::IntegrationTest
    include SupervisorAuthTestHelper
    include SupervisorAuthTestHelper::AutoBasicAuth

    setup do
      @run = PostDeployTaskRun.create!(
        version: "20260501000000", name: "SupervisedExampleTask", status: "succeeded",
        finished_at: Time.current, stats: { "repaired" => 3 }
      )
    end

    test "should get index" do
      get supervisor_post_deploy_task_runs_url

      assert_response :success
      assert_match "SupervisedExampleTask", response.body
      assert_match "20260501000000", response.body
    end

    test "should show a run" do
      get supervisor_post_deploy_task_run_url(@run)

      assert_response :success
      assert_match "SupervisedExampleTask", response.body
    end

    # The ledger is the record of whether a one-time step ran against this
    # environment. Marking one succeeded by hand would assert an application
    # nothing performed, and deleting one would silently make the task run again.
    test "the ledger is read-only" do
      actions = Rails.application.routes.routes
        .select { |route| route.defaults[:controller] == "supervisor/post_deploy_task_runs" }
        .map { |route| route.defaults[:action] }

      assert_equal %w[index show], actions.sort
      assert_empty PostDeployTaskRunDashboard::FORM_ATTRIBUTES
    end
  end
end
