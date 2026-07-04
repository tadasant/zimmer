# frozen_string_literal: true

require "test_helper"

# Tests for CodexMcpStatusDetector — the Codex runtime's MCP status detector.
#
# Codex writes no per-server log files, so connection status is derived from the
# rollout transcript: an `mcp__<server>__<tool>` function_call proves the server
# connected. Failures are best-effort from the captured CLI stderr log.
class CodexMcpStatusDetectorTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @mock_file_system = MockFileSystemAdapter.new
    @working_dir = "/home/rails/clone"
    @session.update!(
      agent_runtime: "codex",
      metadata: { "working_directory" => @working_dir },
      mcp_servers: [ "appsignal-pulsemcp-prod", "playwright-custom" ]
    )
  end

  def detector(min_timestamp: nil)
    CodexMcpStatusDetector.new(@session, file_system: @mock_file_system, min_timestamp: min_timestamp)
  end

  # Build a rollout JSONL string from an array of {timestamp, type, payload} hashes.
  def rollout(*events)
    events.map { |e| JSON.generate(e) }.join("\n")
  end

  def function_call(name:, timestamp:, call_id: "call_1", arguments: "{}")
    {
      "timestamp" => timestamp,
      "type" => "response_item",
      "payload" => { "type" => "function_call", "name" => name, "arguments" => arguments, "call_id" => call_id }
    }
  end

  # An `event_msg` / `mcp_tool_call_end` event — codex's MCP-call-completion record.
  # `invocation.server` names the server verbatim (no sanitization).
  def mcp_tool_call_end(server:, tool:, timestamp:, is_error: false, call_id: "call_1")
    {
      "timestamp" => timestamp,
      "type" => "event_msg",
      "payload" => {
        "type" => "mcp_tool_call_end",
        "call_id" => call_id,
        "invocation" => { "server" => server, "tool" => tool, "arguments" => {} },
        "result" => { "Ok" => { "content" => [], "isError" => is_error } }
      }
    }
  end

  # A realistic Codex stderr line emitted by the rmcp client once per connected
  # MCP server (only when RUST_LOG enables rmcp=info). The server's self-declared
  # name is intentionally NOT the AO config key — only the COUNT of these lines is
  # usable, which is why detection is count-based and all-or-nothing.
  def rmcp_init_line(timestamp:, name: "some-mcp-server")
    %(#{timestamp}  INFO serve_inner: rmcp::service: Service initialized as client peer_info=Some(InitializeResult { server_info: Implementation { name: "#{name}", version: "1.0.0" } }))
  end

  # === connected detection ===

  test "poll returns empty server_statuses when transcript is nil" do
    result = detector.poll(transcript_content: nil)
    assert_equal [], result[:logs]
    assert_equal({}, result[:server_statuses])
  end

  test "poll returns empty server_statuses when transcript is blank" do
    assert_equal({}, detector.poll(transcript_content: "")[:server_statuses])
  end

  test "poll marks a server connected when its mcp__ tool is called in the rollout" do
    content = rollout(
      function_call(name: "mcp__appsignal-pulsemcp-prod__search_logs", timestamp: "2026-05-29T21:39:13.000Z")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_equal "connected", statuses["appsignal-pulsemcp-prod"][:status]
    assert_equal "2026-05-29T21:39:13.000Z", statuses["appsignal-pulsemcp-prod"][:connected_at]
    # A server with no tool call stays absent (rendered as pending by the view).
    assert_nil statuses["playwright-custom"]
  end

  test "poll marks multiple servers connected independently" do
    content = rollout(
      function_call(name: "mcp__appsignal-pulsemcp-prod__search_logs", timestamp: "2026-05-29T21:39:13.000Z", call_id: "c1"),
      function_call(name: "mcp__playwright-custom__browser_execute", timestamp: "2026-05-29T21:39:20.000Z", call_id: "c2")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_equal "connected", statuses["appsignal-pulsemcp-prod"][:status]
    assert_equal "connected", statuses["playwright-custom"][:status]
  end

  test "poll ignores non-mcp function calls (shell/local_shell_call)" do
    content = rollout(
      function_call(name: "shell", timestamp: "2026-05-29T21:39:13.000Z"),
      {
        "timestamp" => "2026-05-29T21:39:14.000Z",
        "type" => "response_item",
        "payload" => { "type" => "local_shell_call", "call_id" => "x", "action" => {} }
      }
    )

    assert_equal({}, detector.poll(transcript_content: content)[:server_statuses])
  end

  test "poll keeps the earliest connected_at when a server is called multiple times" do
    content = rollout(
      function_call(name: "mcp__playwright-custom__browser_execute", timestamp: "2026-05-29T21:40:00.000Z", call_id: "c2"),
      function_call(name: "mcp__playwright-custom__browser_screenshot", timestamp: "2026-05-29T21:39:30.000Z", call_id: "c1")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]
    assert_equal "2026-05-29T21:39:30.000Z", statuses["playwright-custom"][:connected_at]
  end

  test "poll sanitizes server names when matching the mcp tool prefix" do
    # An auto-injected server whose name contains characters Codex sanitizes to
    # "_" (e.g. a dot). all_mcp_servers includes injected servers verbatim, while
    # the rollout tool name carries the sanitized form.
    @session.update!(custom_metadata: { "injected_mcp_servers" => [ "agent.orchestrator" ] })
    content = rollout(
      function_call(name: "mcp__agent_orchestrator__start_session", timestamp: "2026-05-29T21:39:13.000Z")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]
    assert_equal "connected", statuses["agent.orchestrator"][:status]
  end

  # === connected detection via mcp_tool_call_end (raw server name) ===

  test "poll marks a server connected from an mcp_tool_call_end event" do
    content = rollout(
      mcp_tool_call_end(server: "appsignal-pulsemcp-prod", tool: "search_logs", timestamp: "2026-05-29T21:39:13.000Z")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_equal "connected", statuses["appsignal-pulsemcp-prod"][:status]
    assert_equal "2026-05-29T21:39:13.000Z", statuses["appsignal-pulsemcp-prod"][:connected_at]
  end

  test "poll marks a server connected from mcp_tool_call_end even when the tool errored" do
    # A tool-level error still proves the server was reachable and responded.
    content = rollout(
      mcp_tool_call_end(server: "playwright-custom", tool: "browser_execute", timestamp: "2026-05-29T21:39:13.000Z", is_error: true)
    )

    assert_equal "connected", detector.poll(transcript_content: content)[:server_statuses]["playwright-custom"][:status]
  end

  test "poll ignores mcp_tool_call_end for codex's built-in tools (server: codex)" do
    # Codex routes its own built-ins (list_mcp_resources, etc.) through the same
    # event under the pseudo-server "codex", which is not a trackable MCP server.
    content = rollout(
      mcp_tool_call_end(server: "codex", tool: "list_mcp_resources", timestamp: "2026-05-29T21:39:13.000Z")
    )

    assert_equal({}, detector.poll(transcript_content: content)[:server_statuses])
  end

  test "poll honors min_timestamp for mcp_tool_call_end events" do
    content = rollout(
      mcp_tool_call_end(server: "playwright-custom", tool: "browser_execute", timestamp: "2026-05-29T21:00:00.000Z")
    )

    statuses = detector(min_timestamp: Time.parse("2026-05-29T21:30:00.000Z"))
      .poll(transcript_content: content)[:server_statuses]

    assert_equal({}, statuses)
  end

  test "poll unifies mcp_tool_call_end and function_call evidence, keeping the earliest timestamp" do
    # The same call surfaces as both a function_call (sanitized name) and an
    # mcp_tool_call_end (raw name); the detector must collapse them to one server
    # and keep the earliest connected_at.
    content = rollout(
      function_call(name: "mcp__playwright-custom__browser_execute", timestamp: "2026-05-29T21:39:20.000Z", call_id: "c1"),
      mcp_tool_call_end(server: "playwright-custom", tool: "browser_execute", timestamp: "2026-05-29T21:39:13.000Z", call_id: "c1")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_equal 1, statuses.size
    assert_equal "connected", statuses["playwright-custom"][:status]
    assert_equal "2026-05-29T21:39:13.000Z", statuses["playwright-custom"][:connected_at]
  end

  test "poll matches mcp_tool_call_end to a trackable server by sanitized name" do
    # Defense in depth: codex normally names the server verbatim in
    # invocation.server, but if it ever emits a form that differs only by
    # sanitization, match_trackable_server falls back to a sanitize-equal match
    # (raw "agent.orchestrator" vs emitted "agent_orchestrator").
    @session.update!(custom_metadata: { "injected_mcp_servers" => [ "agent.orchestrator" ] })
    content = rollout(
      mcp_tool_call_end(server: "agent_orchestrator", tool: "start_session", timestamp: "2026-05-29T21:39:13.000Z")
    )

    assert_equal "connected", detector.poll(transcript_content: content)[:server_statuses]["agent.orchestrator"][:status]
  end

  test "poll collapses both shapes onto one server regardless of call_id correlation" do
    # Unification keys on the resolved server name, NOT call_id: two distinct
    # calls to the same server (different call_ids) still produce a single
    # connected entry stamped with the earliest timestamp.
    content = rollout(
      function_call(name: "mcp__playwright-custom__browser_screenshot", timestamp: "2026-05-29T21:39:25.000Z", call_id: "c1"),
      mcp_tool_call_end(server: "playwright-custom", tool: "browser_execute", timestamp: "2026-05-29T21:39:13.000Z", call_id: "c2")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_equal 1, statuses.size
    assert_equal "2026-05-29T21:39:13.000Z", statuses["playwright-custom"][:connected_at]
  end

  # === min_timestamp filtering (stale-run guard, issue #716 analogue) ===

  test "poll skips function calls older than min_timestamp" do
    content = rollout(
      function_call(name: "mcp__playwright-custom__browser_execute", timestamp: "2026-05-29T21:00:00.000Z")
    )

    statuses = detector(min_timestamp: Time.parse("2026-05-29T21:30:00.000Z"))
      .poll(transcript_content: content)[:server_statuses]

    assert_equal({}, statuses)
  end

  test "poll includes function calls at or after min_timestamp" do
    content = rollout(
      function_call(name: "mcp__playwright-custom__browser_execute", timestamp: "2026-05-29T22:00:00.000Z")
    )

    statuses = detector(min_timestamp: Time.parse("2026-05-29T21:30:00.000Z"))
      .poll(transcript_content: content)[:server_statuses]

    assert_equal "connected", statuses["playwright-custom"][:status]
  end

  # === failed detection (best-effort, from stderr) ===

  test "poll marks a server failed when stderr reports a startup failure" do
    stderr_path = File.join(@working_dir, "codex_stderr.log")
    @mock_file_system.write(stderr_path, "ERROR: MCP client for `appsignal-pulsemcp-prod` failed to start: spawn error\n")

    statuses = detector.poll(transcript_content: "")[:server_statuses]

    assert_equal "failed", statuses["appsignal-pulsemcp-prod"][:status]
    assert_includes statuses["appsignal-pulsemcp-prod"][:error], "failed to start"
  end

  test "a successful tool call takes precedence over a stderr failure for the same server" do
    stderr_path = File.join(@working_dir, "codex_stderr.log")
    @mock_file_system.write(stderr_path, "ERROR: MCP client for `playwright-custom` failed to start\n")
    content = rollout(
      function_call(name: "mcp__playwright-custom__browser_execute", timestamp: "2026-05-29T21:39:13.000Z")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]
    assert_equal "connected", statuses["playwright-custom"][:status]
  end

  test "poll ignores stderr failures for servers not in the session" do
    stderr_path = File.join(@working_dir, "codex_stderr.log")
    @mock_file_system.write(stderr_path, "ERROR: MCP client for `some-other-server` failed to start\n")

    assert_equal({}, detector.poll(transcript_content: "")[:server_statuses])
  end

  test "poll does not mark servers failed from benign stderr lines (no false-positive escalation)" do
    # A configured-server failure escalates to a session-level failure (and a
    # retry), so the failure patterns must NOT fire on ordinary, non-startup-failure
    # output: progress logs, a tool's own runtime error, or a line that merely
    # contains the word "failed" without the MCP-startup shape.
    stderr_path = File.join(@working_dir, "codex_stderr.log")
    benign = <<~STDERR
      INFO: starting MCP server `playwright-custom`
      DEBUG: appsignal-pulsemcp-prod connected, 12 tools available
      WARN: tool call failed: navigation timed out for playwright-custom
      ERROR: request to https://example.com failed with status 500
      INFO: playwright-custom: screenshot captured
    STDERR
    @mock_file_system.write(stderr_path, benign)

    assert_equal({}, detector.poll(transcript_content: "")[:server_statuses])
  end

  test "poll matches the exact raw server name over a sanitized collision" do
    # Two trackable servers whose names sanitize to the same string ("a_b") must
    # bind a tool call to the exact (raw) match, not the other server. Use injected
    # servers (not catalog-validated) so arbitrary colliding names are allowed.
    @session.update!(mcp_servers: [], custom_metadata: { "injected_mcp_servers" => [ "a-b", "a_b" ] })
    content = rollout(
      function_call(name: "mcp__a_b__do_thing", timestamp: "2026-05-29T21:39:13.000Z")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_equal "connected", statuses["a_b"][:status]
    assert_nil statuses["a-b"]
  end

  test "poll converges connected_at to a real timestamp when an earlier call lacked one" do
    content = rollout(
      function_call(name: "mcp__playwright-custom__browser_execute", timestamp: nil, call_id: "c1"),
      function_call(name: "mcp__playwright-custom__browser_screenshot", timestamp: "2026-05-29T21:39:30.000Z", call_id: "c2")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]
    assert_equal "2026-05-29T21:39:30.000Z", statuses["playwright-custom"][:connected_at]
  end

  # === startup detection (count-based: connected-but-never-called) ===

  test "poll marks all servers connected when stderr has one init line per expected server" do
    stderr_path = File.join(@working_dir, "codex_stderr.log")
    @mock_file_system.write(stderr_path, [
      rmcp_init_line(timestamp: "2026-05-29T21:39:10.000Z"),
      rmcp_init_line(timestamp: "2026-05-29T21:39:12.000Z")
    ].join("\n") + "\n")

    statuses = detector.poll(transcript_content: nil)[:server_statuses]

    assert_equal "connected", statuses["appsignal-pulsemcp-prod"][:status]
    assert_equal "connected", statuses["playwright-custom"][:status]
    # connected_at is approximated with the latest init line — every expected
    # server has finished its handshake by then.
    assert_equal "2026-05-29T21:39:12.000Z", statuses["appsignal-pulsemcp-prod"][:connected_at]
    assert_equal "2026-05-29T21:39:12.000Z", statuses["playwright-custom"][:connected_at]
  end

  test "poll leaves servers gray when there are fewer init lines than expected servers" do
    # One of the two configured servers failed to start (so emitted no init line).
    # The count stays below the expected total, so nothing is greened — an honest
    # gray rather than a false green.
    stderr_path = File.join(@working_dir, "codex_stderr.log")
    @mock_file_system.write(stderr_path, rmcp_init_line(timestamp: "2026-05-29T21:39:10.000Z") + "\n")

    assert_equal({}, detector.poll(transcript_content: nil)[:server_statuses])
  end

  test "tool-call connected_at takes precedence over the count-based timestamp" do
    stderr_path = File.join(@working_dir, "codex_stderr.log")
    @mock_file_system.write(stderr_path, [
      rmcp_init_line(timestamp: "2026-05-29T21:39:10.000Z"),
      rmcp_init_line(timestamp: "2026-05-29T21:39:12.000Z")
    ].join("\n") + "\n")
    content = rollout(
      function_call(name: "mcp__appsignal-pulsemcp-prod__search_logs", timestamp: "2026-05-29T21:39:11.000Z")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    # The called server keeps its precise tool-call timestamp...
    assert_equal "2026-05-29T21:39:11.000Z", statuses["appsignal-pulsemcp-prod"][:connected_at]
    # ...while the never-called server is greened from the count.
    assert_equal "connected", statuses["playwright-custom"][:status]
    assert_equal "2026-05-29T21:39:12.000Z", statuses["playwright-custom"][:connected_at]
  end

  test "a stderr startup failure takes precedence over count-based connection" do
    # Precedence check: even if the init-line count reaches threshold, an explicit
    # startup-failure line keeps that server red (failure wins over the fallback).
    stderr_path = File.join(@working_dir, "codex_stderr.log")
    @mock_file_system.write(stderr_path, [
      "ERROR: MCP client for `appsignal-pulsemcp-prod` failed to start",
      rmcp_init_line(timestamp: "2026-05-29T21:39:10.000Z"),
      rmcp_init_line(timestamp: "2026-05-29T21:39:12.000Z")
    ].join("\n") + "\n")

    statuses = detector.poll(transcript_content: nil)[:server_statuses]

    assert_equal "failed", statuses["appsignal-pulsemcp-prod"][:status]
    assert_equal "connected", statuses["playwright-custom"][:status]
  end

  test "count-based detection ignores init lines older than min_timestamp" do
    # Stale init lines from a prior run of the same session must not green the pill
    # (issue #716 analogue).
    stderr_path = File.join(@working_dir, "codex_stderr.log")
    @mock_file_system.write(stderr_path, [
      rmcp_init_line(timestamp: "2026-05-29T21:00:00.000Z"),
      rmcp_init_line(timestamp: "2026-05-29T21:00:01.000Z")
    ].join("\n") + "\n")

    statuses = detector(min_timestamp: Time.parse("2026-05-29T21:30:00.000Z"))
      .poll(transcript_content: nil)[:server_statuses]

    assert_equal({}, statuses)
  end

  test "count-based detection requires the rmcp init marker, not other rmcp/launcher lines" do
    stderr_path = File.join(@working_dir, "codex_stderr.log")
    @mock_file_system.write(stderr_path, [
      "2026-05-29T21:39:10.000Z  INFO serve_inner: rmcp::service: received notification notification=ToolListChangedNotification",
      "2026-05-29T21:39:11.000Z  INFO codex_rmcp_client::stdio_server_launcher: MCP server stderr (npx): Starting default (STDIO) server..."
    ].join("\n") + "\n")

    assert_equal({}, detector.poll(transcript_content: nil)[:server_statuses])
  end

  # === persistence (shared McpStatusPersisting module) ===

  test "poll + update_session_mcp_status writes connected status into custom_metadata" do
    content = rollout(
      function_call(name: "mcp__appsignal-pulsemcp-prod__search_logs", timestamp: "2026-05-29T21:39:13.000Z")
    )

    d = detector
    result = d.poll(transcript_content: content)
    d.update_session_mcp_status(result[:server_statuses])

    @session.reload
    status = @session.custom_metadata.dig("mcp_servers_status", "appsignal-pulsemcp-prod")
    assert_equal "connected", status["status"]
    assert_equal "2026-05-29T21:39:13.000Z", status["connected_at"]
  end

  test "update_session_mcp_status escalates a configured server failure to the session" do
    stderr_path = File.join(@working_dir, "codex_stderr.log")
    @mock_file_system.write(stderr_path, "ERROR: MCP client for `appsignal-pulsemcp-prod` failed to start\n")

    d = detector
    result = d.poll(transcript_content: "")
    any_failed = d.update_session_mcp_status(result[:server_statuses])

    assert any_failed
    @session.reload
    assert @session.custom_metadata["should_fail_session"]
  end

  test "update_session_mcp_status records an injected server failure without escalating the session" do
    # An auto-injected server is not one the user asked for, so its failure is
    # rendered red in the UI but must NOT mark the session for failure/retry.
    @session.update!(mcp_servers: [], custom_metadata: { "injected_mcp_servers" => [ "playwright-custom" ] })
    stderr_path = File.join(@working_dir, "codex_stderr.log")
    @mock_file_system.write(stderr_path, "ERROR: MCP client for `playwright-custom` failed to start\n")

    d = detector
    result = d.poll(transcript_content: "")
    any_failed = d.update_session_mcp_status(result[:server_statuses])

    refute any_failed
    @session.reload
    assert_equal "failed", @session.custom_metadata.dig("mcp_servers_status", "playwright-custom", "status")
    assert_nil @session.custom_metadata["should_fail_session"]
  end
end
