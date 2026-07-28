# frozen_string_literal: true

# Answers one question consistently, everywhere Zimmer decides whether an MCP
# server still needs the user to authorize it: does an active (unexpired)
# credential for that server already exist?
#
# The invariant this exists to enforce: **a server Zimmer already holds a valid
# credential for must never be presented as needing OAuth authorization.**
# McpOauthController#initiate short-circuits on an existing active credential, so
# an "Authorize" button for such a server can never resolve — it redirects
# straight back to the session page, which reads to the user as "the button does
# nothing". A 401 from a server we hold a valid token for is not a missing
# authorization; it is the runtime failing to honor the token we injected.
#
# The converse matters just as much: **a credential the provider has revoked is
# not a valid credential**, even though its row is still present and unexpired.
# When a connect failure carries `invalid_grant` / "Invalid refresh token", the
# refresh token is dead at the provider and no local retry can revive it — so
# #invalidate! force-expires the row and the server routes to re-authorization
# instead of riding the retry ladder into an orphaned session (GitHub issue #222).
#
# The post-spawn failure classifier (AgentSessionJob#check_and_handle_mcp_failure),
# the resume service, and the OAuth banner all consult this so they agree on what
# "still needs authorization" means.
module McpOauthServerAuthorization
  # Error text from an MCP server's connect failure that means the *provider*
  # rejected the refresh grant: the refresh token was revoked, expired, or
  # already rotated away. Claude Code surfaces this verbatim, e.g.
  # "Token refresh failed with invalid_grant: Invalid refresh token".
  #
  # These are the same permanent grant errors McpOauthCredential classifies when
  # Zimmer refreshes a token itself (PERMANENT_REFRESH_ERRORS), plus the
  # human-readable phrasing providers pair them with. Nothing local can revive
  # such a credential — only the user re-authorizing can.
  REFRESH_TOKEN_REJECTED_PATTERN = Regexp.union(
    /invalid_grant/i,
    /invalid_client/i,
    /unauthorized_client/i,
    /invalid refresh token/i
  )

  module_function

  # True when a connect error says the provider rejected the refresh grant, so
  # the stored credential is permanently dead and only re-authorization helps.
  #
  # @param error [String, nil] the raw error text reported for a failed server
  # @return [Boolean]
  def refresh_token_rejected?(error)
    error.to_s.match?(REFRESH_TOKEN_REJECTED_PATTERN)
  end

  # Force-expires the stored credential for a server whose refresh token the
  # provider rejected, so every "is this authorized?" check — this module's
  # #authorized? and McpOauthController#initiate's short-circuit alike — agrees
  # that the user must re-authorize.
  #
  # Both tokens go: the access token is dropped (force-expired) rather than left
  # to run out its TTL because this is only called after the runtime already
  # tried it and got a 401, and the refresh token is nulled because the provider
  # just told us it is dead. Contrast McpOauthCredential#invalidate_refresh_token!,
  # which preserves a still-usable access token when only the *refresh* failed.
  #
  # @param server_info [Hash] an `oauth_required_servers`-shaped entry
  # @return [Boolean] true when a credential row was invalidated.
  def invalidate!(server_info)
    key = credential_key_for(server_info)
    return false if key.blank?

    credentials = McpOauthCredential.for_credential_key(key).active.to_a
    return false if credentials.empty?

    credentials.each { |credential| credential.update!(refresh_token: nil, expires_at: 1.second.ago) }
    true
  end

  # @param server_info [Hash] an `oauth_required_servers` entry — string- or
  #   symbol-keyed — carrying at least a server_name, and optionally a
  #   credential_key / server_url used to derive one.
  # @return [Boolean] true when an active credential already exists for it.
  def authorized?(server_info)
    key = credential_key_for(server_info)
    return false if key.blank?

    McpOauthCredential.for_credential_key(key).active.exists?
  end

  # Filters a list of recorded server entries down to those that genuinely still
  # need the user to authorize them.
  #
  # @param server_infos [Array<Hash>]
  # @return [Array<Hash>]
  def still_needing_authorization(server_infos)
    Array(server_infos).reject { |server_info| authorized?(server_info) }
  end

  # Resolves the credential key for a recorded server entry. Prefers the key
  # persisted alongside the entry, and otherwise derives it from the catalog
  # config — falling back to the recorded server_url so entries written by the
  # post-spawn failure path (which records a catalog miss) still resolve.
  #
  # @param server_info [Hash]
  # @return [String, nil] nil when no key can be derived.
  def credential_key_for(server_info)
    key = server_info["credential_key"] || server_info[:credential_key]
    return key if key.present?

    server_name = server_info["server_name"] || server_info[:server_name]
    return nil if server_name.blank?

    config = ServersConfig.credential_config(server_name)
    config ||= { type: "http", url: server_info["server_url"] || server_info[:server_url] }
    return nil if config[:url].blank?

    McpOauthCredential.compute_credential_key(server_name, config)
  end
end
