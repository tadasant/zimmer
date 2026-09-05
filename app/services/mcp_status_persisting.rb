# Shared persistence of per-MCP-server connection statuses onto a Session's
# custom_metadata.
#
# Each runtime detects MCP connection state from a different signal — Claude
# Code from per-server log files (McpLogPollerService), Codex from rollout
# `function_call` events naming each server (CodexMcpStatusDetector) — but once a
# detector has produced a `server_statuses` hash, the persistence semantics are
# identical: write the changed statuses into `custom_metadata["mcp_servers_status"]`,
# and escalate a *configured* (not merely injected) server failure to a
# session-level failure. Centralizing that here keeps the two runtimes byte-for-byte
# consistent in how status is recorded and how failures escalate.
#
# Including classes must provide:
# - `@session`  — the Session being tracked
# - `@logger`   — a StructuredLogger
#
# `with_db_retry` is deliberately NOT a third item on that list: the module
# includes DatabaseRetry itself, so an includer gets it whether or not it
# remembers to ask. A dependency a module can satisfy for itself is not one to
# ask callers for — asking cost the Pi runtime every MCP status it had, because
# NullMcpStatusDetector included this module and not DatabaseRetry, and the call
# below raised NoMethodError on every poll (GlitchTip issue 85).
#
# Plain `include`, not `extend ActiveSupport::Concern`. Concern overrides
# `append_features` but not `extend_object`, so under it DatabaseRetry lands in
# each includer's ancestors while staying out of this module's own — and
# `obj.extend(McpStatusPersisting)` would reproduce exactly the NoMethodError
# above. A plain include puts DatabaseRetry in the real ancestor chain, where
# both `include` and `extend` reach it.
module McpStatusPersisting
  include DatabaseRetry

  # Update session's custom_metadata with MCP server statuses
  # @param server_statuses [Hash] Server name => { status:, error:, connected_at:, failed_at: }
  # @return [Boolean] true if any configured server changed to failed
  def update_session_mcp_status(server_statuses)
    configured_servers = @session.user_selected_mcp_servers
    trackable_servers = @session.all_mcp_servers
    return false if trackable_servers.empty?

    any_failed = false
    failed_servers = []
    reconnected_servers = []
    # Whether this poll actually has something to persist. Polls are frequent and
    # mostly say nothing new, and `updated_metadata` always names
    # `mcp_servers_status`, so without this an unchanged poll would still issue an
    # UPDATE and re-broadcast the session card several times a minute per live
    # session.
    status_changed = false

    with_db_retry do
      @session.reload
      current_metadata = @session.custom_metadata || {}
      current_mcp_status = current_metadata["mcp_servers_status"] || {}
      degraded_names = @session.degraded_mcp_server_names.to_set

      # Update status for both configured and auto-injected servers so the UI
      # can show real connection state for every server in the runtime config.
      trackable_servers.each do |server_name|
        new_status = server_statuses[server_name]

        # A server the detector said nothing about is not a server that is not
        # there. Claude Code writes a per-server log directory only once the
        # process gets far enough to log; a server whose process died before that
        # produces no status at all, and skipping it here left it absent from
        # mcp_servers_status entirely. The session views already read an absent
        # key as pending, but the JSON consumers do not: the REST API and the
        # get_session MCP tool hand back custom_metadata verbatim, so a broken
        # server simply was not in it, and absent there reads as "not configured"
        # rather than "configured and broken". Seed the same `pending` the views
        # assume so every consumer sees the server listed.
        #
        # Writing only when the key is absent is the whole safety property: the
        # placeholder is a floor, so a real status — from this poll or any
        # earlier one — is never overwritten by it.
        if new_status.nil?
          unless current_mcp_status.key?(server_name)
            current_mcp_status[server_name] = Session::MCP_STATUS_PENDING
            status_changed = true
          end
          next
        end

        current_status = current_mcp_status[server_name] || Session::MCP_STATUS_PENDING

        # Only update if status changed
        if current_status["status"] != new_status[:status]
          current_mcp_status[server_name] = {
            "status" => new_status[:status],
            "error" => new_status[:error],
            "connected_at" => new_status[:connected_at],
            "failed_at" => new_status[:failed_at]
          }.compact
          status_changed = true
        end

        # Only selected-server failures escalate to a session-level failure.
        # An injected-server failure is still recorded in mcp_servers_status
        # (so the UI can render it red), but it does not trigger the
        # should_fail_session path — that semantics is reserved for servers
        # the user explicitly asked for directly or through a selected plugin.
        if new_status[:status] == "failed" && configured_servers.include?(server_name)
          any_failed = true
          failed_servers << { "name" => server_name, "status" => "failed", "error" => new_status[:error] }
        end

        # A server this session had written off has come back. This is the only
        # signal that is actually true about the outage being over — no restart or
        # sweep can know it — so it is what retires the write-off, rather than a
        # timer or a metadata clear on some recovery path. Retiring it stops the
        # agent's prompt claiming a working server is unavailable, and re-arms the
        # retry ladder if the server fails again later.
        if new_status[:status] == "connected" && degraded_names.include?(server_name)
          reconnected_servers << server_name
        end
      end

      # Only the keys this pass actually computed — a whole-column write from
      # current_metadata would erase whatever landed since the reload above.
      updated_metadata = { "mcp_servers_status" => current_mcp_status }

      # If any configured server failed, mark session for failure
      if any_failed && !current_metadata["mcp_connection_checked"]
        status_changed = true
        updated_metadata["mcp_connection_checked"] = true
        updated_metadata["should_fail_session"] = true
        updated_metadata["mcp_failed_servers"] = failed_servers
        updated_metadata["mcp_failure_reason"] = "MCP server(s) failed to connect: #{failed_servers.map { |s| s['name'] }.join(', ')}"

        # This is the *intermediate* detection of an MCP connection failure, not a
        # terminal one. AgentSessionJob#check_and_handle_mcp_failure consumes
        # should_fail_session and retries the session with backoff (healing a
        # corrupt npx cache along the way), and in production these failures
        # overwhelmingly self-heal on retry — the dominant signature is the
        # `npx`-launched plugin servers (e.g. playwright-custom, remote-fs-screenshots)
        # racing on the shared `_npx` cache (pulsemcp/pulsemcp#3924 and
        # pulsemcp/pulsemcp#4109).
        #
        # Per the logging philosophy (CLAUDE.md), an intermediate attempt that has
        # downstream retry logic logs at .info. Logging .error here tripped the
        # global prod-ERROR Grafana alert for every transient, self-healing flap.
        # No MCP-connect path emits .error any more: exhausting the ladder leaves
        # the server out and the session running, which AgentSessionJob reports at
        # .warn because it costs a capability rather than a session.
        @logger.info("MCP server(s) detected as failed; flagging session for retry/failure handling", failed_servers: failed_servers)
      end

      @session.merge_custom_metadata!(updated_metadata) if status_changed

      if reconnected_servers.any?
        remaining = @session.degraded_mcp_servers.reject { |entry| reconnected_servers.include?(entry["name"]) }
        @logger.info("MCP server(s) reconnected; retiring the degraded record", servers: reconnected_servers)
        if remaining.any?
          @session.merge_metadata!("mcp_degraded_servers" => remaining)
        else
          @session.remove_metadata!("mcp_degraded_servers")
        end
      end
    end

    any_failed
  end
end
