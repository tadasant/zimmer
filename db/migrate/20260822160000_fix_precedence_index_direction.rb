# frozen_string_literal: true

# The ranked index, built the way the query actually reads it.
#
# `Session.ranked` orders `precedence DESC, created_at ASC`. The original index
# was `(precedence ASC, created_at ASC)`, and Postgres cannot serve a
# mixed-direction sort from a same-direction index — so the index the ranked view
# was built for could not answer the ranked view's own query, and every render
# sorted from scratch.
#
# The partial predicate is rewritten too: `status <> 3` hard-codes the enum's
# integer and, being a bare inequality, also excludes rows where `status` is NULL
# (the column is nullable). `IS DISTINCT FROM` keeps those rows in the index,
# which is where they belong — a session with no status is not archived.
class FixPrecedenceIndexDirection < ActiveRecord::Migration[8.0]
  OLD_NAME = "index_sessions_on_precedence_unarchived"
  NEW_NAME = "index_sessions_on_precedence_desc_unarchived"

  def up
    remove_index :sessions, name: OLD_NAME, if_exists: true
    add_index :sessions, [ :precedence, :created_at ],
      order: { precedence: :desc, created_at: :asc },
      where: "status IS DISTINCT FROM 3",
      name: NEW_NAME
  end

  def down
    remove_index :sessions, name: NEW_NAME, if_exists: true
    add_index :sessions, [ :precedence, :created_at ],
      where: "status <> 3", name: OLD_NAME
  end
end
