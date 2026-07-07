# frozen_string_literal: true

# Decides whether a session needs a dedicated self-session agent-orchestrator
# MCP server injected, and resolves the per-environment Zimmer instance target
# (BASE_URL / API_KEY) that Zimmer servers should point at.
#
# This is runtime-agnostic: it reasons about *which* catalog entry to inject and
# *whether* injection is needed (the dedup rule), but it does not know how to
# write the entry in any particular config format. The per-runtime config
# post-processor passes in a description of the Zimmer servers already present and a
# sink block that writes the chosen entry in its native format (`.mcp.json` for
# Claude, `.codex/config.toml` for Codex).
class SelfSessionInjector
  # The catalog key for the self-session Zimmer server, per environment. Dev/test
  # have no dedicated entry, so they fall back to the staging-flavored one and
  # rely on the post-processor's env retargeting to point it at the local
  # instance.
  SELF_SESSION_CATALOG_KEYS = {
    "production" => "agent-orchestrator-prod-self-session",
    "staging" => "agent-orchestrator-staging-self-session"
  }.freeze

  # @param env [String] the Rails environment name (injectable for testing)
  # @param secrets_interpolator [SecretsInterpolator] resolves env-var lookups
  def initialize(env: Rails.env, secrets_interpolator: SecretsInterpolator.new)
    @env = env.to_s
    @secrets_interpolator = secrets_interpolator
  end

  def catalog_key
    SELF_SESSION_CATALOG_KEYS.fetch(@env, SELF_SESSION_CATALOG_KEYS["staging"])
  end

  # Inject the self-session Zimmer server unless an existing Zimmer server already
  # exposes the self_session tool group.
  #
  # @param existing_ao_servers [Array<Hash>] one entry per MCP server already
  #   present, each shaped `{ name: String, tool_groups: String|nil }`. The
  #   caller extracts these from its native config so the dedup rule stays
  #   format-agnostic.
  # @yield [String, ServersConfig::Server] the catalog key + resolved catalog
  #   server; the block writes the entry in the runtime's native format.
  # @return [String, nil] the injected catalog key, or nil if injection was
  #   skipped (dedup hit or catalog entry missing).
  def inject!(existing_ao_servers:)
    return nil if self_session_capable_present?(existing_ao_servers)

    key = catalog_key
    catalog_server = ServersConfig.find(key)
    unless catalog_server
      Rails.logger.warn "[SelfSessionInjector] Self-session catalog entry '#{key}' not found, skipping injection"
      return nil
    end

    yield(key, catalog_server)
    key
  end

  # An Zimmer server with TOOL_GROUPS blank exposes the full tool surface — including
  # the self_session group — which makes the dedicated self-session server
  # redundant.
  #
  # The self_session group is action_session (filtered to update_notes,
  # update_title, archive), get_session, get_configs, send_push_notification,
  # wake_me_up_later, and wake_me_up_when_session_changes_state. (start_session
  # and quick_search_sessions belong to the broader `sessions` group, not
  # self_session — but a blank-tool_groups server exposes both groups anyway.)
  #
  # ALLOWED_AGENT_ROOTS does NOT hide tools at registration time; it only adds
  # call-time guards on a few actions: creating sessions (start_session),
  # creating or modifying triggers (action_trigger create/update), and changing
  # a session's MCP servers (action_session change_mcp_servers). None of those
  # touch the self_session surface — its action_session is filtered to
  # update_notes/update_title/archive, so change_mcp_servers is never exposed.
  # The one self_session tool with a call-time guard is
  # wake_me_up_when_session_changes_state, and it guards only the *watched*
  # session (it refuses to schedule a wake on a session outside the allowed
  # roots); a session waking *itself* via wake_me_up_later is never guarded. So
  # the self-management use of the self_session tools keeps working even when
  # the full-surface server carries ALLOWED_AGENT_ROOTS. Subagent roots that go
  # through this path are orchestrated by a parent and don't currently watch
  # sessions outside their allowed roots — cross-session wakes are exercised by
  # ao-router, which lists agent-orchestrator-prod in default_mcp_servers
  # directly and doesn't go through this dedup. If a future subagent root needs
  # to watch a session outside its allowed roots, the cleaner fix is to relax
  # that guard, not to inject a duplicate self-session server.
  #
  # Avoiding the duplicate also prevents two concurrent
  # `npx … agent-orchestrator-mcp-server@latest` invocations from racing on
  # npm's shared `_npx/<hash>` cache directory, which has caused tar-extraction
  # corruption + ERR_MODULE_NOT_FOUND on session start.
  def self_session_capable_present?(existing_ao_servers)
    self_key = catalog_key
    existing_ao_servers.any? do |server|
      server[:name].to_s.include?("agent-orchestrator") &&
        server[:name] != self_key &&
        server[:tool_groups].blank?
    end
  end

  # BASE_URL and API_KEY for the Zimmer instance this Rails process IS. Used both to
  # retarget catalog-resolved Zimmer servers and to populate auto-injected Zimmer
  # servers so a local-dev or staging session orchestrates itself, not
  # production.
  def ao_self_target
    case @env
    when "production"
      {
        base_url: get_env_value("AGENT_ORCHESTRATOR_PROD_BASE_URL") || "https://zimmer.example.com",
        api_key: get_env_value("AGENT_ORCHESTRATOR_PROD_API_KEY").to_s
      }
    when "staging"
      {
        base_url: get_env_value("AGENT_ORCHESTRATOR_STAGING_BASE_URL") || "https://staging.zimmer.example.com",
        api_key: get_env_value("AGENT_ORCHESTRATOR_STAGING_API_KEY").to_s
      }
    else
      {
        base_url: get_env_value("AGENT_ORCHESTRATOR_LOCAL_BASE_URL") || default_local_base_url,
        api_key: get_env_value("AGENT_ORCHESTRATOR_LOCAL_API_KEY").to_s
      }
    end
  end

  private

  def get_env_value(var_name)
    @secrets_interpolator.get_env_value(var_name)
  end

  def default_local_base_url
    port = ENV["PORT"].presence || "3000"
    "http://localhost:#{port}"
  end
end
