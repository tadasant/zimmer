# frozen_string_literal: true

# "Analyze All": a saved filter set, a concurrency ceiling, and one item per
# session the filter matched at the moment the batch was created.
#
# The batch is a queue, not a fan-out. OutcomeAnalysisBatchPumpJob keeps at most
# `concurrency` analysis sessions in flight at a time and spawns the next item
# only as a slot frees, which is what makes `concurrency: 1` mean sequential and
# `concurrency: 100` mean a hundred at once rather than a hundred all queued.
class CreateOutcomeAnalysisBatches < ActiveRecord::Migration[8.1]
  def change
    create_table :outcome_analysis_batches do |t|
      t.jsonb :filters, null: false, default: {}
      t.integer :concurrency, null: false, default: 1
      t.string :status, null: false, default: "running"
      t.integer :total_count, null: false, default: 0
      t.datetime :finished_at
      t.timestamps
    end

    add_index :outcome_analysis_batches, [ :status, :id ]

    create_table :outcome_analysis_batch_items do |t|
      t.references :outcome_analysis_batch, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.bigint :session_id, null: false
      t.bigint :analysis_session_id
      t.string :state, null: false, default: "queued"
      t.integer :position, null: false, default: 0
      t.text :error
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end

    add_index :outcome_analysis_batch_items, [ :outcome_analysis_batch_id, :state, :position ],
      name: "index_outcome_batch_items_on_batch_state_position"
    add_index :outcome_analysis_batch_items, [ :outcome_analysis_batch_id, :session_id ],
      unique: true, name: "index_outcome_batch_items_on_batch_session"
    add_index :outcome_analysis_batch_items, :analysis_session_id, where: "analysis_session_id IS NOT NULL"

    # An item exists to name a session, so it goes when the session does — the
    # column is NOT NULL and an item pointing at nothing describes nothing. The
    # batch's own `total_count` is the record that it was once enqueued; progress
    # is measured against the items that still exist (see
    # OutcomeAnalysisBatch#progress_percent) so a deletion does not strand the
    # bar short of the end.
    add_foreign_key :outcome_analysis_batch_items, :sessions, column: :session_id, on_delete: :cascade
    add_foreign_key :outcome_analysis_batch_items, :sessions, column: :analysis_session_id, on_delete: :nullify
  end
end
