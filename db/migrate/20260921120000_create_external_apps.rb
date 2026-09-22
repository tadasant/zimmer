# frozen_string_literal: true

# Zimmer plugins: external apps whose credential invokes an allowlisted set of
# triggers and nothing else. See ExternalApp.
#
#   external_apps           the app: a name, what it is, whether it is on, and
#                           when it last invoked anything
#   external_app_triggers   its allowlist, one row per trigger it may invoke.
#                           Deleting a trigger or the app deletes the row, so an
#                           allowlist can never name a trigger that is gone
#   api_keys.external_app_id
#                           the app an `external_app` key belongs to. A key has
#                           that grant exactly when it has an app, enforced by a
#                           check constraint as well as the model
class CreateExternalApps < ActiveRecord::Migration[8.1]
  def change
    create_table :external_apps do |t|
      t.string :name, null: false
      t.text :description
      t.boolean :enabled, null: false, default: true
      t.datetime :last_invoked_at
      t.timestamps
    end
    add_index :external_apps, "lower(name)", unique: true, name: "index_external_apps_on_lower_name"

    create_table :external_app_triggers do |t|
      # The composite unique index below leads with external_app_id, so it serves
      # lookups by app and a second index would be dead weight.
      t.references :external_app, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :trigger, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
    end
    add_index :external_app_triggers, %i[external_app_id trigger_id], unique: true,
              name: "index_external_app_triggers_on_app_and_trigger"

    add_reference :api_keys, :external_app, foreign_key: { on_delete: :cascade }
    add_check_constraint :api_keys,
                         "(\"grant\" = 'external_app') = (external_app_id IS NOT NULL)",
                         name: "api_keys_external_app_grant_has_app"
  end
end
