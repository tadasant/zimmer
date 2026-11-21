# frozen_string_literal: true

# Expand phase of encrypting MCP OAuth credentials at rest.
#
# Adds an Active Record–encrypted twin of each secret column. From this deploy
# McpOauthCredential writes every secret to both its plaintext column and its
# encrypted twin, and reads only the plaintext column, so:
#
# - the old containers still serving during the cutover read and write exactly
#   what they always did;
# - reverting the code leaves every row readable, because the plaintext column
#   is still current;
# - rolling this migration back drops only the twins, which hold nothing the
#   plaintext columns do not.
#
# `access_token` loses its NOT NULL here, ahead of the contract phase that will
# stop writing plaintext. Relaxing a constraint is invisible to code that keeps
# writing the column, so it is safe in the expand deploy, and it means the
# contract phase needs no schema change at all.
#
# Existing rows get their twins from the EncryptMcpOauthCredentialSecrets
# post-deploy task. All three are plain `add_column`s of nullable columns: no
# rewrite, no lock beyond the instant of the catalog change.
class AddEncryptedSecretColumnsToMcpOauthCredentials < ActiveRecord::Migration[8.1]
  def change
    add_column :mcp_oauth_credentials, :access_token_ciphertext, :text
    add_column :mcp_oauth_credentials, :refresh_token_ciphertext, :text
    add_column :mcp_oauth_credentials, :client_secret_ciphertext, :text
    change_column_null :mcp_oauth_credentials, :access_token, true
  end
end
