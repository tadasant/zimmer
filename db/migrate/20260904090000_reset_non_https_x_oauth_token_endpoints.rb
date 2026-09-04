# frozen_string_literal: true

# XOauthCredential now refuses a token_endpoint that is not an https URL with a
# host, and this repairs any row that already holds one so the validation cannot
# brick it.
#
# Without this, a legacy `http://` row would still pass through #refresh!: the
# POST goes out (over cleartext HTTP Basic, which is the whole point of the new
# validation), X rotates the single-use refresh token, and then
# apply_token_response!'s `update!` raises RecordInvalid on the way to persisting
# it — losing the rotated token and leaving the credential unable to refresh
# again. Repairing at deploy time is what keeps the validation from turning a
# leak into a dead credential.
#
# The predicate is the validation's own, frozen here rather than approximated in
# SQL. A `LIKE 'https://%'` filter would leave behind exactly the rows that are
# hardest to notice — a trailing space, embedded whitespace, a bare `https://`
# with no host — which start with the right characters, fail the validation, and
# would be unsavable afterwards. The table holds one row per X account, so
# reading it into Ruby costs nothing. It is deliberately NOT expressed by calling
# XOauthCredential: a migration must keep working after the model moves on.
#
# Idempotent: a second run matches nothing. Nobody has observed a non-https row
# on any deployment, so the expected count is 0 — this exists because the failure
# mode if one does exist is unrecoverable, not because one is known.
class ResetNonHttpsXOauthTokenEndpoints < ActiveRecord::Migration[8.0]
  DEFAULT_TOKEN_ENDPOINT = "https://api.x.com/2/oauth2/token"

  def up
    broken = select_all("SELECT id, token_endpoint FROM x_oauth_credentials")
      .reject { |row| usable_https_endpoint?(row["token_endpoint"]) }
      .map { |row| row["id"] }

    unless broken.empty?
      execute(<<~SQL.squish)
        UPDATE x_oauth_credentials
        SET token_endpoint = #{connection.quote(DEFAULT_TOKEN_ENDPOINT)},
            updated_at = NOW()
        WHERE id IN (#{broken.map { |id| connection.quote(id) }.join(", ")})
      SQL
    end

    say "Reset #{broken.size} unusable x_oauth_credentials.token_endpoint value(s) to the default"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def usable_https_endpoint?(value)
    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.blank?
  rescue URI::InvalidURIError
    false
  end
end
