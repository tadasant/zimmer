# frozen_string_literal: true

# Runtime-agnostic value object for an active MCP OAuth credential resolved for a
# session.
#
# McpOauthCredentialInjector produces these from the protocol-level
# McpOauthCredential records (after refreshing where needed); a
# RuntimeMcpCredentialWriter consumes them and serializes the tokens to the
# runtime-specific on-disk credential store. Nothing on this object is
# Claude-specific — it carries only the OAuth token data plus the
# runtime-computed key under which the writer should store the entry.
#
# @!attribute server_name [String] MCP server name from the catalog
# @!attribute server_url [String] the server's remote URL
# @!attribute client_id [String] OAuth client id used to obtain the token
# @!attribute access_token [String] current access token
# @!attribute refresh_token [String, nil] refresh token, if the server issued one
# @!attribute expires_at [Time, nil] access token expiry (nil = never expires)
# @!attribute scope [String, nil] OAuth scopes granted for the token
# @!attribute headers [Hash] static headers from the server config (part of the
#   credential-key identity)
# @!attribute credential_key [String] the key the runtime writer stores this
#   entry under, computed via RuntimeMcpCredentialWriter#credential_key_for
ResolvedMcpCredential = Data.define(
  :server_name,
  :server_url,
  :client_id,
  :access_token,
  :refresh_token,
  :expires_at,
  :scope,
  :headers,
  :credential_key
)
