# frozen_string_literal: true

# XOauthCredential now refuses a non-https token_endpoint, and this repairs any
# row that already holds one so the validation cannot brick it.
#
# Without this, a legacy `http://` row would still pass through #refresh!: the
# POST goes out (leaking the client secret over cleartext HTTP Basic, which is
# the whole point of the new validation), X rotates the single-use refresh token,
# and then apply_token_response!'s `update!` raises RecordInvalid on the way to
# persisting it — losing the rotated token and leaving the credential unable to
# refresh again. Repairing at deploy time is what keeps the validation from
# turning a silent leak into a dead credential.
#
# Idempotent: a second run matches nothing. Nobody has observed a non-https row
# on any deployment, so the expected count is 0 — the migration exists because
# the failure mode if one does exist is unrecoverable, not because one is known.
class ResetNonHttpsXOauthTokenEndpoints < ActiveRecord::Migration[8.0]
  def up
    result = execute(<<~SQL.squish)
      UPDATE x_oauth_credentials
      SET token_endpoint = 'https://api.x.com/2/oauth2/token',
          updated_at = NOW()
      WHERE lower(token_endpoint) NOT LIKE 'https://%'
    SQL

    say "Reset #{result.cmd_tuples} non-https x_oauth_credentials.token_endpoint value(s) to the default"
  end

  def down
    # Irreversible by design: the values this replaced were unusable (X publishes
    # no plaintext token endpoint) and were not recorded anywhere to restore from.
  end
end
