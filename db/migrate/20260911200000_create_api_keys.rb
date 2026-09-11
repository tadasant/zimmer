# frozen_string_literal: true

# Named API keys (tadasant/zimmer#46): a key is a row with a name and a
# `last_used_at`, so the logs can say which key acted and revoking one takes
# effect on the next request rather than the next deploy.
#
# Only a SHA-256 digest of each key is stored — never the key. A minted key is
# shown once, in the response that created it, and is unrecoverable after that.
#
# `source` records where the key itself lives. A `minted` key exists only as this
# row. An `env` row is the bookkeeping for an `API_KEYS` entry, registered the
# first time that entry authenticates, so the keys every client already holds
# keep working and gain a name without anyone re-provisioning them.
#
# Revocation stamps `revoked_at` rather than deleting the row. An `env` row has to
# outlive its revocation, or the next request carrying that key would register it
# afresh and undo the revoke; and keeping the row is what lets an operator who
# revoked the wrong key restore it.
class CreateApiKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :api_keys do |t|
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :source, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.timestamps
    end

    # The lookup every authenticated request makes.
    add_index :api_keys, :token_digest, unique: true
    # The log line names a key by name, so two keys must never share one.
    add_index :api_keys, "lower(name)", unique: true, name: "index_api_keys_on_lower_name"
  end
end
