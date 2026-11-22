# frozen_string_literal: true

# One row per short-lived OpenRouter key PiSessionKeys minted for a Pi spawn.
# See PiProviderKey.
#
# Holds the key's OpenRouter identifier (`key_hash`), never the key itself. A
# plain `session_id` rather than a foreign key: a session is hard-deleted when
# its trash retention expires, and the sweep still has to find and delete a key
# whose session is gone.
class CreatePiProviderKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :pi_provider_keys do |t|
      t.bigint :session_id
      t.string :key_hash, null: false
      t.string :name, null: false
      t.decimal :limit_usd, precision: 12, scale: 4, null: false
      t.datetime :expires_at, null: false
      t.datetime :revoked_at
      t.string :revoke_reason
      t.decimal :usage_usd, precision: 12, scale: 6
      t.text :last_error
      t.timestamps
    end
    add_index :pi_provider_keys, :key_hash, unique: true
    add_index :pi_provider_keys, :session_id
    add_index :pi_provider_keys, :created_at, where: "revoked_at IS NULL", name: "index_pi_provider_keys_active"
  end
end
