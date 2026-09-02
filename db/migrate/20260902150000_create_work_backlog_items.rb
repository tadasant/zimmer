# frozen_string_literal: true

# The agent fleet's work backlog — the ranked queue of GitHub issues the issue
# work gate has cleared and nobody has started — moved out of a checked-in JSON
# file and into Postgres.
#
# Until now the queue was `WORK_BACKLOG.json` in `tadasant/tadasant-internal`,
# specified by `WORK_BACKLOG.md` beside it. Every append (the gate clearing an
# issue) and every pull (the 04:00 groomer starting up to three items) was a
# branch, a commit, a PR, a CI run and an auto-merge. The table replaces that
# write path: an append is one INSERT, a pull is one UPDATE.
#
# A ROW IS NEVER DELETED. The file removed an item when it was pulled, so the
# file held only what was waiting and the history of what got started lived in
# the groomer's reports. Here an item has a status — `queued`, `started` (with
# the session it became), or `removed` (with a reason and who did it) — so the
# ledger of what was started, and the trend of how big the queue has been, can
# be reconstructed from the table alone.
#
# THE COLUMNS ARE WHAT IS QUERIED; `payload` IS THE REST. The gate's ratings
# object, the verbatim `prompt` an issueless item carries, the one-line `notes`
# and the gate's session URL ride in jsonb, together with whatever the gate adds
# to its schema next. Promoting a jsonb key to a column later is one migration;
# un-promoting one is a data migration.
class CreateWorkBacklogItems < ActiveRecord::Migration[8.1]
  def change
    create_table :work_backlog_items do |t|
      # The item's identity in the file: "zimmer#498", or "manual-<slug>" for an
      # item with no issue. Unique among QUEUED rows only (see the partial index
      # below): a started or removed row keeps its key as history, and the same
      # issue can be cleared and queued again after the session that took it
      # first came to nothing.
      t.string :key, null: false

      # The GitHub issue URL. Null only for an issueless item, which is a shape
      # only a human or the one-time migration may create — the model enforces it.
      t.string :issue_url

      # owner/name — what a session gets checked out for.
      t.string :repo, null: false
      # The gate surface that rated it: zimmer, strad, motet, tadasant-internal, …
      t.string :surface, null: false
      t.string :title, null: false
      # The gate's classification: bug, tech-debt, docs, dep-bump, …
      t.string :kind, null: false
      t.string :scope_direction, null: false
      # small | medium | large — THE ranking input. Comes from the gate; nothing
      # here re-estimates it.
      t.string :estimated_cost, null: false
      t.string :gate_verdict

      # Date, not timestamp: the gate writes `"decided_at": "2026-08-29"`.
      t.date :decided_at
      # When the item entered the queue. A timestamp, because the queue's size
      # over time is what the trend chart is built from.
      t.datetime :added_at, null: false
      # issue-work-gate | queue-migration | human — the root or person that
      # appended it.
      t.string :added_by, null: false
      # How the row got here: `import` (the one-time backfill of the JSON file),
      # `mcp` (append_work_backlog_item), `api` (POST /api/v1/work_backlog_items).
      # Stamped by the writer, never accepted from a caller.
      t.string :added_via, null: false, default: "api"

      # Absolute rank, higher is pulled sooner, on the same scale the file used:
      # sparse values inside a band per estimated_cost, so the cheapest work
      # floats. See WorkBacklog::Ranking.
      t.integer :precedence, null: false
      # A human's hand-placement. A pinned item is never re-ranked by an agent.
      t.boolean :pinned, null: false, default: false

      # queued → started (the session it became is recorded) | removed (with a
      # reason and who did it). Terminal rows stay; "removed" still means gone
      # from the queue.
      t.string :status, null: false, default: "queued"

      # The session that APPENDED the row. On the MCP surface it is stamped
      # server-side from the connection and there is no argument that could set
      # it. On the REST surface there is no connection identity to read, so it is
      # a self-declared `acting_session_id` — the same shape, and the same caveat,
      # as everywhere else in the API. Provenance, never authorization.
      t.references :writing_session, foreign_key: { to_table: :sessions, on_delete: :nullify }, index: true
      # The implementing session a pull (or a "start now") spawned for this item.
      t.references :started_session, foreign_key: { to_table: :sessions, on_delete: :nullify }, index: true
      # The session that did the pulling — the groomer — when one did.
      t.references :started_by_session, foreign_key: { to_table: :sessions, on_delete: :nullify }, index: true
      t.datetime :started_at

      t.datetime :removed_at
      t.string :removed_by
      t.text :removal_reason

      # ratings, prompt, notes, gate_session, and anything the gate adds later.
      t.jsonb :payload, null: false, default: {}

      t.timestamps
    end

    # One queued row per key. Partial so history rows can share the key.
    add_index :work_backlog_items, :key, unique: true, where: "status = 'queued'",
              name: "index_work_backlog_items_on_queued_key"
    add_index :work_backlog_items, :key
    # The queue in rank order — the read every pull and every Issues view makes.
    add_index :work_backlog_items, [ :status, :precedence, :added_at, :id ],
              order: { precedence: :desc, added_at: :asc, id: :asc },
              name: "index_work_backlog_items_rank"
    add_index :work_backlog_items, :issue_url
    add_index :work_backlog_items, :repo
    add_index :work_backlog_items, :surface
    add_index :work_backlog_items, :kind
    add_index :work_backlog_items, :scope_direction
    add_index :work_backlog_items, :estimated_cost
    add_index :work_backlog_items, :gate_verdict
    add_index :work_backlog_items, :added_by
    add_index :work_backlog_items, :added_at
    add_index :work_backlog_items, :decided_at
    add_index :work_backlog_items, :started_at
    add_index :work_backlog_items, :removed_at
    add_index :work_backlog_items, :pinned, where: "pinned"
  end
end
