# frozen_string_literal: true

# The second kind of lineage edge: "this session inspected that one and decided
# to queue or interrupt it".
#
# `sessions.parent_session_id` records ONE fact — who spawned whom — and it is a
# tree because a session is spawned exactly once. Seniority is not so tidy: a
# session that reads another session's state and decides to redirect it has
# information that session does not have, and that relationship can hold between
# two sessions with no spawn edge between them at all. That is the "uncle" edge,
# and it needs its own table because a session can be interrupted by several
# different seniors over its life.
#
# Deliberately a separate table rather than a second column on `sessions`:
#
#   * a column would cap the relationship at one uncle and silently drop the
#     rest, and there is no principled way to pick which one to keep;
#   * the spawn column stays exactly what it was, so `Session#lineage_parent_id`
#     and its no-backfill derivation are untouched;
#   * an edge carries its own provenance (`source`), which has nowhere to live on
#     the `sessions` row.
#
# ON DELETE CASCADE on both ends, which is where this differs from
# `parent_session_id` (SET NULL). Nulling a parent pointer leaves a meaningful
# row — a session with no recorded parent. Nulling either end of an edge leaves a
# row that asserts nothing; the edge simply stops existing when either session
# does.
class CreateSessionUncleLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :session_uncle_links do |t|
      # The junior: the session that was queued or interrupted.
      t.references :session, null: false, foreign_key: { on_delete: :cascade }, index: false
      # The senior: the session that did the queueing or interrupting.
      t.bigint :uncle_session_id, null: false

      # Which entry point recorded this edge, e.g. "mcp:action_session.follow_up".
      # Free-form and for reading, not for dispatch — an edge means the same thing
      # however it arrived.
      t.string :source

      t.timestamps
    end

    # One edge per ordered pair. A senior that interrupts the same session ten
    # times is still one seniority claim, and the graph invariants below are much
    # easier to reason about when an edge is a set member rather than a log line.
    add_index :session_uncle_links, %i[session_id uncle_session_id], unique: true,
              name: "index_session_uncle_links_on_pair"
    # The reverse direction: "which sessions am I senior to?" — the downward walk
    # SessionHierarchy#children_of does on every render.
    add_index :session_uncle_links, :uncle_session_id

    add_foreign_key :session_uncle_links, :sessions, column: :uncle_session_id, on_delete: :cascade
  end
end
