# frozen_string_literal: true

# Live Mode's voice-engine cost ledger: one row per billable or measured
# operation — a voice model's tokens or minutes, a Claude call, a transcription,
# a tool call, a turn's latency — tagged with the engine and conversation it
# belongs to. Volumes are kept alongside the dollars so a row can be re-priced;
# `cost_usd` is what `price_version` of config/live_voice_prices.yml made of them.
class CreateLiveUsageEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :live_usage_events do |t|
      t.references :live_conversation, foreign_key: { on_delete: :nullify }, null: true
      t.string :engine, null: false
      t.string :operation, null: false
      t.string :vendor
      t.string :model
      t.bigint :input_tokens, null: false, default: 0
      t.bigint :output_tokens, null: false, default: 0
      t.bigint :cache_read_tokens, null: false, default: 0
      t.bigint :cache_write_tokens, null: false, default: 0
      t.bigint :audio_input_tokens, null: false, default: 0
      t.bigint :audio_output_tokens, null: false, default: 0
      t.decimal :seconds, precision: 12, scale: 3, null: false, default: 0
      t.bigint :characters, null: false, default: 0
      t.integer :count, null: false, default: 0
      t.decimal :cost_usd, precision: 14, scale: 6, null: false, default: 0
      t.boolean :priced, null: false, default: true
      t.string :price_version
      t.integer :latency_ms
      t.integer :first_audio_ms
      t.string :error
      t.string :idempotency_key
      t.jsonb :details, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
    end
    add_index :live_usage_events, :idempotency_key, unique: true
    add_index :live_usage_events, %i[engine occurred_at]
    add_index :live_usage_events, %i[live_conversation_id engine]
    add_index :live_usage_events, :occurred_at
  end
end
