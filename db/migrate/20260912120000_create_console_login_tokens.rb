# frozen_string_literal: true

# Console login tokens (tadasant/zimmer#220): the agent-login primitive. A row is one
# short-lived, single-use, revocable token that an automated actor — a Playwright run
# in CI, a post-deploy agent session — exchanges exactly once for a web-console
# session cookie.
#
# The row's id is the token's `jti`: the wire form is `zlt_<id>.<secret>`, the id
# finds the row and the secret is compared, in constant time, against
# `secret_digest`. Only the SHA-256 digest is stored, never the secret; the plaintext
# token is shown once, in the response that minted it.
#
# `status` is the whole single-use story. `active` rows exchange; the exchange is one
# conditional UPDATE from `active` to `consumed`, so a concurrent double-exchange
# loses rather than succeeding twice. `revoked` is what an actor sets on a token it
# minted and could not exchange, before minting again. Expiry is not a status: an
# `active` row past `expires_at` is dead, and the reaper deletes it later.
#
# The authority the exchanged session carries is baked into the row — `principal`
# and `role` are copied into the cookie at exchange time and cannot be changed by
# presenting the token differently — and so is the session's own lifetime,
# `session_ttl_seconds`, which becomes the cookie's `Max-Age`.
class CreateConsoleLoginTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :console_login_tokens do |t|
      t.string :secret_digest, null: false
      t.string :principal, null: false
      t.string :role, null: false
      t.string :status, null: false, default: "active"
      t.datetime :expires_at, null: false
      t.integer :session_ttl_seconds, null: false
      t.datetime :consumed_at
      t.datetime :revoked_at
      t.string :minted_from_ip
      t.string :consumed_from_ip

      t.timestamps
    end

    # The reaper's scan: every row whose expiry is older than the retention window.
    add_index :console_login_tokens, :expires_at
  end
end
