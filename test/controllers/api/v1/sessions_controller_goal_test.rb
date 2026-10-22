# frozen_string_literal: true

require "test_helper"

# `goal` on `PATCH /api/v1/sessions/:id`: Sessions::UpdateGoal's write, kept in
# one save with the PATCH's other columns.
class Api::V1::SessionsControllerGoalTest < ActionDispatch::IntegrationTest
  setup do
    @valid_api_key = "test_api_key_12345"
    @headers = { "X-API-Key" => @valid_api_key }
    ENV["API_KEYS"] = @valid_api_key
  end

  teardown do
    ENV.delete("API_KEYS")
  end

  test "the goal write goes through Sessions::UpdateGoal and is logged" do
    session = needs_input_session(goal: nil)
    calls = []
    real_call = Sessions::UpdateGoal.method(:call)
    spy = lambda do |**kwargs, &blk|
      calls << kwargs
      real_call.call(**kwargs, &blk)
    end

    Sessions::UpdateGoal.stub(:call, spy) do
      patch "/api/v1/sessions/#{session.id}", params: { goal: "  Ship the PR  " }, headers: @headers
    end

    assert_response :success
    assert_equal 1, calls.size
    assert_equal :rest, calls.first[:actor]
    assert_equal "Ship the PR", JSON.parse(response.body)["session"]["goal"]
    assert_equal "Ship the PR", session.reload.goal
    assert_equal [ "Goal set via the REST API" ], goal_logs(session)
  end

  test "an empty goal clears it to null and logs the clear" do
    session = needs_input_session(goal: "Old goal")

    patch "/api/v1/sessions/#{session.id}", params: { goal: "" }, headers: @headers

    assert_response :success
    assert_nil JSON.parse(response.body)["session"]["goal"]
    assert_nil session.reload.goal
    assert_equal [ "Goal cleared via the REST API" ], goal_logs(session)
  end

  test "an unchanged goal writes no log row" do
    session = needs_input_session(goal: "Same goal")

    assert_no_difference -> { session.logs.count } do
      patch "/api/v1/sessions/#{session.id}", params: { goal: "Same goal" }, headers: @headers
    end
    assert_response :success
  end

  test "an over-length goal refuses the whole PATCH with the model's wording" do
    session = needs_input_session(goal: "Old goal")
    session.update_columns(slug: "old-slug")

    patch "/api/v1/sessions/#{session.id}", params: { slug: "new-slug", goal: "a sentence " * 5_000 }, headers: @headers

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_equal "Validation failed", json["error"]
    assert_includes json["message"], "Goal is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters)"
    session.reload
    assert_equal "Old goal", session.goal
    assert_equal "old-slug", session.slug
    assert_empty goal_logs(session)
  end

  test "an unknown goal id alongside a scheduling class refuses the whole PATCH" do
    session = needs_input_session(goal: "Old goal")

    patch "/api/v1/sessions/#{session.id}", params: { goal: "pr_merged", scheduling_class: "priority" }, headers: @headers

    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["message"], GoalsConfig.unknown_id_message("pr_merged")
    session.reload
    assert_equal "Old goal", session.goal
    assert_nil session.scheduling_class
    assert_empty session.logs.where("content LIKE 'Goal%' OR content LIKE 'Scheduling class%'")
  end

  # The goal and the PATCH's other columns are one save, so the after_commit
  # callbacks keyed on those columns still see them: the goal check panel's
  # repaint (`saved_change_to_goal?`) and the replacement back-reference that
  # `custom_metadata` drives.
  test "a goal change alongside custom_metadata keeps both columns' after-commit work" do
    replaced = needs_input_session(goal: nil)
    session = needs_input_session(goal: "Old goal")
    Session.any_instance.expects(:broadcast_goal_check_panel).at_least_once

    patch "/api/v1/sessions/#{session.id}",
      params: { goal: "New goal", custom_metadata: { Session::REPLACES_SESSION_KEY => replaced.id.to_s } },
      headers: @headers, as: :json

    assert_response :success
    assert_equal "New goal", session.reload.goal
    assert_equal session.id.to_s, replaced.reload.custom_metadata[Session::REPLACED_BY_SESSION_KEY].to_s
  end

  test "a goal and a scheduling class go in one save, each with its log row" do
    replaced = needs_input_session(goal: nil)
    session = needs_input_session(goal: "Old goal")
    session.update!(scheduling_class: SessionGenesis::PRIORITY)
    Session.any_instance.expects(:broadcast_goal_check_panel).at_least_once

    patch "/api/v1/sessions/#{session.id}",
      params: { goal: "New goal", scheduling_class: "spot",
                custom_metadata: { Session::REPLACES_SESSION_KEY => replaced.id.to_s } },
      headers: @headers, as: :json

    assert_response :success
    session.reload
    assert_equal "New goal", session.goal
    assert session.spot?
    assert_equal session.id.to_s, replaced.reload.custom_metadata[Session::REPLACED_BY_SESSION_KEY].to_s
    logs = session.logs.pluck(:content)
    assert_includes logs, "Goal updated via the REST API"
    assert_includes logs, "Scheduling class set via the REST API to spot (was priority)"
  end

  test "a PATCH without a goal leaves the goal and its log alone" do
    session = needs_input_session(goal: "Old goal")

    patch "/api/v1/sessions/#{session.id}", params: { slug: "another-slug" }, headers: @headers

    assert_response :success
    session.reload
    assert_equal "Old goal", session.goal
    assert_equal "another-slug", session.slug
    assert_empty goal_logs(session)
  end

  private

  def needs_input_session(goal:)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", status: :needs_input, goal: goal)
  end

  def goal_logs(session)
    session.logs.order(:created_at).pluck(:content).grep(/\AGoal /)
  end
end
