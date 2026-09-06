# frozen_string_literal: true

require "test_helper"
require "mocha/minitest"

# Tests for PiMcpStatusDetector — the Pi runtime's MCP status detector.
#
# Pi writes no per-server MCP log files, so connection status is derived from the
# session JSONL. The pinned pi-mcp-adapter names the server in two places a
# transcript records structurally: the per-server namespace-proxy tool
# `mcp__<server>`, and the `connect` argument of the bare `mcp` proxy.
#
# The fixtures below are shaped from a real Pi session's JSONL (production
# session 15578), including the exact adapter strings for a successful connect
# and for the OAuth refusal.
class PiMcpStatusDetectorTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:running)
    @session.update!(
      agent_runtime: "pi",
      mcp_servers: [ "context7", "playwright-custom", "notion" ]
    )
  end

  def detector(min_timestamp: nil)
    PiMcpStatusDetector.new(@session, file_system: MockFileSystemAdapter.new, min_timestamp: min_timestamp)
  end

  # Pi's session JSONL: one JSON object per line, `type: "message"`.
  def transcript(*entries)
    entries.map { |e| JSON.generate(e) }.join("\n")
  end

  def tool_call(name:, timestamp:, id: "toolu_1", arguments: {})
    {
      "type" => "message",
      "timestamp" => timestamp,
      "message" => {
        "role" => "assistant",
        "content" => [ { "type" => "toolCall", "id" => id, "name" => name, "arguments" => arguments } ]
      }
    }
  end

  def tool_result(text:, timestamp:, call_id: "toolu_1")
    {
      "type" => "message",
      "timestamp" => timestamp,
      "message" => {
        "role" => "toolResult",
        "toolCallId" => call_id,
        "content" => [ { "type" => "text", "text" => text } ]
      }
    }
  end

  # --- signal 1: the per-server namespace proxy tool -------------------------

  test "a mcp__<server> namespace-proxy call marks that server connected" do
    content = transcript(tool_call(name: "mcp__context7", timestamp: "2026-09-06T14:54:29Z"))

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_equal "connected", statuses["context7"][:status]
    assert_equal "2026-09-06T14:54:29Z", statuses["context7"][:connected_at]
  end

  test "the adapter's hyphen-to-underscore mapping is applied to the server name" do
    # `playwright-custom` is exposed as `mcp__playwright_custom`.
    content = transcript(tool_call(name: "mcp__playwright_custom", timestamp: "2026-09-06T14:54:30Z"))

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_equal "connected", statuses["playwright-custom"][:status]
  end

  test "the earliest call is what stamps connected_at" do
    content = transcript(
      tool_call(name: "mcp__context7", timestamp: "2026-09-06T14:54:29Z"),
      tool_call(name: "mcp__context7", timestamp: "2026-09-06T14:59:00Z", id: "toolu_2")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_equal "2026-09-06T14:54:29Z", statuses["context7"][:connected_at]
  end

  test "a server whose sanitized name is ambiguous is not reported" do
    # `a-b` and `a_b` both map to `mcp__a_b`; a status on the wrong one is worse
    # than none, so neither is claimed.
    @session.stubs(:all_mcp_servers).returns([ "a-b", "a_b" ])
    content = transcript(tool_call(name: "mcp__a_b", timestamp: "2026-09-06T14:54:29Z"))

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_empty statuses
  end

  # --- signal 2: the bare `mcp` proxy's connect ------------------------------

  test "a successful mcp connect marks the named server connected" do
    content = transcript(
      tool_call(name: "mcp", timestamp: "2026-09-06T14:54:10Z", arguments: { "connect" => "context7" }),
      tool_result(text: "context7 (16 tools):\n\n- context7_resolve_library_id - Resolve a library", timestamp: "2026-09-06T14:54:12Z")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_equal "connected", statuses["context7"][:status]
  end

  test "an OAuth refusal marks the named server failed with the adapter's message" do
    content = transcript(
      tool_call(name: "mcp", timestamp: "2026-09-06T14:54:10Z", arguments: { "connect" => "notion" }),
      tool_result(
        text: %(Server "notion" requires OAuth authentication. Run mcp({ action: "auth-start", server: "notion" }) to get a browser URL.),
        timestamp: "2026-09-06T14:54:11Z"
      )
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_equal "failed", statuses["notion"][:status]
    assert_match(/requires OAuth authentication/, statuses["notion"][:error])
  end

  test "a connect that merely found nothing leaves the server pending rather than failed" do
    # The adapter connects lazily; 'disconnected' is the healthy resting state,
    # and escalating it would fail the session over a server nobody needed.
    content = transcript(
      tool_call(name: "mcp", timestamp: "2026-09-06T14:54:10Z", arguments: { "connect" => "context7" }),
      tool_result(text: %(Server "context7" is configured but not connected.), timestamp: "2026-09-06T14:54:11Z")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_empty statuses
  end

  test "connected is never downgraded to failed by a later refusal" do
    content = transcript(
      tool_call(name: "mcp__notion", timestamp: "2026-09-06T14:54:00Z"),
      tool_call(name: "mcp", timestamp: "2026-09-06T14:55:00Z", id: "toolu_2", arguments: { "connect" => "notion" }),
      tool_result(text: %(Server "notion" requires OAuth authentication.), timestamp: "2026-09-06T14:55:01Z", call_id: "toolu_2")
    )

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_equal "connected", statuses["notion"][:status]
  end

  test "a server named in a connect the session does not have is ignored" do
    content = transcript(
      tool_call(name: "mcp", timestamp: "2026-09-06T14:54:10Z", arguments: { "connect" => "not-mine" }),
      tool_result(text: "not-mine (3 tools):", timestamp: "2026-09-06T14:54:11Z")
    )

    assert_empty detector.poll(transcript_content: content)[:server_statuses]
  end

  # --- robustness ------------------------------------------------------------

  test "entries older than min_timestamp are ignored" do
    content = transcript(tool_call(name: "mcp__context7", timestamp: "2026-09-06T14:00:00Z"))

    statuses = detector(min_timestamp: Time.zone.parse("2026-09-06T14:30:00Z"))
      .poll(transcript_content: content)[:server_statuses]

    assert_empty statuses
  end

  test "malformed lines are skipped rather than raising" do
    content = [ "not json", JSON.generate(tool_call(name: "mcp__context7", timestamp: "2026-09-06T14:54:29Z")), "{" ].join("\n")

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_equal "connected", statuses["context7"][:status]
  end

  test "a blank transcript reports nothing" do
    assert_equal({ logs: [], server_statuses: {} }, detector.poll(transcript_content: nil))
    assert_equal({ logs: [], server_statuses: {} }, detector.poll(transcript_content: ""))
  end

  test "logs are always empty — Pi has no per-server MCP log lines" do
    content = transcript(tool_call(name: "mcp__context7", timestamp: "2026-09-06T14:54:29Z"))

    assert_empty detector.poll(transcript_content: content)[:logs]
  end

  test "a session with no MCP servers reports nothing" do
    @session.update!(mcp_servers: [])
    @session.stubs(:all_mcp_servers).returns([])

    assert_equal({ logs: [], server_statuses: {} }, detector.poll(transcript_content: "{}"))
  end
end
