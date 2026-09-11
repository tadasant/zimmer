require "test_helper"

# An unknown goal id is refused wherever a goal is stored. Before this, any string
# was a legal goal, so a typo in an id fell through as free text and reached the
# agent as the goal itself (tadasant/zimmer#88).
class GoalReferenceValidatorTest < ActiveSupport::TestCase
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  def build_session(goal:)
    Session.new(agent_runtime: "claude_code", status: :waiting, prompt: "p", git_root: "https://github.com/test/repo.git", goal: goal)
  end

  # ---- the rule ----

  test "a known goal id is accepted" do
    assert build_session(goal: "open-reviewed-green-pr").valid?
  end

  test "a free-text sentence is accepted" do
    assert build_session(goal: "Fix the flaky login test and open a PR").valid?
  end

  test "a goal description stored verbatim is accepted" do
    assert build_session(goal: GoalsConfig.find("codebase-question").description).valid?
  end

  test "a mistyped goal id is refused, naming the ids that exist" do
    session = build_session(goal: "open-reviewd-green-pr")

    assert_not session.valid?
    message = session.errors.full_messages_for(:goal).first
    assert_includes message, %(Goal "open-reviewd-green-pr" is not a known goal id)
    GoalsConfig.ids.each { |id| assert_includes message, id }
  end

  test "the example id the start_session tool used to advertise is refused" do
    # `pr_merged` was the MCP tool's documented example and never a goal.
    assert_not build_session(goal: "pr_merged").valid?
  end

  test "a blank goal is not an id" do
    assert build_session(goal: nil).valid?
    assert build_session(goal: "").valid?
  end

  # ---- only a write that sets the goal is judged ----

  test "a session already holding an unknown id can still be saved" do
    session = build_session(goal: "Fix it")
    session.save!
    session.update_column(:goal, "retired-goal-id")

    session.reload.title = "Renamed"
    assert session.save, session.errors.full_messages.inspect
  end

  # ---- every model that stores a goal ----

  test "a trigger refuses an unknown goal id" do
    trigger = triggers(:enabled_slack_trigger)
    trigger.goal = "retired-goal-id"

    assert_not trigger.valid?
    assert trigger.errors.of_kind?(:goal, :unknown_goal_id)
  end

  test "a trigger with a free-text goal is valid" do
    trigger = triggers(:enabled_slack_trigger)
    trigger.goal = "PR is merged"

    assert trigger.valid?, trigger.errors.full_messages.inspect
  end

  test "an enqueued message refuses an unknown goal id" do
    message = EnqueuedMessage.new(session: sessions(:running), content: "Next", goal: "retired-goal-id", position: 1)

    assert_not message.valid?
    assert message.errors.of_kind?(:goal, :unknown_goal_id)
  end

  test "an enqueued message repeating its session's own goal is not judged" do
    session = sessions(:running)
    session.update_column(:goal, "retired-goal-id")
    message = EnqueuedMessage.new(session: session, content: "Next", goal: "retired-goal-id", position: 1)

    assert message.valid?, message.errors.full_messages.inspect
  end
end
