# Heals sessions whose mcp_servers column landed empty at creation time by
# restoring the servers the agent root currently resolves, before Zimmer re-runs AIR
# to regenerate .mcp.json.
#
# The "landed empty at create" defect: a root whose MCP servers come from
# `default_in_roots` (e.g. pulsemcp-inbox-manager → gmail-pulsemcp-readwrite-external,
# 1password-provisioning, pulse-tenants-rw) resolves those into its
# default_mcp_servers via `air resolve`, which Zimmer freezes into the session at
# create time. When the catalog resolve was structurally incomplete in that
# moment, AIR drops the unresolvable references and the column lands empty (see
# AirCatalogService for that failure mode).
#
# Every path that regenerates .mcp.json mid-life re-runs `air prepare
# --without-defaults`, which builds its server list ONLY from session.mcp_servers
# and does NOT re-resolve default_in_roots. So an empty column degrades the
# regenerated .mcp.json to just the auto-injected self-session server — silently
# stripping every configured MCP server from an in-flight task. This happens on
# unarchive (UnarchiveSessionService) AND on mid-run clone recreation / fresh
# start (AgentSessionJob), which is why the heal lives in a shared concern.
#
# Requires the includer to also include DatabaseRetry (for with_db_retry).
module McpServerBackfill
  extend ActiveSupport::Concern

  # Restore a session's MCP servers from its agent root's currently-resolved
  # defaults when the persisted mcp_servers column is empty. We only act when the
  # column is empty AND the root currently resolves a non-empty default set, so a
  # genuinely server-less root (no defaults) stays empty and falls through to
  # ensure_baseline_mcp_config!. No-op when the catalog itself cannot resolve the
  # root's defaults (returns []), so we never clobber with garbage.
  #
  # Resolved defaults are filtered through ServersConfig.exists? — the same gate
  # the sessions controller applies — so a still-structurally-incomplete catalog
  # (a name resolved into the root's defaults but absent from the catalog's mcp
  # section) can't make session.update! raise mcp_servers_must_exist_in_catalog
  # and silently abort the heal.
  #
  # @param session [Session] the session to heal
  # @return [Array<String>, nil] the restored server list if a backfill occurred, else nil
  def backfill_default_mcp_servers_if_empty(session)
    return if session.mcp_servers.present?

    defaults = session.agent_root_default_mcp_servers.select { |name| ServersConfig.exists?(name) }
    return if defaults.blank?

    backfilled = false
    with_db_retry do
      session.reload
      next if session.mcp_servers.present?

      session.update!(mcp_servers: defaults)
      backfilled = true
    end

    if backfilled
      Rails.logger.info(
        "Backfilled empty mcp_servers from agent root defaults " \
        "(session=#{session.id}, agent_root=#{session.agent_root_key}, " \
        "restored=#{defaults.inspect})"
      )
      defaults
    end
  rescue => e
    Rails.logger.warn("Failed to backfill default mcp_servers (session=#{session&.id}): #{e.message}")
    nil
  end
end
