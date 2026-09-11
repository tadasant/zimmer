require "test_helper"

module Supervisor
  class WorkflowRunsControllerTest < ActionDispatch::IntegrationTest
    include SupervisorAuthTestHelper
    include SupervisorAuthTestHelper::AutoBasicAuth

    setup do
      session = Session.create_from_agent_root!(agent_root_name: "zimmer", prompt: "Restate: hi", skip_enqueue: true)
      @run = WorkflowRun.create!(
        session: session, trigger: triggers(:enabled_schedule_trigger), workflow_id: "echo",
        input: { "message" => "hi" }, resolved: { "reply_channel_id" => "C08ABCDEF" }
      )
    end

    test "should get index" do
      get supervisor_workflow_runs_url

      assert_response :success
      assert_match "echo", response.body
    end

    test "should show a run, with what it was started with and bound to" do
      get supervisor_workflow_run_url(@run)

      assert_response :success
      assert_match "echo", response.body
      assert_match "C08ABCDEF", response.body
    end

    # A run's `resolved` identifiers are only worth trusting if nothing but the
    # workflow's #plan wrote them, so the panel offers no form and no Delete.
    test "the panel is read-only" do
      actions = Rails.application.routes.routes
        .select { |route| route.defaults[:controller] == "supervisor/workflow_runs" }
        .map { |route| route.defaults[:action] }

      assert_equal %w[index show], actions.sort
      assert_empty WorkflowRunDashboard::FORM_ATTRIBUTES
    end
  end
end
