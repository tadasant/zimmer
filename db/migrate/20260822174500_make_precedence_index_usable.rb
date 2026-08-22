# frozen_string_literal: true

# The ranked index, with a predicate the planner can actually prove.
#
# The previous migration fixed the column direction and, in the same breath, gave
# the index a predicate that made it unusable: `status IS DISTINCT FROM 3` is a
# `DistinctExpr`, and Postgres's predicate prover bails on anything that is not a
# plain `OpExpr`. The ranked view filters `status IN (0,1,2,4)`, which it CAN
# prove against `status <> 3` — so the index built for the ranked view could not
# answer the ranked view's query, and it sorted from scratch anyway.
#
# Measured on a local database with `enable_seqscan = off`:
#
#   IS DISTINCT FROM 3 -> Sort -> Index Scan using index_sessions_on_status
#   status <> 3        -> Index Scan using the ranked index, no Sort
#
# The NULL-status rows the old predicate was written to keep are not a real
# population: `sessions.status` is `integer default 1` and every write path sets
# it. Trading a usable index for them was the wrong way round.
class MakePrecedenceIndexUsable < ActiveRecord::Migration[8.0]
  OLD_NAME = "index_sessions_on_precedence_desc_unarchived"
  NEW_NAME = "index_sessions_on_precedence_ranked"

  def up
    remove_index :sessions, name: OLD_NAME, if_exists: true
    add_index :sessions, [ :precedence, :created_at, :id ],
      order: { precedence: :desc, created_at: :asc, id: :asc },
      where: "status <> 3",
      name: NEW_NAME
  end

  def down
    remove_index :sessions, name: NEW_NAME, if_exists: true
    add_index :sessions, [ :precedence, :created_at ],
      order: { precedence: :desc, created_at: :asc },
      where: "status IS DISTINCT FROM 3",
      name: OLD_NAME
  end
end
