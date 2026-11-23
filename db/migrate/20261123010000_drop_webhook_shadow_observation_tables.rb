# frozen_string_literal: true

# expand-contract: contract of #1630
#
# The GitHub webhook shadow mode's comparison stores. #1630 removed the mode, the models and every
# read and write of both tables, and shipped in the deploy before this one, so nothing in either
# image touches them when they go. `down` recreates them empty: the rows were a rehearsal's
# evidence, not state anything depends on.
class DropWebhookShadowObservationTables < ActiveRecord::Migration[8.1]
  def up
    drop_table :trigger_shadow_observations
    drop_table :github_pr_shadow_observations
  end

  def down
    create_table :trigger_shadow_observations do |t|
      t.references :trigger_condition, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :event_key, null: false
      t.string :path, null: false
      t.string :delivery_id
      t.datetime :created_at, null: false
    end
    add_index :trigger_shadow_observations, [ :trigger_condition_id, :created_at ]
    add_index :trigger_shadow_observations, :created_at
    add_index :trigger_shadow_observations, [ :trigger_condition_id, :event_key, :delivery_id ],
              unique: true, where: "delivery_id IS NOT NULL", name: "index_trigger_shadow_observations_on_delivery"

    create_table :github_pr_shadow_observations do |t|
      t.bigint :session_id, null: false
      t.string :pr_url, null: false
      t.string :kind, null: false
      t.string :mode, null: false
      t.boolean :hit, null: false
      t.datetime :signaled_at
      t.datetime :created_at, null: false
    end
    add_index :github_pr_shadow_observations, :created_at
    add_index :github_pr_shadow_observations, %i[kind created_at]
    add_index :github_pr_shadow_observations, :session_id
  end
end
