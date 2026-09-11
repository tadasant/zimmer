# frozen_string_literal: true

# The corpus behind the categorization feedback loop (tadasant/zimmer#16).
#
# One row per categorization OUTCOME — what the model answered and the exact
# context string it answered from — plus one row per human CORRECTION of that
# answer. Before this table a correction was `sessions.category_id = X` and
# nothing else, so an auto-assignment and a human overruling it were
# indistinguishable the moment the write landed.
#
# The category ids are nullified rather than cascaded on delete, and the names
# are denormalized alongside them, because the corpus has to outlive both the
# session it came from and the category it named.
class CreateCategoryFeedbackEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :category_feedback_events do |t|
      t.references :session, foreign_key: { on_delete: :nullify }, index: true

      t.string :kind, null: false

      # What the categorizer answered. Null on an `uncategorized` row (it
      # answered NONE, blank, or something that matched nothing) and on a
      # `correction` row whose inference event had no match either.
      t.bigint :auto_category_id
      t.string :auto_category_name

      # What the human said instead. Only set on a `correction` row; null there
      # means the human moved the session to Uncategorized.
      t.bigint :corrected_category_id
      t.string :corrected_category_name

      # The hermetic part: the exact string the model saw (already capped at
      # SessionTitleJob::MAX_CONTEXT_CHARS), so replay never re-reads a
      # transcript that TranscriptArchiveJob may have moved away.
      t.text :context_snapshot
      t.string :context_source
      t.boolean :title_requested, null: false, default: false
      t.text :raw_answer

      t.string :model
      t.string :prompt_version
      t.string :source
      t.string :candidate_names, array: true, default: [], null: false

      # The last verdict a replay of the CURRENT config gave this row. Written
      # only by CategorizationReplayJob; the rest of the row is append-only.
      t.datetime :replayed_at
      t.bigint :replay_category_id
      t.string :replay_category_name
      t.text :replay_raw_answer
      t.string :replay_model
      t.string :replay_prompt_version

      t.timestamps
    end

    add_foreign_key :category_feedback_events, :categories, column: :auto_category_id, on_delete: :nullify
    add_foreign_key :category_feedback_events, :categories, column: :corrected_category_id, on_delete: :nullify
    add_foreign_key :category_feedback_events, :categories, column: :replay_category_id, on_delete: :nullify

    # The two reads this table has: "the latest inference outcome for this
    # session" (correction capture) and "the most recent corrections" (the eval
    # corpus and the replay batch).
    add_index :category_feedback_events, [ :session_id, :kind, :id ],
      name: "index_category_feedback_events_on_session_and_kind"
    add_index :category_feedback_events, [ :kind, :id ],
      name: "index_category_feedback_events_on_kind_and_id"
  end
end
