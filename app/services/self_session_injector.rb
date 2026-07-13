# frozen_string_literal: true

# Decides whether a session needs Zimmer's own MCP server injected into its
# runtime config, and resolves the Zimmer instance (BASE_URL / API_KEY) those
# entries should point at.
#
# Zimmer serves MCP natively (McpController → Mcp::Server), so an injected entry
# is a streamable-HTTP server pointing back at this instance's /mcp endpoint,
# scoped with query params:
#
#   self-session : /mcp?tool_groups=self_session
#   subagent     : /mcp?allowed_agent_roots=<roots>   (full surface, restricted roots)
#
# This is runtime-agnostic: it decides *what* entry to write and *whether* it is
# needed (the dedup rule), but not how to serialize it. The per-runtime config
# post-processor passes in the servers already present and writes the chosen
# entry in its native format (`.mcp.json` for Claude, `.codex/config.toml` for
# Codex).
class SelfSessionInjector
  # Entry name for the auto-injected self-session server. Every session gets one
  # (unless something else already covers the surface) — that is what makes
  # self-archiving, own-notes/title edits and the wake-up tools universally
  # available.
  SELF_SESSION_SERVER_NAME = "zimmer-self-session"

  # Entry name for the server injected into roots that declare
  # default_subagent_roots, so they can spawn their subagent sessions.
  SUBAGENT_SERVER_NAME = "zimmer"

  API_KEY_HEADER = "X-API-Key"

  # @param env [String] the Rails environment name (injectable for testing)
  # @param secrets_interpolator [SecretsInterpolator] resolves env-var lookups
  def initialize(env: Rails.env, secrets_interpolator: SecretsInterpolator.new)
    @env = env.to_s
    @secrets_interpolator = secrets_interpolator
  end

  # Inject the self-session server unless a server already present covers the
  # self_session tool group.
  #
  # @param existing_servers [Array<Hash>] one entry per MCP server already present,
  #   each shaped `{ name: String, url: String|nil }`. The caller extracts these from
  #   its native config so the dedup rule stays format-agnostic.
  # @yield [String, String, Hash] entry name, endpoint URL, headers; the block writes
  #   the entry in the runtime's native format.
  # @return [String, nil] the injected entry name, or nil if injection was skipped.
  def inject!(existing_servers:)
    return nil if self_session_capable_present?(existing_servers)

    yield(SELF_SESSION_SERVER_NAME, endpoint_url(tool_groups: "self_session"), headers)
    SELF_SESSION_SERVER_NAME
  end

  # A Zimmer MCP entry with no tool_groups exposes the full surface — which
  # includes every self_session tool — so a dedicated self-session entry would be
  # redundant. This is what keeps a root with default_subagent_roots (whose
  # injected `zimmer` server is full-surface) from carrying two Zimmer servers.
  #
  # An entry that scopes itself to a group set covers self-session only if
  # self_session is among those groups.
  def self_session_capable_present?(existing_servers)
    existing_servers.any? do |server|
      name = server[:name].to_s
      next false if name == SELF_SESSION_SERVER_NAME
      next false unless zimmer_server_name?(name)
      # No URL means it is not one of our HTTP entries after all (a hand-written
      # stdio entry, say). Skipping injection on that basis would silently strip a
      # session's self-archiving and wake-up tools, so treat it as not covering the
      # surface.
      next false if server[:url].blank?

      groups = tool_groups_in(server[:url])
      groups.empty? || groups.include?("self_session")
    end
  end

  # Zimmer's own MCP entries are identified by name — `zimmer` (injected
  # full-surface) and `zimmer-*` (injected or catalog-resolved scoped variants).
  # Matching on the name rather than the URL keeps a third-party server that
  # happens to be served at /mcp from being mistaken for one of ours.
  def zimmer_server_name?(name)
    name.to_s == SUBAGENT_SERVER_NAME || name.to_s.start_with?("#{SUBAGENT_SERVER_NAME}-")
  end

  # The MCP endpoint of the Zimmer instance this Rails process IS, optionally
  # scoped. Used both to build injected entries and to retarget catalog-resolved
  # Zimmer servers, so a local-dev or staging session orchestrates itself rather
  # than production.
  def endpoint_url(tool_groups: nil, allowed_agent_roots: nil)
    query = {}
    query["tool_groups"] = tool_groups if tool_groups.present?
    query["allowed_agent_roots"] = allowed_agent_roots if allowed_agent_roots.present?

    url = "#{self_target[:base_url].to_s.chomp('/')}/mcp"
    query.any? ? "#{url}?#{query.to_query}" : url
  end

  def headers
    { API_KEY_HEADER => self_target[:api_key] }
  end

  # BASE_URL and API_KEY for the Zimmer instance this Rails process IS.
  #
  # The env var names carry the ZIMMER_ prefix, provisioned as deploy secrets
  # (config/deploy.*.yml, .kamal/secrets.*), as prod's encrypted mcp_secrets, and as
  # what the AIR catalog interpolates. The prod/staging names are dual-set alongside
  # the legacy AGENT_ORCHESTRATOR_* names (same values) until those are retired.
  def self_target
    @self_target ||= {
      base_url: AppUrl.base_url(env: @env, secrets_interpolator: @secrets_interpolator),
      api_key: get_env_value(api_key_var).to_s
    }
  end

  private

  # The tool_groups an entry's endpoint URL scopes itself to. An empty list means
  # the full surface (that is also what a URL-less entry reports, which only
  # happens for a malformed Zimmer entry).
  def tool_groups_in(url)
    return [] if url.blank?

    query = URI.parse(url.to_s).query
    Rack::Utils.parse_query(query)["tool_groups"].to_s.split(",").map(&:strip).reject(&:empty?)
  rescue URI::InvalidURIError
    []
  end

  def get_env_value(var_name)
    @secrets_interpolator.get_env_value(var_name)
  end

  # The API-key secret name for the Zimmer instance this Rails process IS,
  # paired with the base URL that AppUrl resolves for the same environment.
  def api_key_var
    case @env
    when "production" then "ZIMMER_PROD_API_KEY"
    when "staging" then "ZIMMER_STAGING_API_KEY"
    else "ZIMMER_LOCAL_API_KEY"
    end
  end
end
