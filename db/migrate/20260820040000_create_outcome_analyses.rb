# frozen_string_literal: true

# The Outcomes ledger's storage: one saved Transcript-Segment tree per analyzed
# session, plus the batch bookkeeping the "Analyze All" queue runs on.
#
# The tree itself lives in `root` (jsonb) and is never read by the ledger or the
# stats view — everything those two surfaces filter, group, or sort on is
# denormalized into a column here at save time. That is what keeps a ledger of
# thousands of analyses to one indexed query instead of thousands of JSON parses.
class CreateOutcomeAnalyses < ActiveRecord::Migration[8.1]
  def change
    create_table :outcome_analyses do |t|
      # The analyzed session. A deleted session takes its analyses with it: an
      # analysis of a transcript that no longer exists asserts nothing.
      t.references :session, null: false, index: false, foreign_key: { on_delete: :cascade }

      # The session that PRODUCED the analysis, nullified rather than cascaded —
      # the finding outlives the worker that found it.
      t.bigint :analyzer_session_id

      t.string :schema_version, null: false, default: "1"
      t.jsonb :root, null: false
      t.text :notes

      # --- Denormalized from the analyzed session, frozen at save time ---------
      t.string :agent_root
      t.string :agent_runtime, null: false
      t.string :model
      t.datetime :session_created_at, null: false

      # --- Denormalized from the Segment tree --------------------------------
      t.string :root_outcome, null: false
      t.integer :segment_count, null: false, default: 0
      t.integer :failure_segment_count, null: false, default: 0
      t.integer :max_depth, null: false, default: 0

      t.datetime :analyzed_at, null: false

      # Re-analysis supersedes rather than overwrites, so the prior read of a
      # transcript survives a second one that disagrees with it.
      t.datetime :superseded_at

      t.timestamps
    end

    # Exactly one current analysis per session — enforced by the database, so a
    # racing double-save cannot leave two rows both claiming to be current.
    add_index :outcome_analyses, :session_id,
      unique: true, where: "superseded_at IS NULL", name: "index_outcome_analyses_current_per_session"
    # The superseded history, read only from a session's own page.
    add_index :outcome_analyses, [ :session_id, :analyzed_at ], name: "index_outcome_analyses_on_session_and_analyzed_at"
    add_index :outcome_analyses, :analyzer_session_id, where: "analyzer_session_id IS NOT NULL"
    # The stats view's driving predicate: current rows, windowed on the analyzed
    # session's created_at, grouped by one of the three dimension columns.
    add_index :outcome_analyses, [ :session_created_at, :agent_runtime, :model, :agent_root ],
      where: "superseded_at IS NULL", name: "index_outcome_analyses_stats"

    add_foreign_key :outcome_analyses, :sessions, column: :analyzer_session_id, on_delete: :nullify

    # The ledger filters archived sessions by agent root and by model, both of
    # which live inside JSON columns. Without these two the ledger degrades to a
    # sequential scan of every session the deployment has ever run.
    add_index :sessions, "(metadata->>'agent_root_key')", name: "index_sessions_on_agent_root_key"
    add_index :sessions, "(config->>'model')", name: "index_sessions_on_config_model"
  end
end
