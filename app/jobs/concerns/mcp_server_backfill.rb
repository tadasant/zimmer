# Heals sessions whose mcp_servers column landed empty at creation time by
# restoring the servers the agent root currently resolves, before Zimmer re-runs AIR
# to regenerate .mcp.json.
#
# The "landed empty at create" defect: a root whose MCP servers come from
# `default_in_roots` (e.g. an inbox-manager root → gmail-readwrite,
# 1password-provisioning, tenants-rw) resolves those into its
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

  # Detect a regenerated .mcp.json that carries FEWER MCP servers than the
  # session previously had, and return the lost names.
  #
  # Every mid-life regeneration path (mid-run clone recreation, fresh start on a
  # reused clone, unarchive) rebuilds .mcp.json from scratch via `air prepare
  # --without-defaults`. If anything upstream narrowed the session's artifact
  # columns, that regeneration silently hands the agent a smaller toolset than
  # it had a moment ago — and the agent has no way to notice. A session losing
  # its tools is broken system behavior that will not self-resolve, so per the
  # repo's logging philosophy this belongs at WARN, not INFO, and not unlogged.
  #
  # `custom_metadata["mcp_servers_status"]` is a hash keyed by server name that
  # records the runtime status the session last reported for each server it had
  # configured. Comparing its keys against the set AIR just wrote (user-selected
  # + plugin-derived + auto-injected) catches a narrowing regardless of which
  # upstream path caused it. Deliberate user removals prune themselves out of
  # that hash via Session#forget_mcp_server_status!, so what remains here is an
  # unexplained loss.
  #
  # @param session [Session] the session whose config was just regenerated
  # @param injected_servers [Array<String>, nil] names AIR auto-injected this run
  # @param context [String] short label for the regeneration path, used in logs
  # @return [Array<String>] server names lost relative to the session's history
  def detect_lost_mcp_servers(session, injected_servers, context:)
    previously_seen = (session.custom_metadata || {})["mcp_servers_status"]
    return [] if previously_seen.blank?

    effective = (session.user_selected_mcp_servers + Array(injected_servers)).uniq
    lost = previously_seen.keys - effective
    return [] if lost.empty?

    Rails.logger.warn(
      "[McpServerBackfill] Regenerated MCP config dropped server(s) #{lost.inspect} " \
      "(session=#{session.id}, agent_root=#{session.agent_root_key}, context=#{context}). " \
      "The session previously connected to them and will now run without them."
    )
    lost
  rescue => e
    Rails.logger.warn("Failed to detect lost mcp_servers (session=#{session&.id}): #{e.message}")
    []
  end
end
