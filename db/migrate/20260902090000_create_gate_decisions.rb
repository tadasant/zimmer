# frozen_string_literal: true

# The gate decision ledgers, moved out of checked-in JSON and into Postgres.
#
# `pr-merge-gate` and `issue-work-gate` record every rating they make. Until now
# each record was an append to a JSON file in `tadasant/tadasant-internal`,
# landed by its own auto-merged pull request. Reading one to calibrate a single
# rating meant reading the whole file — 3.3 MB for the largest.
#
# THE SHAPE IS DELIBERATELY THIN. Only the handful of fields that are stable
# across both gates and worth querying get columns; everything else in an entry
# rides in `payload` verbatim. The entry schemas are still moving — of the 34
# distinct keys seen across the PR gate's zimmer entries, four were added in the
# last few weeks and four more are retired — so pinning them into columns would
# buy a migration every time a gate learns something. Promoting a jsonb field to
# a column later is easy; un-promoting is a data migration.
class CreateGateDecisions < ActiveRecord::Migration[8.1]
  def change
    create_table :gate_decisions do |t|
      # Which gate rated, and the surface (repo/agent root) it rated on. The two
      # together name the ledger file this row would have been appended to.
      t.string :gate, null: false
      t.string :surface, null: false

      # The PR or issue that was rated. Nullable: one salvaged historical entry
      # carries no artifact at all, and refusing it would lose the record.
      t.string :artifact_url

      # Date, not timestamp: the gates write `"decided_at": "2026-09-02"`.
      # Ordering within a day falls back to `id`, which is insertion order, which
      # for the imported rows is the order the entries appear in the file.
      t.date :decided_at

      t.string :decision

      # The session whose work was rated. Free text in the source — often a URL
      # followed by a paragraph of prose — so this holds the URL that was
      # extracted from it, and the original stays in `payload`.
      t.string :producing_session_url

      # The session that WROTE this row. On the MCP surface it is stamped
      # server-side from the connection and there is no argument that could set
      # it. On the REST surface there is no connection identity to read, so it is
      # a self-declared `writing_session_id` param — the same shape, and the same
      # caveat, as `acting_session_id` and `analyzer_session_id` elsewhere in the
      # API. Read it as provenance, never as an authorization claim.
      t.references :writing_session, foreign_key: { to_table: :sessions, on_delete: :nullify }, index: true

      # How the row got here: `import` (backfilled from the JSON ledgers), `mcp`
      # (a gate calling record_gate_decision), `api` (POST /api/v1/gate_decisions).
      t.string :recorded_via, null: false, default: "api"

      # The entry, verbatim, minus nothing. The promoted columns above are copies,
      # not moves, so a reader that only knows the JSON schema still sees whole
      # entries.
      t.jsonb :payload, null: false, default: {}

      # Importer idempotency. NULL for rows written live, which is why this is a
      # plain unique index rather than a NOT NULL one: Postgres does not consider
      # two NULLs equal, so live rows never collide.
      t.string :source_key

      t.timestamps
    end

    # "The most recent N decisions on this surface" — the query that replaces
    # reading a 3.3 MB file.
    add_index :gate_decisions, [ :gate, :surface, :decided_at, :id ], order: { decided_at: :desc, id: :desc },
              name: "index_gate_decisions_on_gate_surface_recency"
    add_index :gate_decisions, :artifact_url
    add_index :gate_decisions, [ :gate, :decision ]
    add_index :gate_decisions, :source_key, unique: true
    add_index :gate_decisions, :payload, using: :gin

    # Human feedback is a separate table because it has a different author and a
    # different trust level from the row it hangs off. A gate row is written by a
    # machine; a feedback row is the one thing in this ledger that a machine must
    # never be able to write, so it gets its own table, its own authorship and
    # its own timestamp rather than being one more key in `payload`.
    create_table :gate_decision_feedbacks do |t|
      t.references :gate_decision, null: false, foreign_key: true, index: true

      # "should-have-held", "should-have-merged", "mischaracterized", … Free text
      # rather than an enum: the vocabulary is the humans', and it is still small
      # enough that a constraint would be guessing.
      t.string :verdict, null: false
      t.text :note

      # When the human said it, which is not when it was typed in.
      t.date :received_at

      # The User#key of the person, resolved at the input boundary from the
      # authenticated actor — the same rule HumanMessage#author follows, and for
      # the same reason: attribution comes from the boundary, never from the body.
      # Nullable only for the `imported` channel, where the JSON entry recorded a
      # note without recording who gave it; an invented author would be worse than
      # an absent one.
      t.string :author

      # Which boundary the words came through: `web_ui` is a human typing into
      # Zimmer, `imported` is a note transcribed from the JSON ledgers by the
      # backfill. There is deliberately no machine channel.
      t.string :channel, null: false, default: "web_ui"

      # Anything else the source entry carried alongside the note.
      t.jsonb :payload, null: false, default: {}

      t.timestamps
    end

    add_index :gate_decision_feedbacks, [ :gate_decision_id, :received_at ],
              name: "index_gate_decision_feedbacks_on_decision_and_received"

    # NOTE ON ENFORCEMENT. Append-only is enforced on the models, not with a
    # Postgres trigger. A trigger would be the stronger guarantee — `update_all`,
    # `delete_all` and raw SQL all walk past a `before_update` — but this app dumps
    # its schema in Rails' Ruby format, which cannot carry triggers or functions.
    # A trigger installed here would exist in production and silently NOT exist in
    # CI, in test, or in any environment built by `db:schema:load`, which is a
    # worse place to be than an honest callback: the guarantee would be untestable
    # and every environment would disagree about it. Filed as zimmer#780.
  end
end
