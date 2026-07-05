# frozen_string_literal: true

require "test_helper"

class McpLogPollerServiceTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @mock_file_system = MockFileSystemAdapter.new

    # Set up session with working_directory and mcp_servers
    # Use actual server names from mcp.json config to pass validation
    @session.update!(
      metadata: { "working_directory" => "/Users/admin/test-project" },
      mcp_servers: [ "context7", "playwright-custom" ]
    )
  end

  # === Basic Polling Tests ===

  test "poll returns empty results when mcp log directory does not exist" do
    # Don't create any directories - directory? will return false
    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll

    assert_equal [], result[:logs]
    assert_equal({}, result[:server_statuses])
  end

  test "poll returns empty results when no mcp-logs-* directories exist" do
    # Create the cache directory but no mcp-logs-* subdirectories
    @mock_file_system.mkdir_p(mcp_cache_dir)

    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll

    assert_equal [], result[:logs]
    assert_equal({}, result[:server_statuses])
  end

  test "poll reads and parses mcp log files from server directories" do
    setup_mcp_log_directory_with_logs

    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll

    assert_equal 2, result[:logs].length
    assert_equal "context7", result[:logs][0][:server_name]
    assert_equal "Starting connection with timeout of 30000ms", result[:logs][0][:message]
  end

  test "poll finds .jsonl files (Claude CLI actual format)" do
    # This test validates we're looking for the correct file extension
    # that Claude CLI actually creates
    server_dir = File.join(mcp_cache_dir, "mcp-logs-context7")
    log_file = File.join(server_dir, "2025-12-13T00-07-09-351Z.jsonl")

    @mock_file_system.mkdir_p(mcp_cache_dir)
    @mock_file_system.mkdir_p(server_dir)
    @mock_file_system.write(log_file, to_jsonl([
      { "debug" => "Test message", "timestamp" => "2025-12-13T00:07:09Z" }
    ]))

    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll

    assert_equal 1, result[:logs].length
    assert_equal "Test message", result[:logs][0][:message]
  end

  test "poll determines server status as connected when connection success message found" do
    server_dir = File.join(mcp_cache_dir, "mcp-logs-context7")
    log_file = File.join(server_dir, "2025-12-09T10-00-00.jsonl")

    @mock_file_system.mkdir_p(mcp_cache_dir)
    @mock_file_system.mkdir_p(server_dir)
    @mock_file_system.write(log_file, to_jsonl([
      { "debug" => "Starting connection with timeout of 30000ms", "timestamp" => "2025-12-09T10:00:00Z" },
      { "debug" => "Successfully connected to server in 500ms", "timestamp" => "2025-12-09T10:00:01Z" }
    ]))

    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll

    assert_equal "connected", result[:server_statuses]["context7"][:status]
    assert_equal "2025-12-09T10:00:01Z", result[:server_statuses]["context7"][:connected_at]
  end

  test "poll determines server status as failed when connection failed message found" do
    server_dir = File.join(mcp_cache_dir, "mcp-logs-context7")
    log_file = File.join(server_dir, "2025-12-09T10-00-00.jsonl")

    @mock_file_system.mkdir_p(mcp_cache_dir)
    @mock_file_system.mkdir_p(server_dir)
    @mock_file_system.write(log_file, to_jsonl([
      { "debug" => "Starting connection with timeout of 30000ms", "timestamp" => "2025-12-09T10:00:00Z" },
      { "error" => "Connection failed: MCP error -32000: Connection closed", "timestamp" => "2025-12-09T10:00:01Z" }
    ]))

    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll

    assert_equal "failed", result[:server_statuses]["context7"][:status]
    assert_includes result[:server_statuses]["context7"][:error], "Connection failed"
  end

  test "poll determines server status as pending when no connection status found" do
    server_dir = File.join(mcp_cache_dir, "mcp-logs-context7")
    log_file = File.join(server_dir, "2025-12-09T10-00-00.jsonl")

    @mock_file_system.mkdir_p(mcp_cache_dir)
    @mock_file_system.mkdir_p(server_dir)
    @mock_file_system.write(log_file, to_jsonl([
      { "debug" => "Starting connection with timeout of 30000ms", "timestamp" => "2025-12-09T10:00:00Z" }
    ]))

    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll

    assert_equal "pending", result[:server_statuses]["context7"][:status]
  end

  test "poll handles invalid JSON in log files gracefully" do
    server_dir = File.join(mcp_cache_dir, "mcp-logs-context7")
    log_file = File.join(server_dir, "2025-12-09T10-00-00.jsonl")

    @mock_file_system.mkdir_p(mcp_cache_dir)
    @mock_file_system.mkdir_p(server_dir)
    @mock_file_system.write(log_file, "not valid json")

    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll

    # Should not raise, just return empty logs for this server
    assert_equal [], result[:logs]
  end

  test "poll handles partially invalid JSONL (valid lines still parsed)" do
    server_dir = File.join(mcp_cache_dir, "mcp-logs-context7")
    log_file = File.join(server_dir, "2025-12-09T10-00-00.jsonl")

    @mock_file_system.mkdir_p(mcp_cache_dir)
    @mock_file_system.mkdir_p(server_dir)
    # Mix of valid and invalid lines
    content = <<~JSONL
      {"debug":"Valid line 1","timestamp":"2025-12-09T10:00:00Z"}
      not valid json
      {"debug":"Valid line 2","timestamp":"2025-12-09T10:00:01Z"}
    JSONL
    @mock_file_system.write(log_file, content)

    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll

    # Should parse valid lines and skip invalid ones
    assert_equal 2, result[:logs].length
    assert_equal "Valid line 1", result[:logs][0][:message]
    assert_equal "Valid line 2", result[:logs][1][:message]
  end

  test "poll sorts logs by timestamp across multiple servers" do
    server1_dir = File.join(mcp_cache_dir, "mcp-logs-context7")
    server2_dir = File.join(mcp_cache_dir, "mcp-logs-playwright-custom")
    log1_file = File.join(server1_dir, "2025-12-09T10-00-00.jsonl")
    log2_file = File.join(server2_dir, "2025-12-09T10-00-00.jsonl")

    @mock_file_system.mkdir_p(mcp_cache_dir)
    @mock_file_system.mkdir_p(server1_dir)
    @mock_file_system.mkdir_p(server2_dir)
    @mock_file_system.write(log1_file, to_jsonl([
      { "debug" => "Server1 message", "timestamp" => "2025-12-09T10:00:02Z" }
    ]))
    @mock_file_system.write(log2_file, to_jsonl([
      { "debug" => "Server2 message", "timestamp" => "2025-12-09T10:00:01Z" }
    ]))

    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll

    # playwright-custom message should come first (earlier timestamp)
    assert_equal "playwright-custom", result[:logs][0][:server_name]
    assert_equal "context7", result[:logs][1][:server_name]
  end

  # === Real Claude CLI Format Tests ===
  # These tests validate against the ACTUAL format produced by Claude CLI.
  # If these tests fail, either Claude CLI changed its format or our parsing is wrong.
  # See GitHub issue #638 for context on why these tests are critical.

  test "parse_log_file handles real Claude CLI JSONL format" do
    # This is the ACTUAL format Claude CLI produces - copied from real log output
    real_log_content = <<~JSONL
      {"debug":"Starting connection with timeout of 30000ms","timestamp":"2025-12-13T00:07:09.976Z","sessionId":"abc123"}
      {"debug":"Successfully connected to undefined server in 997ms","timestamp":"2025-12-13T00:07:10.961Z","sessionId":"abc123"}
    JSONL

    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.send(:parse_log_file, real_log_content, "test-server")

    assert_equal 2, result.length
    assert_match(/Starting connection/, result[0][:message])
    assert_match(/Successfully connected/, result[1][:message])
    assert_equal "2025-12-13T00:07:09.976Z", result[0][:timestamp]
    assert_equal "2025-12-13T00:07:10.961Z", result[1][:timestamp]
  end

  test "poll correctly parses real Claude CLI log files with .jsonl extension" do
    # Test with the exact filename format Claude CLI uses: ISO timestamp with Z.jsonl
    server_dir = File.join(mcp_cache_dir, "mcp-logs-context7")
    log_file = File.join(server_dir, "2025-12-13T00-07-09-351Z.jsonl")

    @mock_file_system.mkdir_p(mcp_cache_dir)
    @mock_file_system.mkdir_p(server_dir)

    # Real Claude CLI JSONL content (one JSON object per line, NOT wrapped in array)
    real_content = <<~JSONL
      {"debug":"Starting connection with timeout of 30000ms","timestamp":"2025-12-13T00:07:09.976Z","sessionId":"abc123"}
      {"debug":"Successfully connected to undefined server in 997ms","timestamp":"2025-12-13T00:07:10.961Z","sessionId":"abc123"}
    JSONL
    @mock_file_system.write(log_file, real_content)

    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll

    assert_equal 2, result[:logs].length
    assert_equal "connected", result[:server_statuses]["context7"][:status]
  end

  test "poll detects connection failure from real Claude CLI error format" do
    server_dir = File.join(mcp_cache_dir, "mcp-logs-context7")
    log_file = File.join(server_dir, "2025-12-13T00-07-09-351Z.jsonl")

    @mock_file_system.mkdir_p(mcp_cache_dir)
    @mock_file_system.mkdir_p(server_dir)

    # Real Claude CLI error format
    error_content = <<~JSONL
      {"debug":"Starting connection with timeout of 30000ms","timestamp":"2025-12-13T00:07:09.976Z","sessionId":"abc123"}
      {"error":"Connection failed: MCP error -32000: Connection closed","timestamp":"2025-12-13T00:07:39.976Z","sessionId":"abc123"}
    JSONL
    @mock_file_system.write(log_file, error_content)

    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll

    assert_equal 2, result[:logs].length
    assert_equal "failed", result[:server_statuses]["context7"][:status]
    assert_includes result[:server_statuses]["context7"][:error], "Connection failed"
  end

  test "poll combines multiple error messages to show root cause" do
    server_dir = File.join(mcp_cache_dir, "mcp-logs-1password-ro")
    log_file = File.join(server_dir, "2025-12-13T00-07-09-351Z.jsonl")

    @mock_file_system.mkdir_p(mcp_cache_dir)
    @mock_file_system.mkdir_p(server_dir)

    # Simulate a sequence where root cause appears before the generic "Connection failed" message
    error_content = <<~JSONL
      {"debug":"Starting connection with timeout of 30000ms","timestamp":"2025-12-13T00:07:09.976Z","sessionId":"abc123"}
      {"error":"Authentication failed: API key not found in keychain","timestamp":"2025-12-13T00:07:10.000Z","sessionId":"abc123"}
      {"error":"Connection failed: MCP error -32000: Connection closed","timestamp":"2025-12-13T00:07:39.976Z","sessionId":"abc123"}
    JSONL
    @mock_file_system.write(log_file, error_content)

    # Need to configure session to use this server
    @session.update!(mcp_servers: [ "1password-ro" ])

    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll

    assert_equal 3, result[:logs].length
    assert_equal "failed", result[:server_statuses]["1password-ro"][:status]
    # Should include both the root cause and the connection failed message
    error_message = result[:server_statuses]["1password-ro"][:error]
    assert_includes error_message, "API key not found",
      "Error should include root cause message"
    assert_includes error_message, "Connection failed",
      "Error should include final connection failed message"
  end

  test "poll clears error messages after successful connection" do
    server_dir = File.join(mcp_cache_dir, "mcp-logs-context7")
    log_file = File.join(server_dir, "2025-12-13T00-07-09-351Z.jsonl")

    @mock_file_system.mkdir_p(mcp_cache_dir)
    @mock_file_system.mkdir_p(server_dir)

    # Simulate: initial error, then successful connection (errors should be cleared)
    log_content = <<~JSONL
      {"error":"Temporary authentication error","timestamp":"2025-12-13T00:07:09.976Z","sessionId":"abc123"}
      {"debug":"Successfully connected to server","timestamp":"2025-12-13T00:07:10.000Z","sessionId":"abc123"}
    JSONL
    @mock_file_system.write(log_file, log_content)

    service = McpLogPollerService.new(@session, file_system: @mock_file_system)
    result = service.poll

    # Should be connected (not failed) since the connection succeeded after the error
    assert_equal "connected", result[:server_statuses]["context7"][:status],
      "Should detect as connected when connection eventually succeeds"
    assert_nil result[:server_statuses]["context7"][:error],
      "Should not include earlier errors when connection eventually succeeds"
  end

  # === update_session_mcp_status Tests ===

  test "update_session_mcp_status updates custom_metadata with server statuses" do
    service = McpLogPollerService.new(@session, file_system: @mock_file_system)

    server_statuses = {
      "context7" => { status: "connected", connected_at: "2025-12-09T10:00:00Z" }
    }

    service.update_session_mcp_status(server_statuses)

    @session.reload
    assert_equal "connected", @session.custom_metadata.dig("mcp_servers_status", "context7", "status")
  end

  test "update_session_mcp_status sets should_fail_session when configured server fails" do
    service = McpLogPollerService.new(@session, file_system: @mock_file_system)

    server_statuses = {
      "context7" => { status: "failed", error: "Connection failed", failed_at: "2025-12-09T10:00:00Z" }
    }

    result = service.update_session_mcp_status(server_statuses)

    @session.reload
    assert result, "Should return true when a server fails"
    assert @session.custom_metadata["should_fail_session"]
    assert_equal "MCP server(s) failed to connect: context7", @session.custom_metadata["mcp_failure_reason"]
    assert_equal [ { "name" => "context7", "status" => "failed", "error" => "Connection failed" } ], @session.custom_metadata["mcp_failed_servers"]
  end

  test "update_session_mcp_status does not set should_fail_session for unconfigured servers" do
    # Use only playwright-custom as configured server
    @session.update!(mcp_servers: [ "playwright-custom" ])
    service = McpLogPollerService.new(@session, file_system: @mock_file_system)

    # context7 fails but is not configured
    server_statuses = {
      "context7" => { status: "failed", error: "Connection failed", failed_at: "2025-12-09T10:00:00Z" }
    }

    result = service.update_session_mcp_status(server_statuses)

    @session.reload
    assert_not result, "Should return false when only unconfigured servers fail"
    assert_nil @session.custom_metadata["should_fail_session"]
  end

  test "update_session_mcp_status only checks once (mcp_connection_checked flag)" do
    service = McpLogPollerService.new(@session, file_system: @mock_file_system)

    # First call - should set should_fail_session
    server_statuses = {
      "context7" => { status: "failed", error: "Connection failed", failed_at: "2025-12-09T10:00:00Z" }
    }
    service.update_session_mcp_status(server_statuses)

    @session.reload
    assert @session.custom_metadata["should_fail_session"]

    # Manually clear should_fail_session to simulate it being handled
    @session.update!(custom_metadata: @session.custom_metadata.merge("should_fail_session" => false))

    # Second call - should NOT set should_fail_session again because mcp_connection_checked is true
    service.update_session_mcp_status(server_statuses)

    @session.reload
    assert_not @session.custom_metadata["should_fail_session"], "Should not re-set should_fail_session after first check"
  end

  test "update_session_mcp_status returns false when no mcp_servers configured" do
    @session.update!(mcp_servers: nil)
    service = McpLogPollerService.new(@session, file_system: @mock_file_system)

    result = service.update_session_mcp_status({ "context7" => { status: "connected" } })

    assert_not result
  end

  # === Auto-Injected MCP Server Tracking Tests ===
  # When AIR prepare auto-injects MCP servers (e.g. agent-orchestrator for subagent
  # roots), the injected server names are stored in
  # custom_metadata["injected_mcp_servers"]. These servers must be tracked in
  # mcp_servers_status so the session UI can show their real connection state
  # instead of always rendering them as "pending".

  test "update_session_mcp_status writes status entries for auto-injected servers" do
    @session.update!(custom_metadata: { "injected_mcp_servers" => [ "agent-orchestrator" ] })
    service = McpLogPollerService.new(@session, file_system: @mock_file_system)

    server_statuses = {
      "agent-orchestrator" => { status: "connected", connected_at: "2026-04-27T20:53:11Z" }
    }

    service.update_session_mcp_status(server_statuses)

    @session.reload
    assert_equal "connected", @session.custom_metadata.dig("mcp_servers_status", "agent-orchestrator", "status"),
      "Auto-injected server status must be written to mcp_servers_status"
    assert_equal "2026-04-27T20:53:11Z", @session.custom_metadata.dig("mcp_servers_status", "agent-orchestrator", "connected_at")
  end

  test "update_session_mcp_status writes status entries for both configured and injected servers" do
    @session.update!(custom_metadata: { "injected_mcp_servers" => [ "agent-orchestrator" ] })
    service = McpLogPollerService.new(@session, file_system: @mock_file_system)

    server_statuses = {
      "context7" => { status: "connected", connected_at: "2026-04-27T20:53:00Z" },
      "agent-orchestrator" => { status: "connected", connected_at: "2026-04-27T20:53:11Z" }
    }

    service.update_session_mcp_status(server_statuses)

    @session.reload
    statuses = @session.custom_metadata["mcp_servers_status"]
    assert_equal "connected", statuses.dig("context7", "status")
    assert_equal "connected", statuses.dig("agent-orchestrator", "status")
  end

  test "update_session_mcp_status records failure for injected server but does not fail the session" do
    # Injected-server failures are still recorded so the UI can render them red,
    # but they do NOT trigger should_fail_session — that path is reserved for
    # servers the user explicitly asked for.
    @session.update!(custom_metadata: { "injected_mcp_servers" => [ "agent-orchestrator" ] })
    service = McpLogPollerService.new(@session, file_system: @mock_file_system)

    server_statuses = {
      "agent-orchestrator" => { status: "failed", error: "Connection refused", failed_at: "2026-04-27T20:53:11Z" }
    }

    result = service.update_session_mcp_status(server_statuses)

    @session.reload
    assert_not result, "An injected-server failure should not return true (which would fail the session)"
    assert_equal "failed", @session.custom_metadata.dig("mcp_servers_status", "agent-orchestrator", "status"),
      "Injected-server failure must still be recorded in mcp_servers_status"
    assert_equal "Connection refused", @session.custom_metadata.dig("mcp_servers_status", "agent-orchestrator", "error")
    assert_nil @session.custom_metadata["should_fail_session"]
  end

  test "update_session_mcp_status writes injected status when no configured servers" do
    @session.update!(
      mcp_servers: [],
      custom_metadata: { "injected_mcp_servers" => [ "agent-orchestrator" ] }
    )
    service = McpLogPollerService.new(@session, file_system: @mock_file_system)

    server_statuses = {
      "agent-orchestrator" => { status: "connected", connected_at: "2026-04-27T20:53:11Z" }
    }

    service.update_session_mcp_status(server_statuses)

    @session.reload
    assert_equal "connected", @session.custom_metadata.dig("mcp_servers_status", "agent-orchestrator", "status"),
      "Injected server status should be tracked even when no configured servers exist"
  end

  test "update_session_mcp_status escalates failure when a server is in both configured and injected lists" do
    # When a server name appears in BOTH mcp_servers and injected_mcp_servers, it
    # is configured-by-the-user and a failure should still escalate to should_fail_session.
    # The .uniq deduplication must not strip the configured semantics.
    @session.update!(
      mcp_servers: [ "context7" ],
      custom_metadata: { "injected_mcp_servers" => [ "context7" ] }
    )
    service = McpLogPollerService.new(@session, file_system: @mock_file_system)

    server_statuses = {
      "context7" => { status: "failed", error: "boom", failed_at: "2026-04-27T20:53:11Z" }
    }

    result = service.update_session_mcp_status(server_statuses)

    @session.reload
    assert result, "Failure of a configured server must escalate even if it also happens to be in injected list"
    assert_equal true, @session.custom_metadata["should_fail_session"]
  end

  # === Timestamp Filtering Tests (Issue #716) ===
  # These tests validate that stale MCP log entries from previous session runs
  # are filtered out when restarting a session.

  test "determine_server_status filters out log entries older than min_timestamp" do
    # Create service with min_timestamp set to after the failed connection
    min_timestamp = Time.parse("2025-12-09T10:00:02Z")
    service = McpLogPollerService.new(@session, file_system: @mock_file_system, min_timestamp: min_timestamp)

    # Logs contain a failure from BEFORE min_timestamp (should be filtered)
    # and a success AFTER min_timestamp (should be included)
    logs = [
      { server_name: "context7", timestamp: "2025-12-09T10:00:00Z", message: "Connection failed: timeout" },
      { server_name: "context7", timestamp: "2025-12-09T10:00:03Z", message: "Successfully connected to server" }
    ]

    result = service.send(:determine_server_status, logs)

    # Should detect as connected because the old failure is filtered out
    assert_equal "connected", result[:status]
    assert_equal "2025-12-09T10:00:03Z", result[:connected_at]
  end

  test "determine_server_status detects failure when failure timestamp is after min_timestamp" do
    # Create service with min_timestamp set to before the failed connection
    min_timestamp = Time.parse("2025-12-09T09:00:00Z")
    service = McpLogPollerService.new(@session, file_system: @mock_file_system, min_timestamp: min_timestamp)

    logs = [
      { server_name: "context7", timestamp: "2025-12-09T10:00:00Z", message: "Connection failed: timeout" }
    ]

    result = service.send(:determine_server_status, logs)

    # Should detect as failed because the failure is after min_timestamp
    assert_equal "failed", result[:status]
    assert_includes result[:error], "Connection failed"
  end

  test "determine_server_status processes all entries when min_timestamp is nil" do
    # Create service without min_timestamp (backward compatibility)
    service = McpLogPollerService.new(@session, file_system: @mock_file_system, min_timestamp: nil)

    # Logs contain a failure followed by success
    logs = [
      { server_name: "context7", timestamp: "2025-12-09T10:00:00Z", message: "Connection failed: timeout" }
    ]

    result = service.send(:determine_server_status, logs)

    # Should detect as failed (normal behavior without filtering)
    assert_equal "failed", result[:status]
  end

  test "determine_server_status handles entries without timestamps gracefully" do
    min_timestamp = Time.parse("2025-12-09T10:00:00Z")
    service = McpLogPollerService.new(@session, file_system: @mock_file_system, min_timestamp: min_timestamp)

    # Mix of entries with and without timestamps
    logs = [
      { server_name: "context7", timestamp: nil, message: "Connection failed: timeout" },
      { server_name: "context7", timestamp: "2025-12-09T10:00:03Z", message: "Successfully connected to server" }
    ]

    result = service.send(:determine_server_status, logs)

    # Entry without timestamp should still be processed (safer to include than exclude)
    # The subsequent success overrides the earlier failure (retry logic)
    assert_equal "connected", result[:status]
  end

  test "determine_server_status handles malformed timestamps gracefully" do
    min_timestamp = Time.parse("2025-12-09T10:00:00Z")
    service = McpLogPollerService.new(@session, file_system: @mock_file_system, min_timestamp: min_timestamp)

    logs = [
      { server_name: "context7", timestamp: "not-a-valid-timestamp", message: "Connection failed: timeout" }
    ]

    result = service.send(:determine_server_status, logs)

    # Malformed timestamp should not raise, entry should still be processed
    assert_equal "failed", result[:status]
  end

  test "determine_server_status treats transient failure followed by success as connected" do
    # This test validates that Claude Code's built-in retry logic is respected.
    # A transient npm or network error that fails initially but succeeds on retry
    # should result in a "connected" status, not "failed".
    service = McpLogPollerService.new(@session, file_system: @mock_file_system)

    # Simulate a real scenario: first connection fails due to npm cache issue,
    # then retry succeeds
    logs = [
      { server_name: "pulse-redirects-rw", timestamp: "2025-12-09T10:00:00Z", level: "error", message: "npm error code ENOTEMPTY" },
      { server_name: "pulse-redirects-rw", timestamp: "2025-12-09T10:00:01Z", message: "Connection failed after 796ms: MCP error -32000: Connection closed" },
      { server_name: "pulse-redirects-rw", timestamp: "2025-12-09T10:00:02Z", message: "Starting connection with timeout of 180000ms" },
      { server_name: "pulse-redirects-rw", timestamp: "2025-12-09T10:00:03Z", message: "Successfully connected to undefined server in 545ms" }
    ]

    result = service.send(:determine_server_status, logs)

    # Should detect as connected because the retry succeeded
    assert_equal "connected", result[:status]
    assert_equal "2025-12-09T10:00:03Z", result[:connected_at]
  end

  test "determine_server_status treats multiple failures without success as failed" do
    # Ensure that if all retries fail, the status is still "failed"
    service = McpLogPollerService.new(@session, file_system: @mock_file_system)

    logs = [
      { server_name: "pulse-redirects-rw", timestamp: "2025-12-09T10:00:00Z", level: "error", message: "npm error code ENOTEMPTY" },
      { server_name: "pulse-redirects-rw", timestamp: "2025-12-09T10:00:01Z", message: "Connection failed after 796ms: MCP error -32000: Connection closed" },
      { server_name: "pulse-redirects-rw", timestamp: "2025-12-09T10:00:02Z", message: "Starting connection with timeout of 180000ms" },
      { server_name: "pulse-redirects-rw", timestamp: "2025-12-09T10:00:03Z", message: "Connection failed after 500ms: timeout" }
    ]

    result = service.send(:determine_server_status, logs)

    # Should detect as failed because all attempts failed
    assert_equal "failed", result[:status]
    assert_includes result[:error], "Connection failed"
  end

  test "poll with min_timestamp filters stale logs from real scenario" do
    # This test simulates the real issue from GitHub #716:
    # - Session failed on 12/24 due to MCP connection failure
    # - User restarts on 12/28
    # - Old 12/24 logs should NOT cause immediate failure

    server_dir = File.join(mcp_cache_dir, "mcp-logs-context7")
    log_file = File.join(server_dir, "2025-12-24T10-00-00.jsonl")

    @mock_file_system.mkdir_p(mcp_cache_dir)
    @mock_file_system.mkdir_p(server_dir)

    # Old log with failure from 12/24
    old_content = to_jsonl([
      { "debug" => "Starting connection with timeout of 30000ms", "timestamp" => "2025-12-24T10:00:00Z" },
      { "error" => "Connection failed: MCP error -32000: Connection closed", "timestamp" => "2025-12-24T10:00:30Z" }
    ])
    @mock_file_system.write(log_file, old_content)

    # Session restarted on 12/28
    min_timestamp = Time.parse("2025-12-28T10:00:00Z")
    service = McpLogPollerService.new(@session, file_system: @mock_file_system, min_timestamp: min_timestamp)

    result = service.poll

    # All logs are from 12/24 which is before min_timestamp
    # So server status should be pending (no new connection info yet)
    assert_equal "pending", result[:server_statuses]["context7"][:status]
  end

  private

  def mcp_cache_dir
    File.join(PathSanitizer.cache_base, "-Users-admin-test-project")
  end

  # Convert an array of hashes to JSONL format (one JSON object per line)
  # This matches the actual format Claude CLI produces
  def to_jsonl(entries)
    entries.map { |entry| JSON.generate(entry) }.join("\n")
  end

  def setup_mcp_log_directory_with_logs
    server_dir = File.join(mcp_cache_dir, "mcp-logs-context7")
    log_file = File.join(server_dir, "2025-12-09T10-00-00.jsonl")

    @mock_file_system.mkdir_p(mcp_cache_dir)
    @mock_file_system.mkdir_p(server_dir)
    @mock_file_system.write(log_file, to_jsonl([
      { "debug" => "Starting connection with timeout of 30000ms", "timestamp" => "2025-12-09T10:00:00Z" },
      { "debug" => "Successfully connected to server in 500ms", "timestamp" => "2025-12-09T10:00:01Z" }
    ]))
  end
end
