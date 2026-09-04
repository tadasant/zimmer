# Zimmer's own record of every write it made to the Parameter Store.
#
# The store itself can answer "what is this value" and "when was this version
# created", but only to a credential that can read the resource metadata, and
# only about writes made through it. This table answers the question the
# Inference page actually asks — "did somebody set this from here, and when" —
# without a network call and without ever holding the value.
#
# `fingerprint` is a truncated SHA-256 of the value. It is not the value and no
# part of it: it lets a human confirm the key in the store is the key on their
# clipboard, and reveals nothing to a reader who does not already have one.
class CreateManagedSecretWrites < ActiveRecord::Migration[8.0]
  def change
    create_table :managed_secret_writes do |t|
      t.string :variable, null: false
      t.string :action, null: false
      t.string :outcome, null: false
      t.string :fingerprint
      t.string :project_id
      t.string :location
      t.string :detail
      t.timestamps
    end

    # The one read: the most recent row for a variable.
    add_index :managed_secret_writes, [ :variable, :created_at ]
  end
end
