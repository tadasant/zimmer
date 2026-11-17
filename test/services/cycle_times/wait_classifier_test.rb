# frozen_string_literal: true

require "test_helper"

class CycleTimes::WaitClassifierTest < ActiveSupport::TestCase
  LATER = "mcp__zimmer-self-session__wake_me_up_later"

  def wake(prompt) = CycleTimes::WaitClassifier.classify_wake(LATER, { "prompt" => prompt }).category

  test "the vendored skills' prompt shapes classify exactly" do
    assert_equal "wait_ci", wake("CI wake 3 on https://github.com/a/b/pull/1. Re-read the wait-for-ci skill.")
    assert_equal "wait_ci", wake("Blocker wake 2 of 6 on https://github.com/a/b/pull/1, blocked by #9.")
    assert_equal "wait_merge_gate", wake("Self-wake 1 of 3 on https://github.com/a/b/pull/1. Re-read the open-pr skill's " \
                                         "Terminal Step 2, then run its PR-state check")
    assert_equal "wait_deploy", wake("Post-merge wake 4 of 10 for https://github.com/a/b/pull/1 (MERGED). Check gh run view")
  end

  test "free-text prompts classify by what they wait for" do
    assert_equal "wait_deploy", wake("The deploy should be done by now; verify it.")
    assert_equal "wait_ci", wake("Check whether CI is green on my PR.")
    assert_equal "wait_merge_gate", wake("See if the PR got merged.")
    assert_equal "wait_sleep", wake("Resume the backlog sweep.")
  end

  test "a state-change watch is a wait on another session" do
    result = CycleTimes::WaitClassifier.classify_wake("mcp__zimmer__wake_me_up_when_session_changes_state", { "session_ids" => [ 4, 5 ] })
    assert_equal "wait_child", result.category
    assert_match "4, 5", result.detail
  end

  test "other tools are not wakes" do
    assert_nil CycleTimes::WaitClassifier.classify_wake("Bash", { "command" => "sleep 5" })
  end

  test "a timed wake carries when it was due, read in its timezone" do
    utc = CycleTimes::WaitClassifier.classify_wake(LATER, { "prompt" => "CI wake 1", "wake_at" => "2026-09-02T02:12:00" })
    assert_equal Time.utc(2026, 9, 2, 2, 12), utc.due

    eastern = CycleTimes::WaitClassifier.classify_wake(LATER, { "prompt" => "x", "wake_at" => "2026-09-02T09:00:00",
                                                                "timezone" => "America/New_York" })
    assert_equal Time.utc(2026, 9, 2, 13), eastern.due

    assert_nil CycleTimes::WaitClassifier.classify_wake(LATER, { "prompt" => "x" }).due
    assert_nil CycleTimes::WaitClassifier.classify_wake(LATER, { "prompt" => "x", "wake_at" => "not a time" }).due
  end
end
