# frozen_string_literal: true

require "test_helper"

# The unit-level boundaries of the lost-clone rebuild (#817). The job-level proof —
# that the rebuild actually happens, and that a failure which should stay terminal
# still does — is in test/jobs/agent_session_job_lost_clone_recovery_test.rb.
class Sessions::RecoverLostCloneTest < ActiveSupport::TestCase
  CLONE_PATH = "/tmp/recover-lost-clone-service-test"

  setup do
    @session = Session.create!(
      prompt: "Implement the thing",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "feature/x",
      execution_provider: "local_filesystem",
      session_id: SecureRandom.uuid,
      status: :running,
      metadata: { "clone_path" => CLONE_PATH, "working_directory" => CLONE_PATH },
      transcript: { "type" => "user", "message" => { "content" => "hi" } }.to_json
    )
  end

  test "a session with a conversation is recovered, and the turn carries the lost-clone notice" do
    result = Sessions::RecoverLostClone.call(@session, clone_path: CLONE_PATH)

    assert result.recovered?
    assert_equal 1, RetryBudget::LOST_CLONE.count_for(@session.reload)
    assert_includes @session.metadata["pending_follow_up_prompt"], "Zimmer has rebuilt it by re-cloning"
  end

  test "the clone path is left on the row so the follow-up path knows what to rebuild" do
    Sessions::RecoverLostClone.call(@session, clone_path: CLONE_PATH)

    @session.reload
    assert_equal CLONE_PATH, @session.metadata["clone_path"],
                 "the follow-up path reads clone_path to see the tree is missing, and hands it to " \
                 "SessionClonePath#for_recreate so the transcript directory keeps one slug (#576)"
    assert_equal CLONE_PATH, @session.metadata["working_directory"]
  end

  test "a session with no conversation is declined, so the unstarted-turn path owns it" do
    @session.update!(transcript: nil)

    result = Sessions::RecoverLostClone.call(@session, clone_path: CLONE_PATH)

    assert result.declined?
    assert_equal 0, RetryBudget::LOST_CLONE.count_for(@session.reload)
  end

  # `git_root` is required on the model, so this is the row that lost it some other
  # way. The guard exists because the rebuild is meaningless without it — exactly as
  # the follow-up path's own "no git_root to recreate" guard does.
  test "a session with no git_root is declined rather than sent to rebuild from nothing" do
    @session.update_column(:git_root, nil)

    result = Sessions::RecoverLostClone.call(@session.reload, clone_path: CLONE_PATH)

    assert result.declined?
    assert_equal 0, RetryBudget::LOST_CLONE.count_for(@session.reload)
  end

  test "the budget is spent per attempt and then abandons" do
    2.times { assert Sessions::RecoverLostClone.call(@session.reload, clone_path: CLONE_PATH).recovered? }

    result = Sessions::RecoverLostClone.call(@session.reload, clone_path: CLONE_PATH)

    assert result.abandoned?
    assert_equal RetryBudget::LOST_CLONE.max, RetryBudget::LOST_CLONE.count_for(@session.reload)
    assert_includes @session.reload.metadata[Sessions::RecoverLostClone::ABANDONED_KEY].to_s,
                    "gone missing again"
  end

  # A stable stretch hands the budget back, so a session that loses its clone twice a
  # week is not one failure away from terminal for the rest of its life (#727).
  test "the budget is handed back after a stable stretch" do
    budget = RetryBudget::LOST_CLONE
    started = Time.utc(2026, 9, 5, 12, 0, 0)
    travel_to(started) { budget.record!(@session) }

    travel_to(started + 5.minutes) do
      assert_not_nil budget.reset_if_stable!(@session, since: budget.last_attempt_at(@session))
    end

    assert_equal 0, budget.count_for(@session.reload)
  end

  test "a recovery that raises declines rather than taking the failure path down with it" do
    @session.stub(:deliver_follow_up!, ->(*) { raise "boom" }) do
      result = Sessions::RecoverLostClone.call(@session, clone_path: CLONE_PATH)

      assert result.declined?
      assert_equal "boom", result.message
    end
  end
end
