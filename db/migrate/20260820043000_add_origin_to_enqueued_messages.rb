# frozen_string_literal: true

# Records who wrote a queued message, so Zimmer can tell its own notices from
# a caller's.
#
# The queue has always been able to answer "what does this message say" and
# never "who wrote it", which is fine while every reader treats the rows alike
# and wrong at the one place that must not: the alert on
# `Session#strand_pending_enqueued_messages`. That alert exists because a
# message accepted from a human and then discarded is otherwise found out from
# the human noticing. Zimmer's own PR-merged notice has no such reader — its
# whole instruction is "the PR merged; archive if nothing is left" — so an
# archive that discards it is compliance rather than loss, and paging a human
# about it is noise.
#
# `caller` is the default and covers every pre-existing row. It is the wider
# bucket of the two and deliberately so: the queue is written from eight
# places — the web form, two REST endpoints, MCP `manage_enqueued_messages`
# and `action_session`, a trigger's follow-up, the comment poller — and all of
# them are relaying something somebody else said, which is exactly the case the
# strand alert exists for. Only AutomatedSessionMessage writes a notice Zimmer
# addressed to a session on its own behalf, and only the merged-PR one of those
# is a notice an archive answers.
class AddOriginToEnqueuedMessages < ActiveRecord::Migration[8.0]
  def up
    add_column :enqueued_messages, :origin, :string, null: false, default: "caller"

    # Backfill the notices already queued. Matching on content is available
    # only here, and only because these two templates have been stable text
    # since they were written — from now on the column carries the answer and
    # nothing has to read the body to find it.
    backfill("automated_pr_merged", "PR %, associated with this session, has been merged. This is Zimmer reporting a state change%")
    backfill("automated_merge_conflict", "There are merge conflicts on your PR (%")
  end

  def down
    remove_column :enqueued_messages, :origin
  end

  private

  # Anchored at the start of the body and matched across a long run of the
  # template, not on a short phrase anywhere in it. A caller could in principle
  # paste text that satisfies a loose match, and mis-stamping a caller's message
  # would exempt it from the strand alert permanently. Bounded to the two
  # statuses any reader consults, so a `sent`/`processing` row in flight is left
  # alone.
  def backfill(origin, body_pattern)
    execute(<<~SQL.squish)
      UPDATE enqueued_messages
      SET origin = #{connection.quote(origin)}, updated_at = NOW()
      WHERE status IN ('pending', 'undelivered')
        AND content LIKE #{connection.quote("[AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]%#{body_pattern}")}
    SQL
  end
end
