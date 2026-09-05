# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260905210000_clear_non_https_mcp_oauth_token_endpoints")

# McpOauthCredential's https-only rule would make a pre-existing cleartext row
# unsavable, and #refresh! saves — so this migration is the only thing standing
# between a legacy row and a refresh that leaks the client secret and then loses
# the rotated token on the way to persisting it. Its predicate is worth pinning:
# it has to clear exactly what the validation refuses, and a near-miss like
# `LIKE 'https://%'` would leave behind the values that look right and aren't.
class ClearNonHttpsMcpOauthTokenEndpointsTest < ActiveSupport::TestCase
  setup { @migration = ClearNonHttpsMcpOauthTokenEndpoints.new }

  # suppress_messages rather than `verbose = false`: verbose is a cattr, so the
  # writer would silence migration logging for the rest of the worker process.
  def migrate
    ActiveRecord::Migration.suppress_messages { @migration.up }
  end

  # The rows this exists for cannot be created through the model, which is the
  # point — they predate the validation.
  def credential_holding(endpoint, name:)
    McpOauthCredential.create!(
      server_name: name, server_url: "https://mcp.example.com/#{name}",
      credential_key: "#{name}|#{SecureRandom.hex(8)}", client_id: "cid",
      client_secret: "secret", access_token: "at", refresh_token: "rt",
      token_endpoint: "https://placeholder.example.com/token"
    ).tap { |cred| cred.update_column(:token_endpoint, endpoint) }
  end

  test "clears every endpoint the validation refuses, and leaves the rest alone" do
    refused = {
      "plain http" => "http://auth.example.com/token",
      "http loopback" => "http://127.0.0.1:9000/token",
      "http localhost" => "http://localhost:9000/token",
      "no scheme" => "auth.example.com/token",
      # The four below are why the predicate is the validation's own rather than
      # a LIKE: each starts with the right characters and is still unusable.
      "hostless https" => "https://",
      "single-slash https" => "https:/auth.example.com/token",
      "trailing space" => "https://auth.example.com/token ",
      "unparseable" => "https://auth.example.com/a path"
    }.each_with_index.to_h { |(label, endpoint), i| [ label, credential_holding(endpoint, name: "refused-#{i}") ] }

    kept = {
      "ordinary https" => "https://auth.example.com/token",
      "uppercase scheme" => "HTTPS://auth.example.com/token",
      # post_form reads userinfo as basic auth on purpose; over TLS it stays.
      "https with userinfo" => "https://cid:secret@auth.example.com/token",
      # Already blank means "re-authorize me". Not this migration's business, and
      # skipping it keeps the reported count meaning "rows that held cleartext".
      "already blank" => ""
    }.each_with_index.to_h { |(label, endpoint), i| [ label, credential_holding(endpoint, name: "kept-#{i}") ] }
    kept_before = kept.transform_values(&:token_endpoint)

    migrate

    refused.each do |label, cred|
      assert_nil cred.reload.token_endpoint, "#{label} was left unrepaired"
      assert_predicate cred, :valid?, "#{label} is still unsavable after the migration"
      assert_not cred.can_refresh?, "#{label} should read as needing re-authorization"
    end

    kept.each do |label, cred|
      assert_equal kept_before[label], cred.reload.token_endpoint, "#{label} was rewritten and should not have been"
    end
  end

  test "is a no-op on a second run" do
    cred = credential_holding("http://auth.example.com/token", name: "legacy")
    migrate
    repaired_at = cred.reload.updated_at

    travel 1.minute do
      migrate
      assert_equal repaired_at.to_i, cred.reload.updated_at.to_i, "the second run rewrote a row it had already fixed"
    end
  end

  test "is a no-op when there is nothing to repair" do
    McpOauthCredential.delete_all
    assert_nothing_raised { migrate }
  end

  test "down refuses rather than pretending the old values can come back" do
    assert_raises(ActiveRecord::IrreversibleMigration) do
      ActiveRecord::Migration.suppress_messages { @migration.down }
    end
  end
end
