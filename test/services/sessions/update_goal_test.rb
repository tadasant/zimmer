# frozen_string_literal: true

require "test_helper"

class Sessions::UpdateGoalTest < ActiveSupport::TestCase
  def session_with_goal(goal)
    Session.create!(git_root: "https://github.com/t/r.git", prompt: "x", status: :needs_input, goal: goal)
  end

  def log_contents(session)
    session.logs.order(:created_at).pluck(:content)
  end

  # --- the write --------------------------------------------------------------

  test "writes the goal stripped and logs it, labelled by the actor" do
    session = session_with_goal(nil)

    result = Sessions::UpdateGoal.call(session: session, goal: "  Ship the PR  ", actor: :mcp)

    assert_equal "Ship the PR", session.reload.goal
    assert_nil result.previous_goal
    assert result.changed?
    assert_equal [ "Goal set via MCP" ], log_contents(session)
  end

  test "each actor's log row reads the way its door wrote it" do
    { web: "Goal updated", mcp: "Goal updated via MCP", rest: "Goal updated via the REST API" }.each do |actor, line|
      session = session_with_goal("Old goal")
      Sessions::UpdateGoal.call(session: session, goal: "New goal", actor: actor)
      assert_equal [ line ], log_contents(session), "actor #{actor}"
    end
  end

  test "set, updated and cleared are told apart" do
    session = session_with_goal(nil)

    Sessions::UpdateGoal.call(session: session, goal: "First", actor: :web)
    Sessions::UpdateGoal.call(session: session, goal: "Second", actor: :web)
    Sessions::UpdateGoal.call(session: session, goal: "", actor: :web)

    assert_equal [ "Goal set", "Goal updated", "Goal cleared" ], log_contents(session)
  end

  test "a blank goal clears it to NULL" do
    [ nil, "", "   " ].each do |blank|
      session = session_with_goal("Old goal")

      result = Sessions::UpdateGoal.call(session: session, goal: blank, actor: :rest)

      assert_nil session.reload.goal, "#{blank.inspect} clears it"
      assert_equal "Old goal", result.previous_goal
      assert_equal [ "Goal cleared via the REST API" ], log_contents(session)
    end
  end

  test "the goal the session already has writes no log row" do
    session = session_with_goal("Same goal")

    result = nil
    assert_no_difference -> { session.logs.count } do
      result = Sessions::UpdateGoal.call(session: session, goal: " Same goal ", actor: :web)
    end

    assert_not result.changed?
  end

  test "clearing an already-empty goal writes no log row" do
    session = session_with_goal(nil)

    assert_no_difference -> { session.logs.count } do
      Sessions::UpdateGoal.call(session: session, goal: "", actor: :web)
    end
  end

  test "a retry after a failed write still logs the change" do
    # A failed UPDATE leaves the new goal on the in-memory record; the retry
    # must compare against what is stored, not read it as a no-op.
    session = session_with_goal("Old goal")
    session.goal = "New goal"

    result = Sessions::UpdateGoal.call(session: session, goal: "New goal", actor: :web)

    assert_equal "Old goal", result.previous_goal
    assert_equal "New goal", session.reload.goal
    assert_equal [ "Goal updated" ], log_contents(session)
  end

  test "a failed log write rolls the goal back with it" do
    session = session_with_goal("Old goal")

    session.logs.stub(:create!, ->(**) { raise ActiveRecord::ConnectionFailed, "simulated" }) do
      assert_raises(ActiveRecord::ConnectionFailed) do
        Sessions::UpdateGoal.call(session: session, goal: "New goal", actor: :web)
      end
    end

    assert_equal "Old goal", session.reload.goal
  end

  # --- the refusals -----------------------------------------------------------

  test "an over-length goal is refused, not cut short, and nothing is written" do
    session = session_with_goal("Old goal")

    error = assert_raises(Sessions::UpdateGoal::TooLong) do
      Sessions::UpdateGoal.call(session: session, goal: "x" * (Session::GOAL_MAX_LENGTH + 1), actor: :web)
    end

    assert_equal "Goal is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters)", error.message
    assert_equal "is too long (maximum #{Session::GOAL_MAX_LENGTH.to_fs(:delimited)} characters)", error.reason
    assert_equal "Old goal", session.reload.goal
    assert_empty session.logs
  end

  test "a goal of exactly the maximum length is written" do
    session = session_with_goal(nil)
    goal = "#{'x ' * ((Session::GOAL_MAX_LENGTH / 2) - 1)}xx"
    assert_equal Session::GOAL_MAX_LENGTH, goal.length

    Sessions::UpdateGoal.call(session: session, goal: goal, actor: :web)

    assert_equal goal, session.reload.goal
  end

  test "an unknown goal id is refused and nothing is written" do
    session = session_with_goal("Old goal")

    error = assert_raises(Sessions::UpdateGoal::UnknownGoalId) do
      Sessions::UpdateGoal.call(session: session, goal: "pr_merged", actor: :mcp)
    end

    assert_equal GoalsConfig.unknown_id_message("pr_merged"), error.message
    assert_equal GoalsConfig.unknown_id_reason("pr_merged"), error.reason
    assert_equal "Old goal", session.reload.goal
    assert_empty session.logs
  end

  test "a known goal id is written" do
    session = session_with_goal(nil)

    Sessions::UpdateGoal.call(session: session, goal: "codebase-question", actor: :web)

    assert_equal "codebase-question", session.reload.goal
  end

  test "re-sending a goal id since retired from the catalog is not refused" do
    session = session_with_goal(nil)
    session.update_column(:goal, "retired-goal-id")

    assert_nothing_raised do
      Sessions::UpdateGoal.call(session: session, goal: "retired-goal-id", actor: :rest)
    end
    assert_empty session.logs
  end

  # --- composing the save -----------------------------------------------------

  test "attributes the caller assigned ride the same save" do
    session = session_with_goal("Old goal")
    session.slug = "renamed-slug"

    Sessions::UpdateGoal.call(session: session, goal: "New goal", actor: :rest)

    session.reload
    assert_equal "New goal", session.goal
    assert_equal "renamed-slug", session.slug
  end

  test "a block does the save, and the log row follows it" do
    session = session_with_goal("Old goal")
    saves = 0

    Sessions::UpdateGoal.call(session: session, goal: "New goal", actor: :rest) do
      assert_equal "New goal", session.goal, "assigned before the block runs"
      assert_empty session.logs.reload, "logged after the block's save"
      saves += 1
      session.save!
    end

    assert_equal 1, saves
    assert_equal "New goal", session.reload.goal
    assert_equal [ "Goal updated via the REST API" ], log_contents(session)
  end

  test "a refused goal never runs the block" do
    session = session_with_goal("Old goal")

    assert_raises(Sessions::UpdateGoal::UnknownGoalId) do
      Sessions::UpdateGoal.call(session: session, goal: "pr_merged", actor: :rest) { flunk "the save ran" }
    end
  end
end
