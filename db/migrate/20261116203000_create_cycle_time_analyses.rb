# frozen_string_literal: true

# One row per settled session hierarchy: whether it ran end to end autonomously
# and, when it did, where its wall-clock went. Written by CycleTimes::Analyzer;
# see docs/src/content/docs/operate/cycle-time.md.
class CreateCycleTimeAnalyses < ActiveRecord::Migration[8.1]
  def change
    create_table :cycle_time_analyses do |t|
      t.references :root_session, null: false, foreign_key: { to_table: :sessions, on_delete: :cascade }, index: { unique: true }
      t.boolean :eligible, null: false, default: false
      t.string :ineligible_reason
      t.text :ineligible_detail
      t.string :initiator
      t.string :initiator_detail
      t.string :title
      t.string :agent_root
      t.integer :session_count, null: false, default: 0
      t.datetime :started_at, null: false
      t.datetime :finished_at, null: false
      t.float :wall_seconds, null: false, default: 0
      t.jsonb :category_seconds, null: false, default: {}
      t.jsonb :session_category_seconds, null: false, default: {}
      t.string :dominant_wait_category
      t.jsonb :lanes, null: false, default: []
      t.jsonb :hierarchy_segments, null: false, default: []
      t.jsonb :top_segments, null: false, default: []
      t.integer :algorithm_version, null: false
      t.datetime :computed_at, null: false
      t.timestamps
    end

    add_index :cycle_time_analyses, [ :eligible, :finished_at ]
  end
end
