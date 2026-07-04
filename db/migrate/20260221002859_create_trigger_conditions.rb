# Migration to support multiple triggers (conditions) per trigger flow.
#
# Previously, each Trigger had a single trigger_type and configuration embedded directly.
# This migration extracts trigger conditions into a separate table so a single Trigger
# (now acting as a "trigger flow") can have multiple conditions with OR semantics.
#
# Also adds a new "ao_event" condition type for internal AO events like session needs_input.
class CreateTriggerConditions < ActiveRecord::Migration[8.0]
  def up
    create_table :trigger_conditions do |t|
      t.references :trigger, null: false, foreign_key: true
      t.string :condition_type, null: false  # "slack", "schedule", "ao_event"
      t.jsonb :configuration, null: false, default: {}
      t.datetime :last_polled_at
      t.datetime :last_triggered_at
      t.string :last_message_ts

      t.timestamps
    end

    add_index :trigger_conditions, :condition_type

    # Migrate existing trigger data into trigger_conditions
    execute <<~SQL
      INSERT INTO trigger_conditions (trigger_id, condition_type, configuration, last_polled_at, last_triggered_at, last_message_ts, created_at, updated_at)
      SELECT id, trigger_type, configuration, last_polled_at, last_triggered_at, last_message_ts, created_at, updated_at
      FROM triggers
    SQL

    # Remove the now-redundant columns from triggers
    remove_index :triggers, :trigger_type
    remove_column :triggers, :trigger_type, :string
    remove_column :triggers, :configuration, :jsonb
    remove_column :triggers, :last_polled_at, :datetime
    remove_column :triggers, :last_message_ts, :string
  end

  def down
    # Add columns back to triggers
    add_column :triggers, :trigger_type, :string, default: "slack", null: false
    add_column :triggers, :configuration, :jsonb, default: {}, null: false
    add_column :triggers, :last_polled_at, :datetime
    add_column :triggers, :last_message_ts, :string
    add_index :triggers, :trigger_type

    # Migrate the first condition back to triggers (best-effort)
    execute <<~SQL
      UPDATE triggers
      SET trigger_type = tc.condition_type,
          configuration = tc.configuration,
          last_polled_at = tc.last_polled_at,
          last_message_ts = tc.last_message_ts
      FROM (
        SELECT DISTINCT ON (trigger_id) *
        FROM trigger_conditions
        ORDER BY trigger_id, created_at ASC
      ) tc
      WHERE triggers.id = tc.trigger_id
    SQL

    drop_table :trigger_conditions
  end
end
