# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260831180000_backfill_recovery_nudge_origin_on_enqueued_messages")

# The backfill in `BackfillRecoveryNudgeOriginOnEnqueuedMessages` matches rows by
# a `LIKE` on the opening of `AutomatedPrompts::SYSTEM_RECOVERY`, and a content
# match is the one thing in this codebase that can be wrong without anything
# saying so. `LIKE` matching zero rows is not an error, and CI never executes
# migrations — `bin/rails db:test:prepare` *loads* `db/schema.rb` — so a broken
# pattern ships as a silent no-op and the alert it was meant to quiet keeps
# firing on every queue that already exists.
#
# That is not hypothetical: the first draft of the migration built its statement
# with `<<~SQL.squish`, which runs `gsub(/[[:space:]]+/, " ")` over the whole
# statement including the quoted literal, flattening the template's blank line to
# a single space. It matched nothing. These assertions are the cheap guard that
# runs on every PR.
class BackfillRecoveryNudgeOriginTest < ActiveSupport::TestCase
  PREFIX = BackfillRecoveryNudgeOriginOnEnqueuedMessages::NUDGE_PREFIX

  # The assertion that would have caught the flattening: a pattern whose newlines
  # have been normalised away is no longer a prefix of anything Zimmer writes.
  test "the LIKE prefix is a genuine prefix of the nudge Zimmer actually sends" do
    assert AutomatedPrompts::SYSTEM_RECOVERY.start_with?(PREFIX),
      "the backfill's pattern no longer opens AutomatedPrompts::SYSTEM_RECOVERY, so it would match no row"
  end

  test "the LIKE prefix keeps the blank line that separates the template's first two lines" do
    assert_includes PREFIX, "\n\n",
      "a whitespace-normalising call (`squish`, `strip_heredoc`, a reflow) has flattened the pattern"
  end

  # The reasoned variant is what the spot-hold sweep actually queued onto session
  # 8810, so it is the shape the backfill has to catch.
  test "the prefix matches a reasoned nudge, which is the shape that produced the page" do
    reasoned = AutomatedPrompts.system_recovery(
      reason: "Zimmer's spot-hold sweep found this session's re-check had stopped firing"
    )

    assert reasoned.start_with?(PREFIX)
    assert AutomatedPrompts.system_recovery?(reasoned),
      "the write-time stamp and the backfill must agree about what a recovery nudge is"
  end

  # Anchored and long, so a caller cannot reach the exemption by pasting a short
  # phrase. Mis-stamping a caller's message would exempt it from the strand alert
  # permanently, which is the one failure mode worse than the page.
  test "the prefix is long and anchored rather than a short phrase" do
    assert_operator PREFIX.length, :>, 150,
      "a short pattern is one a caller could satisfy by accident"
    refute PREFIX.start_with?("%"), "the pattern must be anchored at the start of the body"
  end

  test "the origin it backfills is one the model accepts" do
    assert_includes EnqueuedMessage::ORIGINS, "automated_recovery_nudge"
    assert_includes EnqueuedMessage::SELF_ADDRESSED_ORIGINS, "automated_recovery_nudge"
  end

  # `up` deliberately claims only the two statuses any reader consults; a
  # `sent`/`processing` row is in flight and is left alone.
  test "it is bounded to the statuses a reader of a queue consults" do
    assert_equal %w[pending undelivered],
      BackfillRecoveryNudgeOriginOnEnqueuedMessages::BACKFILLED_STATUSES
  end
end
