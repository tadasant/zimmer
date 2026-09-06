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
# The result strings below are the adapter's own renderings, copied from
# `proxy-modes.ts` / `direct-tools.ts` and from a real Pi session's JSONL
# (production session 15578). Several of them are the near-misses that separate a
# real connection from a cache read, which is where this detector's only
# dangerous failure mode lives: a false `connected`.
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

  def tool_result(text:, timestamp:, call_id: "toolu_1", is_error: false)
    {
      "type" => "message",
      "timestamp" => timestamp,
      "message" => {
        "role" => "toolResult",
        "toolCallId" => call_id,
        "isError" => is_error,
        "content" => [ { "type" => "text", "text" => text } ]
      }
    }
  end

  # A call and the result it produced — the only shape that is ever evidence.
  def exchange(name:, result:, arguments: {}, at: "2026-09-06T14:54:29Z", id: "toolu_1", is_error: false)
    [
      tool_call(name: name, timestamp: at, id: id, arguments: arguments),
      tool_result(text: result, timestamp: at, call_id: id, is_error: is_error)
    ]
  end

  def statuses_for(*entries, min_timestamp: nil)
    detector(min_timestamp: min_timestamp)
      .poll(transcript_content: transcript(*entries))[:server_statuses]
  end

  # --- signal 1: the per-server namespace proxy tool -------------------------

  test "a mcp__<server> call that returned a tool result marks that server connected" do
    statuses = statuses_for(*exchange(name: "mcp__context7", result: "Available Libraries:\n- React"))

    assert_equal "connected", statuses["context7"][:status]
    assert_equal "2026-09-06T14:54:29Z", statuses["context7"][:connected_at]
  end

  test "the adapter's hyphen-to-underscore mapping is applied to the server name" do
    # `playwright-custom` is exposed as `mcp__playwright_custom`.
    statuses = statuses_for(*exchange(name: "mcp__playwright_custom", result: '{"isOpen": false}'))

    assert_equal "connected", statuses["playwright-custom"][:status]
  end

  test "the earliest exchange is what stamps connected_at" do
    statuses = statuses_for(
      *exchange(name: "mcp__context7", result: "ok", at: "2026-09-06T14:54:29Z"),
      *exchange(name: "mcp__context7", result: "ok", at: "2026-09-06T14:59:00Z", id: "toolu_2")
    )

    assert_equal "2026-09-06T14:54:29Z", statuses["context7"][:connected_at]
  end

  test "a server whose sanitized name is ambiguous is not reported" do
    # `a-b` and `a_b` both map to `mcp__a_b`; a status on the wrong one is worse
    # than none, so neither is claimed.
    @session.stubs(:all_mcp_servers).returns([ "a-b", "a_b" ])

    assert_empty statuses_for(*exchange(name: "mcp__a_b", result: "ok"))
  end

  # The registration of `mcp__<server>` proves nothing: the adapter's metadata
  # cache is host-global and valid for seven days, so the tool exists at spawn
  # because some OTHER session connected that server days ago.
  test "a mcp__<server> CALL with no result is not evidence of a connection" do
    assert_empty statuses_for(tool_call(name: "mcp__context7", timestamp: "2026-09-06T14:54:29Z"))
  end

  test "a mcp__<server> call the adapter refused does not mark the server connected" do
    # `executeCall` answers this without connecting anything.
    assert_empty statuses_for(
      *exchange(name: "mcp__notion", result: 'Server "notion" requires OAuth authentication.')
    )
  end

  test "a mcp__<server> call against a recently-failed server does not mark it connected" do
    assert_empty statuses_for(
      *exchange(name: "mcp__notion", result: 'Server "notion" not available (last failed 3s ago)')
    )
  end

  test "a tool result flagged isError is not evidence of a connection" do
    assert_empty statuses_for(*exchange(name: "mcp__context7", result: "boom", is_error: true))
  end

  # --- signal 2: the bare `mcp` proxy's connect ------------------------------

  test "a successful mcp connect marks the named server connected" do
    statuses = statuses_for(
      *exchange(
        name: "mcp", arguments: { "connect" => "context7" },
        result: "context7 (16 tools):\n\n- context7_resolve_library_id - Resolve a library"
      )
    )

    assert_equal "connected", statuses["context7"][:status]
  end

  test "an OAuth refusal leaves the server pending rather than failing the session" do
    # McpStatusPersisting escalates a CONFIGURED server's `failed` to a
    # session-level failure, one-shot and irreversible — and this message is the
    # adapter's answer to ANY 401, including a token that merely expired. So it
    # must never be reported as `failed`.
    statuses = statuses_for(
      *exchange(
        name: "mcp", arguments: { "connect" => "notion" },
        result: %(Server "notion" requires OAuth authentication. Run mcp({ action: "auth-start", server: "notion" }) to get a browser URL.)
      )
    )

    assert_empty statuses
  end

  test "no signal ever produces a status other than connected" do
    statuses = statuses_for(
      *exchange(name: "mcp__context7", result: "ok"),
      *exchange(name: "mcp", arguments: { "connect" => "notion" },
                result: 'Server "notion" requires OAuth authentication.', id: "toolu_2")
    )

    assert_equal [ "connected" ], statuses.values.map { |v| v[:status] }.uniq
  end

  test "a connect that merely found nothing leaves the server pending" do
    # The adapter connects lazily; 'disconnected' is the healthy resting state.
    assert_empty statuses_for(
      *exchange(name: "mcp", arguments: { "connect" => "context7" },
                result: %(Server "context7" is configured but not connected.))
    )
  end

  test "a server named in a connect the session does not have is ignored" do
    assert_empty statuses_for(
      *exchange(name: "mcp", arguments: { "connect" => "not-mine" }, result: "not-mine (3 tools):")
    )
  end

  # --- the cache-read near-misses, which look like success and are not --------

  test "mcp({server:}) is not a connect signal — it is a cache read that connects nothing" do
    # `executeList` renders a tool count for a server it never contacted.
    assert_empty statuses_for(
      *exchange(name: "mcp", arguments: { "server" => "notion" }, result: "notion (16 tools):")
    )
  end

  test "a cached listing that says the server is not connected does not green it" do
    assert_empty statuses_for(
      *exchange(
        name: "mcp", arguments: { "connect" => "notion" },
        result: %(notion (16 tools (lazy: tools from cache, not connected yet — mcp({ connect: "notion" }) to connect)):)
      )
    )
  end

  test "a cached listing that says the server needs auth does not green it" do
    assert_empty statuses_for(
      *exchange(
        name: "mcp", arguments: { "connect" => "notion" },
        result: %(notion (16 tools (needs auth — run mcp({ action: "auth-start", server: "notion" }))):)
      )
    )
  end

  # --- robustness ------------------------------------------------------------

  test "entries older than min_timestamp are ignored" do
    assert_empty statuses_for(
      *exchange(name: "mcp__context7", result: "ok", at: "2026-09-06T14:00:00Z"),
      min_timestamp: Time.zone.parse("2026-09-06T14:30:00Z")
    )
  end

  # Time.zone.parse RETURNS NIL for junk rather than raising, so a naive
  # comparison raised NoMethodError, which #poll's blanket rescue swallowed as
  # "no statuses" — for the whole transcript, on every later poll.
  test "an unparseable timestamp does not blank out the rest of the transcript" do
    entries = [
      { "type" => "message", "timestamp" => "not-a-timestamp",
        "message" => { "role" => "assistant", "content" => [] } },
      *exchange(name: "mcp__context7", result: "ok", at: "2026-09-06T14:54:29Z")
    ]

    statuses = statuses_for(*entries, min_timestamp: Time.zone.parse("2026-09-06T14:00:00Z"))

    assert_equal "connected", statuses["context7"][:status]
  end

  test "malformed lines are skipped rather than raising" do
    content = [
      "not json",
      *exchange(name: "mcp__context7", result: "ok").map { |e| JSON.generate(e) },
      "{"
    ].join("\n")

    statuses = detector.poll(transcript_content: content)[:server_statuses]

    assert_equal "connected", statuses["context7"][:status]
  end

  test "a blank transcript reports nothing" do
    assert_equal({ logs: [], server_statuses: {} }, detector.poll(transcript_content: nil))
    assert_equal({ logs: [], server_statuses: {} }, detector.poll(transcript_content: ""))
  end

  test "logs are always empty — Pi has no per-server MCP log lines" do
    assert_empty detector.poll(transcript_content: transcript(*exchange(name: "mcp__context7", result: "ok")))[:logs]
  end

  test "a session with no MCP servers reports nothing" do
    @session.stubs(:all_mcp_servers).returns([])

    assert_equal({ logs: [], server_statuses: {} }, detector.poll(transcript_content: "{}"))
  end

  test "RuntimeRegistry routes Pi's MCP status detection through this detector" do
    assert_equal PiMcpStatusDetector, RuntimeRegistry.for("pi").mcp_status_detector_class
  end
end
