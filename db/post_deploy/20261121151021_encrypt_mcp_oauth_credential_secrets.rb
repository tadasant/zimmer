# frozen_string_literal: true

# Fills the encrypted twins (access_token_ciphertext, refresh_token_ciphertext,
# client_secret_ciphertext) for MCP OAuth credentials written before they
# existed. From this deploy every write fills them; this covers the rows already
# in the table.
#
# A post-deploy task rather than a migration: it needs the application's
# Active Record encryption keys and the model's write path, and the old
# containers must never see a half-migrated table while the schema migration
# runs.
#
# Changes no plaintext column, so nothing that reads a credential sees any
# difference, and a revert of the code leaves every row as it was.
#
# IDEMPOTENT. It picks only rows with a secret whose twin is still empty, so a
# second run touches nothing. Each row is re-read under a row lock, so a token
# refreshed while this runs is mirrored as refreshed. Validations are skipped:
# a legacy row (an http token endpoint the validation now refuses) must still
# get its twin. Its answer — how many rows it encrypted — is in
# `post_deploy_task_runs` (on /health, in `GET /api/v1/health`, from
# `get_system_health` and at /supervisor/post_deploy_task_runs).
class EncryptMcpOauthCredentialSecrets < PostDeployTask
  def self.candidates
    McpOauthCredential.where(
      "(access_token IS NOT NULL AND access_token_ciphertext IS NULL) OR " \
      "(refresh_token IS NOT NULL AND refresh_token_ciphertext IS NULL) OR " \
      "(client_secret IS NOT NULL AND client_secret_ciphertext IS NULL)"
    )
  end

  def up
    sweep(self.class.candidates) do |batch|
      encrypted = 0
      batch.each do |credential|
        credential.with_lock do
          encrypted += 1 if credential.mirror_plaintext_secrets!
        end
      end
      checkpoint!(encrypted: stats.fetch("encrypted", 0) + encrypted)
    end
  end
end
