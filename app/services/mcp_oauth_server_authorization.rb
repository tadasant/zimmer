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
# The post-spawn failure classifier (AgentSessionJob#check_and_handle_mcp_failure),
# the resume service, and the OAuth banner all consult this so they agree on what
# "still needs authorization" means.
module McpOauthServerAuthorization
  module_function

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
