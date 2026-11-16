# frozen_string_literal: true

# What each GitHub path saw while `GITHUB_TRIGGER_INGEST_MODE=webhook_shadow`: a row per event the
# webhook WOULD have fired for a condition, and a row per event the poller DID fire. See
# TriggerShadowObservation and Webhooks::GithubShadowComparison.
class CreateTriggerShadowObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :trigger_shadow_observations do |t|
      t.references :trigger_condition, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :event_key, null: false
      t.string :path, null: false
      t.string :delivery_id
      t.datetime :created_at, null: false
    end

    add_index :trigger_shadow_observations, [ :trigger_condition_id, :created_at ]
    add_index :trigger_shadow_observations, :created_at
    # A webhook job that GoodJob retries must not record its delivery's verdict twice.
    add_index :trigger_shadow_observations, [ :trigger_condition_id, :event_key, :delivery_id ],
              unique: true, where: "delivery_id IS NOT NULL", name: "index_trigger_shadow_observations_on_delivery"
  end
end
