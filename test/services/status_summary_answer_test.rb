# frozen_string_literal: true

require "test_helper"

# The one definition of "is this an answer or is the runtime refusing to give
# one", shared by the fork path and the pool-independent one-shot path.
class StatusSummaryAnswerTest < ActiveSupport::TestCase
  test "a genuine blurb passes through" do
    text = "The PR is open and CI is green. Waiting on a human to merge."

    assert_equal text, StatusSummaryAnswer.clean(text)
  end

  test "blank text is not an answer" do
    assert_nil StatusSummaryAnswer.clean(nil)
    assert_nil StatusSummaryAnswer.clean("")
    assert_nil StatusSummaryAnswer.clean("   \n  ")
  end

  test "a fenced answer is unwrapped" do
    assert_equal "The PR is open.", StatusSummaryAnswer.clean("```markdown\nThe PR is open.\n```")
    assert_equal "The PR is open.", StatusSummaryAnswer.clean("```\nThe PR is open.\n```")
  end

  test "a fence with nothing in it is not an answer" do
    assert_nil StatusSummaryAnswer.clean("```\n```")
  end

  # The defect this module exists to prevent: stored as a summary, a refusal is
  # stamped at the requested line count — i.e. labelled CURRENT — so nothing
  # ever replaces it.
  test "the runtime's own refusals are rejected" do
    [
      "You've hit your session limit · resets 10pm (UTC)",
      "You've hit your weekly limit · resets Aug 22, 11am (UTC)",
      "Not logged in · Please run /login"
    ].each do |refusal|
      assert_nil StatusSummaryAnswer.clean(refusal), "#{refusal.inspect} must not become a blurb"
      assert StatusSummaryAnswer.refusal?(refusal)
    end
  end

  # The patterns are single-line, so a refusal wrapped across lines would slip
  # past a raw match.
  test "a refusal split over lines is still a refusal" do
    assert_nil StatusSummaryAnswer.clean("You've hit your session limit ·\nresets 10pm (UTC)")
  end

  # Length is what keeps the patterns off a real summary that happens to be
  # ABOUT a session which hit a limit.
  test "a real summary that talks about a limit is still an answer" do
    text = "The run stopped when the account hit its session limit, so the migration " \
           "never applied. See [the failing step](https://example.com/runs/1) — it needs a rerun " \
           "once the window resets, and nothing else is outstanding on this branch."

    assert_equal text, StatusSummaryAnswer.clean(text)
    assert_not StatusSummaryAnswer.refusal?(text)
  end

  test "an over-long answer is truncated to the panel's cap" do
    cleaned = StatusSummaryAnswer.clean("word " * 5_000)

    assert_equal StatusSummaryAnswer::MAX_SUMMARY_CHARS, cleaned.length
  end
end
