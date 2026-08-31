# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# One object, four surfaces. #587 set the precedent that a coverage claim
# rendered several ways must come from one place so the renderings cannot
# disagree; this holds the same line for post-deploy tasks across the /health
# page, GET /api/v1/health, the `get_system_health` MCP tool and the Supervisor
# dashboard (the last of which is covered in
# test/controllers/supervisor/post_deploy_task_runs_controller_test.rb, which has
# the basic-auth helper).
class PostDeployTaskSurfacesTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @api_key = "test_api_key_post_deploy"
    ENV["API_KEYS"] = @api_key
    @headers = { "X-API-Key" => @api_key }

    @blocked = PostDeployTaskRun.create!(
      version: "20260401000000", name: "StuckExampleTask", status: "failed",
      failures: PostDeployTaskRun::RETRY_DELAYS.size + 1,
      last_error: "RuntimeError: the thing that went wrong", last_error_at: Time.current,
      attempts: 6
    )
    @done = PostDeployTaskRun.create!(
      version: "20260401000001", name: "DoneExampleTask", status: "succeeded",
      finished_at: Time.current, stats: { "repaired" => 12 }
    )
  end

  teardown { ENV.delete("API_KEYS") }

  test "the health page names the blocked task, its error and the way to unstick it" do
    get health_dashboard_path

    assert_response :success
    assert_select "h3", text: "Post-Deploy Tasks"
    assert_select "td", text: /StuckExampleTask/
    assert_select "td", text: /DoneExampleTask/
    assert_match "the thing that went wrong", response.body
    assert_match "blocked", response.body
    assert_select "form[action=?]", run_post_deploy_tasks_health_path
  end

  test "the REST health report carries the same counts" do
    get api_v1_health_path, headers: @headers

    assert_response :success
    tasks = JSON.parse(response.body).dig("health_report", "post_deploy_task_health")

    assert_equal 2, tasks["total"]
    assert_equal 1, tasks["succeeded"]
    assert_equal 1, tasks["failed"]
    assert_equal 1, tasks["blocked"]
    assert_equal "critical", tasks.dig("status", "status")
    assert_equal %w[20260401000000 20260401000001], tasks["tasks"].map { |t| t["version"] }
  end

  test "a blocked task drags the overall health status down" do
    get api_v1_health_path, headers: @headers

    assert_equal "critical", JSON.parse(response.body).dig("health_report", "overall_status", "status")
  end

  test "the get_system_health MCP tool reports it too" do
    output = Mcp::Tools::GetSystemHealth.new(context: Mcp::Context.new(tool_groups: "health")).call({})

    assert_match "post_deploy_task_health", output
    assert_match "StuckExampleTask", output
  end

  test "the REST action re-arms the blocked task and enqueues a pass" do
    assert_enqueued_with(job: PostDeployTaskJob) do
      post run_post_deploy_tasks_api_v1_health_path, headers: @headers
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["rearmed"]
    assert_equal "pending", @blocked.reload.status
    assert_equal "succeeded", @done.reload.status
  end

  test "the health page button re-arms and redirects" do
    assert_enqueued_with(job: PostDeployTaskJob) { post run_post_deploy_tasks_health_path }

    assert_redirected_to health_dashboard_path
    assert_equal "pending", @blocked.reload.status
    assert_match(/Re-armed 1 post-deploy task/, flash[:notice])
  end

  test "the MCP action does the same thing as the other two" do
    tool = Mcp::Tools::ActionHealth.new(
      context: Mcp::Context.new(tool_groups: "health", caller_fingerprint: HealthActionCooldown.fingerprint("k"))
    )

    output = nil
    assert_enqueued_with(job: PostDeployTaskJob) { output = tool.call("action" => "run_post_deploy_tasks") }

    assert_match "Post-Deploy Tasks Queued", output
    assert_match "**Re-armed:** 1", output
    assert_equal "pending", @blocked.reload.status
  end

  test "a broken task directory degrades the panel instead of taking the health report down" do
    PostDeployTaskRun.stubs(:summary).raises(PostDeployTask::Registry::InvalidTask, "duplicate version")

    get api_v1_health_path, headers: @headers

    assert_response :success
    tasks = JSON.parse(response.body).dig("health_report", "post_deploy_task_health")
    assert_equal "warning", tasks.dig("status", "status")
    assert_match(/could not be read/, tasks.dig("status", "message"))
  end
end
