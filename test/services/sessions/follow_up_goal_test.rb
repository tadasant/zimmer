require "test_helper"
require "mocha/minitest"

# Sessions::FollowUpGoal is the single writer behind the four surfaces that can
# apply a goal alongside a follow-up prompt: the web controller, the REST API,
# the MCP `follow_up` action, and EnqueuedMessageProcessorService claiming a
# queued message. Before it, the same sentence was written out four times (#105).
#
# Two properties matter most: a blank goal PRESERVES rather than clears — except
# on the one surface that can tell an emptied field from an absent one — and the
# goal write shares the caller's single UPDATE rather than becoming a second save.
class Sessions::FollowUpGoalTest < ActiveSupport::TestCase
  def setup
    Session.any_instance.stubs(:broadcast_status_change)
    Session.any_instance.stubs(:broadcast_update_to_sessions_index)
    Session.any_instance.stubs(:broadcast_create_to_sessions_index)
  end

  def make_session(**attrs)
    Session.create!({
      agent_runtime: "claude_code",
      status: :needs_input,
      prompt: "p",
      mcp_servers: [],
      config: {},
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      execution_provider: "local_filesystem"
    }.merge(attrs))
  end

  # === normalize ===

  test "normalize strips whitespace and turns blank into nil" do
    assert_equal "ship it", Sessions::FollowUpGoal.normalize("  ship it  ")
    assert_nil Sessions::FollowUpGoal.normalize("   ")
    assert_nil Sessions::FollowUpGoal.normalize("")
    assert_nil Sessions::FollowUpGoal.normalize(nil)
  end

  # === too_long? ===

  test "too_long? is false for nil, blank and an at-the-limit goal" do
    assert_not Sessions::FollowUpGoal.too_long?(nil)
    assert_not Sessions::FollowUpGoal.too_long?("")
    assert_not Sessions::FollowUpGoal.too_long?("a" * Session::GOAL_MAX_LENGTH)
  end

  test "too_long? is true one character past the limit" do
    assert Sessions::FollowUpGoal.too_long?("a" * (Session::GOAL_MAX_LENGTH + 1))
  end

  # === apply!: the shared rule ===

  test "a non-blank goal that differs overwrites and logs" do
    session = make_session(goal: "old goal")

    changed = Sessions::FollowUpGoal.apply!(session: session, goal: "new goal", source: :follow_up)

    assert changed
    assert_equal "new goal", session.reload.goal
    assert_equal "Goal updated from follow-up", session.logs.order(:id).last.content
  end

  test "a goal identical to the session's is not written and logs nothing" do
    session = make_session(goal: "same goal")
    log_count = session.logs.count

    changed = Sessions::FollowUpGoal.apply!(session: session, goal: "same goal", source: :follow_up)

    assert_not changed
    assert_equal "same goal", session.reload.goal
    assert_equal log_count, session.logs.count
  end

  # The rule the API, the MCP tool and the queue share: a follow-up carrying no
  # goal is not a request to clear the session's goal. Clearing is its own
  # operation (PATCH /api/v1/sessions/:id, `change_goal`).
  test "a blank goal preserves the session's existing goal by default" do
    session = make_session(goal: "keep me")
    log_count = session.logs.count

    [ nil, "" ].each do |blank|
      changed = Sessions::FollowUpGoal.apply!(session: session, goal: blank, source: :follow_up)

      assert_not changed
      assert_equal "keep me", session.reload.goal
      assert_equal log_count, session.logs.count
    end
  end

  # The web follow-up form always submits the goal field, so an emptied box IS a
  # clear — the one surface that opts in.
  test "clear_when_blank: true clears the goal and says removed" do
    session = make_session(goal: "drop me")

    changed = Sessions::FollowUpGoal.apply!(
      session: session, goal: nil, source: :web_follow_up, clear_when_blank: true
    )

    assert changed
    assert_nil session.reload.goal
    assert_equal "Goal removed for this follow-up", session.logs.order(:id).last.content
  end

  test "clear_when_blank: true on a session that already has no goal is a no-op" do
    session = make_session(goal: nil)
    log_count = session.logs.count

    changed = Sessions::FollowUpGoal.apply!(
      session: session, goal: nil, source: :web_follow_up, clear_when_blank: true
    )

    assert_not changed
    assert_nil session.reload.goal
    assert_equal log_count, session.logs.count
  end

  # === log wording stays per-source ===

  test "each source keeps its own log wording" do
    {
      web_follow_up: "Goal updated for this follow-up",
      follow_up: "Goal updated from follow-up",
      enqueued_message: "Goal updated from enqueued message"
    }.each do |source, expected|
      session = make_session(goal: "old")

      Sessions::FollowUpGoal.apply!(session: session, goal: "new", source: source)

      assert_equal expected, session.logs.order(:id).last.content
    end
  end

  test "an unknown source raises rather than logging a mystery line" do
    session = make_session(goal: "old")

    assert_raises(KeyError) do
      Sessions::FollowUpGoal.apply!(session: session, goal: "new", source: :nope)
    end
  end

  # === also_update ===

  # The API and MCP direct branches have always written the prompt and the goal
  # in one UPDATE. Extracting the goal must not turn that into two saves inside
  # their transaction.
  test "also_update writes the prompt and the goal in a single update" do
    session = make_session(goal: "old goal", prompt: "old prompt")

    Sessions::FollowUpGoal.apply!(
      session: session, goal: "new goal", source: :follow_up, also_update: { prompt: "new prompt" }
    )

    session.reload
    assert_equal "new goal", session.goal
    assert_equal "new prompt", session.prompt
  end

  test "also_update still writes when the goal is unchanged" do
    session = make_session(goal: "same goal", prompt: "old prompt")

    changed = Sessions::FollowUpGoal.apply!(
      session: session, goal: nil, source: :follow_up, also_update: { prompt: "new prompt" }
    )

    assert_not changed
    session.reload
    assert_equal "same goal", session.goal
    assert_equal "new prompt", session.prompt
  end

  # === log_with ===

  # EnqueuedMessageProcessorService buffers its log lines when a turn is batching
  # them. The service decides WHAT the line says, never how it is persisted.
  test "log_with receives the line instead of writing it directly" do
    session = make_session(goal: "old")
    captured = []

    Sessions::FollowUpGoal.apply!(
      session: session,
      goal: "new",
      source: :enqueued_message,
      log_with: ->(content) { captured << content }
    )

    assert_equal [ "Goal updated from enqueued message" ], captured
    assert_not_equal "Goal updated from enqueued message", session.logs.order(:id).last&.content
  end

  test "log_with is not called when nothing changed" do
    session = make_session(goal: "same")
    captured = []

    Sessions::FollowUpGoal.apply!(
      session: session,
      goal: "same",
      source: :enqueued_message,
      log_with: ->(content) { captured << content }
    )

    assert_empty captured
  end
end
