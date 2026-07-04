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
# - `with_db_retry` — from the DatabaseRetry concern
module McpStatusPersisting
  # Update session's custom_metadata with MCP server statuses
  # @param server_statuses [Hash] Server name => { status:, error:, connected_at:, failed_at: }
  # @return [Boolean] true if any configured server changed to failed
  def update_session_mcp_status(server_statuses)
    return false if server_statuses.empty?

    configured_servers = @session.user_selected_mcp_servers
    trackable_servers = @session.all_mcp_servers
    return false if trackable_servers.empty?

    any_failed = false
    failed_servers = []

    with_db_retry do
      @session.reload
      current_metadata = @session.custom_metadata || {}
      current_mcp_status = current_metadata["mcp_servers_status"] || {}

      # Update status for both configured and auto-injected servers so the UI
      # can show real connection state for every server in the runtime config.
      trackable_servers.each do |server_name|
        new_status = server_statuses[server_name]
        next unless new_status

        current_status = current_mcp_status[server_name] || { "status" => "pending" }

        # Only update if status changed
        if current_status["status"] != new_status[:status]
          current_mcp_status[server_name] = {
            "status" => new_status[:status],
            "error" => new_status[:error],
            "connected_at" => new_status[:connected_at],
            "failed_at" => new_status[:failed_at]
          }.compact
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
      end

      # Update custom_metadata
      updated_metadata = current_metadata.merge(
        "mcp_servers_status" => current_mcp_status
      )

      # If any configured server failed, mark session for failure
      if any_failed && !current_metadata["mcp_connection_checked"]
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
        # racing on the shared `_npx` cache (GitHub issues #3924 / #4109).
        #
        # Per the logging philosophy (CLAUDE.md), an intermediate attempt that has
        # downstream retry logic logs at .info; the .error that pages on-call is
        # reserved for the terminal case (retries exhausted ->
        # failure_reason: mcp_connection_failed), emitted from AgentSessionJob.
        # Logging .error here tripped the global prod-ERROR Grafana alert for every
        # transient, self-healing flap.
        @logger.info("MCP server(s) detected as failed; flagging session for retry/failure handling", failed_servers: failed_servers)
      end

      @session.update!(custom_metadata: updated_metadata)
    end

    any_failed
  end
end
