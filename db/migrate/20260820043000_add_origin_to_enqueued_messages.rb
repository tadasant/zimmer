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
# `caller` is the default and covers every pre-existing row: the three create
# surfaces (the web queue form, the REST endpoint, MCP
# `manage_enqueued_messages`) all write on someone's behalf, and only
# AutomatedSessionMessage writes a notice of Zimmer's own.
class AddOriginToEnqueuedMessages < ActiveRecord::Migration[8.0]
  def up
    add_column :enqueued_messages, :origin, :string, null: false, default: "caller"

    # Backfill the notices already queued. Matching on content is available
    # only here, and only because these two templates have been stable text
    # since they were written — from now on the column carries the answer and
    # nothing has to read the body to find it.
    backfill("automated_pr_merged", ", associated with this session, has been merged.")
    backfill("automated_merge_conflict", "There are merge conflicts on your PR (")
  end

  def down
    remove_column :enqueued_messages, :origin
  end

  private

  def backfill(origin, marker)
    execute(<<~SQL.squish)
      UPDATE enqueued_messages
      SET origin = #{connection.quote(origin)}, updated_at = NOW()
      WHERE content LIKE #{connection.quote("%#{marker}%")}
        AND content LIKE '[AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]%'
    SQL
  end
end
