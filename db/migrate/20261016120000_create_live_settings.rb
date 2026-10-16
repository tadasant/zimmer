# frozen_string_literal: true

# Live Mode's tunable settings — the models, the voice and its speed, turn
# detection, output caps — and "Live mode guidance", a prompt appended to the
# live model's instructions on every turn. One row for the deployment
# (LiveSetting.current); every column is nullable and NULL means "the shipped
# default", so resetting is writing NULLs and a new default ships with a deploy.
#
# live_setting_changes is the edit history: every write, field by field, before
# and after, and who made it — a person on a surface, or an agent (a live
# conversation's model, or a session through MCP). It is what a bad edit is
# reverted from.
class CreateLiveSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :live_settings do |t|
      t.string :text_model
      t.float :text_temperature
      t.integer :text_max_output_tokens
      t.string :voice_model
      t.string :voice_reasoning_effort
      t.string :voice_name
      t.float :voice_speed
      t.integer :voice_max_output_tokens
      t.string :voice_turn_detection
      t.string :voice_vad_eagerness
      t.float :voice_vad_threshold
      t.integer :voice_vad_prefix_padding_ms
      t.integer :voice_vad_silence_duration_ms
      t.string :voice_noise_reduction
      t.string :voice_transcription_model
      t.text :guidance
      t.string :updated_by
      t.timestamps
    end
    # One row for the deployment, enforced where a race cannot get past it:
    # every row indexes the same constant, so a second insert is RecordNotUnique.
    add_index :live_settings, "(true)", unique: true, name: "index_live_settings_singleton"

    create_table :live_setting_changes do |t|
      t.jsonb :changeset, null: false, default: {}
      t.string :actor_kind, null: false
      t.string :actor, null: false
      t.references :live_conversation, foreign_key: { on_delete: :nullify }
      t.datetime :created_at, null: false
    end
    add_index :live_setting_changes, :created_at
  end
end
