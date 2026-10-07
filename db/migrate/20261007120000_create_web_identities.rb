# frozen_string_literal: true

# The people who have signed in to the web UI with Google. See WebIdentity.
#
# A row is created by the first successful Google sign-in from an allowed
# hosted domain; nobody hand-authors one. It carries the second factor too:
# the TOTP secret, a pending one being set up (kept apart so that replacing
# an authenticator does not void the old one until the new one is confirmed),
# when it was confirmed, the last time step it accepted
# (so a code cannot be replayed), the SHA-256 digests of the unused recovery
# codes, and the failed-attempt lockout.
#
# `session_generation` is part of every sign-in cookie. Bumping it signs the
# identity out on every device.
class CreateWebIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :web_identities do |t|
      t.string :google_sub, null: false
      t.string :email, null: false
      t.string :hosted_domain, null: false
      t.string :name
      t.string :totp_secret
      t.string :totp_pending_secret
      t.datetime :totp_enrolled_at
      t.bigint :totp_last_used_step
      t.jsonb :recovery_code_digests, null: false, default: []
      t.integer :second_factor_failed_attempts, null: false, default: 0
      t.datetime :second_factor_locked_until
      t.integer :session_generation, null: false, default: 0
      t.datetime :last_signed_in_at
      t.timestamps
    end
    add_index :web_identities, :google_sub, unique: true
    add_index :web_identities, "lower(email)", name: "index_web_identities_on_lower_email"
  end
end
