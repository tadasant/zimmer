# frozen_string_literal: true

# McpOauthCredential now refuses a token_endpoint that is not an https URL with
# a host (#892). This clears any row that already holds one, so the validation
# cannot brick a credential that predates it.
#
# Why clearing is the repair, and why it has to happen at deploy time:
#
# There is no per-server default to reset to — unlike XOauthCredential, whose
# endpoint is a constant, an MCP token endpoint is discovered from each server's
# own authorization-server metadata. NULL is the right value and a meaningful
# one: #can_refresh? reads it as "this credential cannot be renewed", so the
# Connectors page asks for re-authorization, which rediscovers the endpoint. The
# column is nullable and the validation allows blank, so a cleared row is savable
# again.
#
# Validation alone would have been worse than nothing for such a row. #refresh!
# POSTs *before* it saves and RefreshMcpOauthTokensJob runs it unattended from
# cron, so the secret would still have gone out in the clear, the provider would
# have rotated and invalidated the single-use refresh token, and only then would
# the `update!` carrying the rotated token have raised RecordInvalid — a leak and
# a permanently unrefreshable credential in one pass.
#
# The predicate is the validation's own, frozen here rather than approximated in
# SQL. A `LIKE 'https://%'` filter would leave behind exactly the rows that are
# hardest to notice — a trailing space, a bare `https://` with no host, a
# single-slash `https:/host/token` — which start with the right characters, still
# fail the validation, and would be unsavable afterwards. The table holds one row
# per OAuth-protected MCP server, so reading it into Ruby costs nothing. It is
# deliberately NOT expressed by calling McpOauthCredential: a migration must keep
# working after the model moves on.
#
# Idempotent: a second run matches nothing, because a cleared row is NULL and
# NULL is skipped. An already-blank endpoint is skipped too rather than
# normalised, so the count it reports means "rows that held a cleartext
# endpoint" and nothing else.
#
# Nobody has observed a non-https row on any deployment — there is no way to
# check one without a prod shell, which is the point — so the expected count is
# 0. This exists because the failure mode if one does exist is unrecoverable,
# not because one is known.
class ClearNonHttpsMcpOauthTokenEndpoints < ActiveRecord::Migration[8.0]
  def up
    broken = select_all("SELECT id, token_endpoint FROM mcp_oauth_credentials WHERE token_endpoint IS NOT NULL AND token_endpoint <> ''")
      .reject { |row| usable_https_endpoint?(row["token_endpoint"]) }
      .map { |row| row["id"] }

    unless broken.empty?
      execute(<<~SQL.squish)
        UPDATE mcp_oauth_credentials
        SET token_endpoint = NULL,
            updated_at = NOW()
        WHERE id IN (#{broken.map { |id| connection.quote(id) }.join(", ")})
      SQL
    end

    say "Cleared #{broken.size} non-https mcp_oauth_credentials.token_endpoint value(s); those credentials now require re-authorization"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def usable_https_endpoint?(value)
    uri = URI.parse(value.to_s)
    uri.is_a?(URI::HTTPS) && uri.host.present?
  rescue URI::Error
    false
  end
end
