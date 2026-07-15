# frozen_string_literal: true

# Runtime-agnostic snapshot of a single MCP OAuth token entry read back OUT of an
# agent runtime's on-disk credential store.
#
# It is the read-side mirror of ResolvedMcpCredential: where ResolvedMcpCredential
# carries a DB credential TO a RuntimeMcpCredentialWriter, this carries whatever
# the runtime last wrote (possibly a token it refreshed and rotated mid-session)
# BACK so McpOauthRuntimeReconciler can persist it into McpOauthCredential.
#
# Only the fields needed to detect and adopt a rotation are captured — the
# access/refresh token pair and the access token's expiry. Everything else in the
# DB row (client_id, token_endpoint, resource, …) is unchanged by a runtime
# refresh, so it is not read back.
#
# @!attribute access_token [String, nil] the access token currently on disk
# @!attribute refresh_token [String, nil] the refresh token currently on disk
# @!attribute expires_at [Time, nil] when the on-disk access token expires
#   (nil = the runtime stored no expiry)
RuntimeMcpTokenSnapshot = Data.define(
  :access_token,
  :refresh_token,
  :expires_at
)
