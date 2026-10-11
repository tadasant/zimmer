# frozen_string_literal: true

# The phones Zimmer's iOS app has registered for push notifications. One row per
# APNs device token, with the APNs environment that token belongs to (`sandbox`
# for a development build, `production` for TestFlight and the App Store — a
# token is only valid against its own environment), and the OAuth grant the app
# registered it under, so a phone that signs out or is revoked stops receiving
# pushes — and a phone whose grant is deleted outright loses its row with it, rather
# than being left with no grant, which would read as an API-key registration. A token Apple reports as dead is disabled, not deleted, so the row says
# why it went quiet.
class CreateApnsDevices < ActiveRecord::Migration[8.1]
  def change
    create_table :apns_devices do |t|
      t.string :token, null: false
      t.string :environment, null: false
      t.string :device_name
      t.string :app_version
      t.references :oauth_server_grant, foreign_key: { on_delete: :cascade }, null: true
      t.datetime :last_registered_at, null: false
      t.datetime :last_delivered_at
      t.datetime :disabled_at
      t.string :disabled_reason
      t.timestamps
    end
    add_index :apns_devices, :token, unique: true
  end
end
