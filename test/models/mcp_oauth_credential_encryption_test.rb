# frozen_string_literal: true

require "test_helper"

# The expand phase of encrypting MCP OAuth credentials at rest: every secret is
# written to its plaintext column and to an encrypted twin, reads take the
# plaintext only, and a legacy row (plaintext only) reads exactly as before.
class McpOauthCredentialEncryptionTest < ActiveSupport::TestCase
  def raw(credential, column)
    McpOauthCredential.connection.select_value(
      McpOauthCredential.where(id: credential.id).select(column).to_sql
    )
  end

  test "a write fills both the plaintext column and an encrypted twin that does not contain the secret" do
    credential = mcp_oauth_credentials(:notion)
    credential.update!(access_token: "at-secret-value", refresh_token: "rt-secret-value", client_secret: "cs-secret-value")

    %w[access_token refresh_token client_secret].each do |column|
      ciphertext = raw(credential, "#{column}_ciphertext")
      assert ciphertext.present?, "#{column} was not mirrored"
      assert_not_includes ciphertext, "secret-value", "#{column}_ciphertext is not encrypted"
      assert_equal raw(credential, column), credential.reload.public_send("#{column}_ciphertext")
    end
  end

  test "clearing a secret clears its twin" do
    credential = mcp_oauth_credentials(:notion)
    credential.update!(refresh_token: "rt")
    credential.update!(refresh_token: nil)

    assert_nil raw(credential, "refresh_token_ciphertext")
    assert_nil credential.reload.refresh_token
  end

  test "a legacy row with plaintext only reads as before" do
    credential = mcp_oauth_credentials(:notion)
    assert_nil raw(credential, "access_token_ciphertext")
    assert_equal "test-access-token-12345", credential.access_token
  end

  test "a NULL plaintext reads as NULL even when its twin still holds a value" do
    credential = mcp_oauth_credentials(:notion)
    credential.update!(refresh_token: "rt-revoked")
    credential.update_column(:refresh_token, nil)

    assert_nil credential.reload.refresh_token, "a secret cleared outside the writers must stay cleared"
  end

  test "any save of a legacy row fills the twins it is missing" do
    credential = mcp_oauth_credentials(:notion)
    credential.update!(scopes: "read")

    assert_equal "test-access-token-12345", credential.reload.access_token_ciphertext
  end

  test "mirror_plaintext_secrets! encrypts a legacy row without touching plaintext, once" do
    credential = mcp_oauth_credentials(:notion)
    updated_at = credential.updated_at

    assert credential.mirror_plaintext_secrets!
    assert_equal "test-access-token-12345", raw(credential, "access_token")
    assert_equal "test-access-token-12345", credential.reload.access_token_ciphertext
    assert_equal updated_at.to_i, credential.updated_at.to_i
    assert_not credential.mirror_plaintext_secrets!, "a second pass has nothing to do"
  end

  test "the encryption post-deploy task fills every missing twin and is a no-op the second time" do
    entry = PostDeployTask::Registry.all.find { |e| e.task_name == "EncryptMcpOauthCredentialSecrets" }
    assert entry, "the task file must ship in db/post_deploy"
    legacy = McpOauthCredential.where(access_token_ciphertext: nil).count
    assert legacy.positive?

    first, outcome = run_task(entry)
    assert_nil outcome
    assert_equal legacy, first.stats["encrypted"]
    assert_equal 0, entry.task_class.candidates.count
    McpOauthCredential.find_each { |c| assert_equal raw(c, "access_token"), c.access_token_ciphertext }

    second, = run_task(entry)
    assert_equal 0, second.stats.fetch("encrypted", 0)
  end

  def run_task(entry)
    run = PostDeployTaskRun.create!(version: "#{entry.version}-#{SecureRandom.hex(4)}", name: entry.task_name, status: "pending")
    assert run.claim!(owner: "test")
    outcome = entry.task_class.new(run: run, logger: Rails.logger).up
    [ run.reload, outcome ]
  end
end
