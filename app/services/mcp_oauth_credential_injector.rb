# Resolves MCP OAuth credentials for a session and routes them to the runtime's
# credential store.
#
# The OAuth machinery this depends on — discovery, dynamic client registration,
# token refresh, the credential DB models — is runtime-agnostic. The single
# runtime-specific piece is the credential *sink*: where resolved tokens get
# written so the spawned CLI can read them. That work is delegated to a
# RuntimeMcpCredentialWriter (ClaudeMcpCredentialWriter or
# CodexMcpCredentialWriter), selected via the session's runtime. This service
# retains the runtime-agnostic concerns:
# gathering credentials, refreshing those that need it, and surfacing OAuth
# status for the spawn gate.
#
# Usage:
#   injector = McpOauthCredentialInjector.new(session, working_directory: "/path/to/clone")
#   credentials_path = injector.inject_credentials!
class McpOauthCredentialInjector
  attr_reader :session, :working_directory

  # MCP transport types that can carry an OAuth flow. stdio servers are local
  # processes authenticated by env vars — there is no OAuth flow to run against them.
  REMOTE_TYPES = %w[http streamable-http sse].freeze

  # Header names that carry a static credential: `Authorization` for bearer-token
  # servers, `X-API-Key` for API-key servers — including Zimmer's own native MCP
  # server, which authenticates with the same API key as the rest of its API.
  CREDENTIAL_HEADERS = %w[authorization x-api-key].freeze

  # True when Claude Code could actually complete an OAuth flow against this server.
  #
  # This is the single source of truth for "is this an OAuth server?", shared by the
  # pre-spawn gate (#check_credentials_status) and the post-spawn MCP-failure
  # classifier (AgentSessionJob#check_and_handle_mcp_failure). A server is OAuth-capable
  # only when all of the following hold:
  #
  #   1. It is in the catalog — without a catalog entry there is no server_url, and an
  #      OAuth banner with no URL renders a dead "Authorize" button that can never
  #      resolve.
  #   2. It uses a remote transport — stdio servers have no OAuth flow.
  #   3. It does NOT configure a static credential header — that header IS the
  #      credential, so no OAuth flow is needed (or possible).
  #
  # Servers failing (3) — e.g. Zimmer's own native `zimmer*` entries, which authenticate
  # with `X-API-Key: ${ZIMMER_PROD_API_KEY}` — return 401 when their token is invalid or
  # under-scoped. That 401 is NOT an OAuth problem: completing an OAuth flow cannot mint a
  # valid API token, so routing it to the OAuth banner strands the user in an unresolvable
  # loop.
  #
  # @param server_name [String] the MCP server name
  # @return [Boolean]
  def self.oauth_capable_server?(server_name)
    server_config = ServersConfig.credential_config(server_name)
    return false if server_config.nil?
    return false unless REMOTE_TYPES.include?(server_config[:type])

    !static_credential_header?(server_config)
  end

  # True when the server config has a non-empty credential header (see
  # CREDENTIAL_HEADERS). HTTP header names are case-insensitive (RFC 7230) so we
  # match in any case. The value may still contain `${VAR}` placeholders at this
  # stage — those are resolved later by AirPrepareService. We treat the presence of
  # such a header as the operator's intent to use a static header credential.
  def self.static_credential_header?(server_config)
    headers = server_config[:headers]
    return false if headers.blank?

    headers.any? do |key, value|
      CREDENTIAL_HEADERS.include?(key.to_s.downcase) && value.to_s.strip.present?
    end
  end

  # @param session [Session] The session to inject credentials for
  # @param working_directory [String] The working directory (used for context, but credentials go to ~/.claude)
  def initialize(session, working_directory:)
    @session = session
    @working_directory = working_directory
  end

  # Injects OAuth credentials for all MCP servers configured in the session.
  # Merges with existing credentials in ~/.claude/.credentials.json.
  # Returns the path to the credentials file, or nil if no credentials are needed.
  #
  # @return [String, nil] Path to the credentials file, or nil if none written
  def inject_credentials!
    return nil if mcp_servers.blank?

    credentials = collect_credentials
    return nil if credentials.empty?

    credential_writer.write!(working_directory: working_directory, credentials: credentials)
  end

  # Checks if all required OAuth credentials are available for the session's MCP servers.
  #
  # This method attempts to refresh expired tokens before reporting them as invalid.
  # A credential is considered valid if:
  # 1. It exists and is not expired (active), OR
  # 2. It exists, is expired, but was successfully refreshed using its refresh_token
  #
  # @return [Hash] Status for each server: {server_name => {required: bool, available: bool, credential_key: String}}
  def check_credentials_status
    return {} if mcp_servers.blank?

    status = {}
    mcp_servers.each do |server_name|
      server_config = get_mcp_server_config(server_name)
      next unless server_config

      # Only check remote servers (they may require OAuth)
      next unless REMOTE_TYPES.include?(server_config[:type])

      # If mcp.json configures a static credential header for this server, that
      # header IS the credential — no OAuth flow is needed. Skip OAuth checks so
      # the gate doesn't block the session when the server's URL also happens to
      # advertise OAuth metadata (e.g. Cloudflare's hosted MCP).
      if static_credential_header?(server_config)
        Rails.logger.info "[McpOauthCredentialInjector] Skipping OAuth checks for #{server_name}: static credential header configured in mcp.json"
        next
      end

      credential_key = McpOauthCredential.compute_credential_key(server_name, server_config)

      # Don't filter by active scope - we want to find expired credentials too
      # so we can attempt to refresh them before asking for re-authentication
      credential = McpOauthCredential.for_credential_key(credential_key).first

      # Before judging expiry, adopt any token the runtime refreshed (and, for
      # rotating providers, rotated) in a prior session — otherwise the DB copy
      # can be a refresh token that's already been rotated away, and we'd report
      # the server as needing re-auth when a live token is sitting on disk.
      reconcile_from_runtime!(credential, server_name, server_config) if credential

      # If credential exists but is expired or expiring soon, try to refresh it
      # Use database-level locking to prevent concurrent refresh attempts from
      # multiple sessions, which could lead to race conditions with single-use refresh tokens
      if credential && !credential.active? && credential.can_refresh?
        Rails.logger.info "[McpOauthCredentialInjector] Attempting to refresh expired token for #{server_name}"
        begin
          credential.with_lock do
            # Re-check active status inside the lock in case another process refreshed it
            next if credential.active?
            next unless credential.can_refresh?

            if credential.refresh!
              Rails.logger.info "[McpOauthCredentialInjector] Successfully refreshed token for #{server_name}"
            end
          end
        rescue StandardError => e
          Rails.logger.warn "[McpOauthCredentialInjector] Failed to refresh token for #{server_name}: #{e.message}"
        end
      end

      # Check for pre-registered OAuth configuration in Rails credentials
      # If present, OAuth is definitely required for this server
      preregistered_oauth = PreregisteredOauthConfig.find_for_server(server_name)

      # If credential exists but is expired after a refresh attempt, this is a
      # refresh failure — the token can't be renewed. Flag it so the caller can
      # immediately require re-auth instead of letting Claude Code discover the
      # 401 after ~60 seconds of retries.
      refresh_failed = credential.present? && !credential.active? && credential.can_refresh?
      requires_reauth = credential&.requires_reauth?

      status[server_name] = {
        server_url: server_config[:url],
        credential_key: credential_key,
        has_credential: credential.present?,
        credential_valid: credential&.active?,
        needs_refresh: credential&.needs_refresh?,
        refresh_failed: refresh_failed,
        requires_reauth: requires_reauth,
        # If pre-registered OAuth config exists, OAuth is required
        # Otherwise, we can't know without probing the server
        oauth_required: preregistered_oauth.present? ? true : nil,
        has_preregistered_oauth: preregistered_oauth.present?,
        # Use to_public_h to avoid exposing client_secret in status
        preregistered_oauth_config: preregistered_oauth&.to_public_h
      }
    end

    status
  end

  # Returns a list of MCP servers that are missing required OAuth credentials.
  #
  # @param oauth_requirements [Hash] Map of server_name => requires_oauth (boolean)
  # @return [Array<Hash>] List of servers missing credentials
  def missing_credentials(oauth_requirements = {})
    status = check_credentials_status
    missing = []

    status.each do |server_name, server_status|
      requires_oauth = oauth_requirements[server_name]

      # If we don't know if OAuth is required, assume it might be for remote servers
      requires_oauth = true if requires_oauth.nil? && server_status[:server_url].present?

      if requires_oauth && !server_status[:has_credential]
        missing << {
          server_name: server_name,
          server_url: server_status[:server_url],
          credential_key: server_status[:credential_key]
        }
      end
    end

    missing
  end

  private

  # The runtime-specific credential sink for this session, resolved from the
  # session's agent_runtime via RuntimeRegistry. Claude sessions get
  # ClaudeMcpCredentialWriter; Codex sessions get CodexMcpCredentialWriter.
  def credential_writer
    @credential_writer ||= session.runtime.mcp_credential_writer_class.new
  end

  # Collects all active credentials for the session's MCP servers as
  # runtime-agnostic ResolvedMcpCredential value objects, refreshing any that
  # need it first.
  def collect_credentials
    credentials = []

    mcp_servers.each do |server_name|
      server_config = get_mcp_server_config(server_name)
      next unless server_config

      credential_key = McpOauthCredential.compute_credential_key(server_name, server_config)
      credential = McpOauthCredential.for_credential_key(credential_key).first

      next unless credential

      # Adopt any runtime-rotated token before deciding whether to refresh, so a
      # refresh runs from the freshest token rather than a rotated-away one.
      reconcile_from_runtime!(credential, server_name, server_config)

      # Refresh token if needed
      if credential.needs_refresh? && credential.can_refresh?
        begin
          credential.refresh!
        rescue => e
          Rails.logger.warn "[McpOauthCredentialInjector] Failed to refresh token for #{server_name}: #{e.message}"
        end
      end

      # Only include active credentials
      next unless credential.active?

      credentials << ResolvedMcpCredential.new(
        server_name: credential.server_name,
        server_url: credential.server_url,
        client_id: credential.client_id,
        access_token: credential.access_token,
        refresh_token: credential.refresh_token,
        expires_at: credential.expires_at,
        scope: credential.scopes,
        headers: server_config[:headers] || {},
        credential_key: credential_writer.credential_key_for(server_name, server_config)
      )
    end

    credentials
  end

  # Captures a token the runtime refreshed mid-session back into the DB before we
  # evaluate or refresh this credential. Best-effort: a read/lock failure must
  # never block a spawn, so the reconciler swallows its own errors and a runtime
  # that can't be resolved just leaves the DB copy in place.
  def reconcile_from_runtime!(credential, server_name, server_config)
    reconciler = runtime_reconciler
    return unless reconciler

    reconciler.reconcile!(
      credential,
      runtime_key: credential_writer.credential_key_for(server_name, server_config)
    )
  end

  # The reconciler reads the session runtime's on-disk credential store once and
  # reuses that snapshot across every server on the session. Returns nil (and
  # skips reconciliation) if the session's runtime credential writer can't be
  # resolved — reconciliation is an optimization, never a spawn prerequisite.
  def runtime_reconciler
    return @runtime_reconciler if defined?(@runtime_reconciler)

    @runtime_reconciler = McpOauthRuntimeReconciler.new(credential_writer)
  rescue StandardError => e
    Rails.logger.warn "[McpOauthCredentialInjector] Skipping runtime reconciliation: #{e.message}"
    @runtime_reconciler = nil
  end

  # Gets the MCP server config from the catalog
  def get_mcp_server_config(server_name)
    ServersConfig.credential_config(server_name)
  end

  def mcp_servers
    @mcp_servers ||= if session.respond_to?(:user_selected_mcp_servers)
      session.user_selected_mcp_servers
    else
      plugin_mcp_servers = session.respond_to?(:plugin_mcp_servers) ? session.plugin_mcp_servers : []
      ((session.mcp_servers || []) + plugin_mcp_servers).uniq
    end
  end

  def static_credential_header?(server_config)
    self.class.static_credential_header?(server_config)
  end
end
