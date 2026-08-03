# Renumbering a queue after a delete runs a single bulk decrement:
#
#   UPDATE enqueued_messages SET position = position - 1 WHERE position > N
#
# Postgres checks a unique *index* per row, not at statement end, so that
# statement is only correct if the planner happens to visit rows in ascending
# position order — the row moving 3 -> 2 has to land before the row moving
# 4 -> 3. Nothing pins that order, so any other scan order (a seq scan over a
# heap whose live tuples happen to be laid out high-position-first, for
# instance) collides with a row the statement has not moved yet and the whole
# delete rolls back with a 500.
#
# Promoting the unique index to a DEFERRABLE INITIALLY DEFERRED unique
# constraint moves the check to commit time, where only the final state of the
# transaction matters. Uniqueness is not weakened: a transaction that would
# leave two rows sharing (session_id, position) still fails, it just fails at
# COMMIT instead of mid-statement.
#
# `USING INDEX` adopts the existing index rather than rebuilding it, so this is
# a catalog-only change — no table scan, no window without an enforced unique.
class DeferEnqueuedMessagePositionUniqueness < ActiveRecord::Migration[8.1]
  CONSTRAINT_NAME = "index_enqueued_messages_on_session_id_and_position"

  def up
    add_unique_constraint :enqueued_messages,
                          name: CONSTRAINT_NAME,
                          using_index: CONSTRAINT_NAME,
                          deferrable: :deferred
  end

  def down
    # Dropping the constraint drops the index it adopted, so put the plain
    # unique index back under the same name.
    remove_unique_constraint :enqueued_messages, name: CONSTRAINT_NAME
    add_index :enqueued_messages, [ :session_id, :position ], unique: true, name: CONSTRAINT_NAME
  end
end
