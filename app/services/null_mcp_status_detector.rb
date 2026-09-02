# frozen_string_literal: true

# The MCP status detector for a runtime that exposes no per-server connection
# signal at all.
#
# Claude Code writes per-server log files (McpLogPollerService reads them) and
# Codex records `mcp__<server>__<tool>` calls in its rollout (CodexMcpStatusDetector
# mines those). Pi exposes neither: it writes no MCP log files, and the
# pi-mcp-adapter extension deliberately routes every server through a single
# `mcp` proxy tool, so a Pi transcript shows `mcp` being called and never names
# the server behind it. There is nothing per-server to detect.
#
# The honest answer is therefore "no status", and this class is how a runtime
# says that. It is NOT a nil bundle slot: TranscriptPollerService dereferences
# `mcp_status_detector_class` unconditionally in its constructor, so a nil there
# is a NoMethodError on every poll of every session on that runtime — before any
# MCP-specific guard can run. A null object keeps "every bundle slot a caller
# instantiates is non-nil" true, which is the property whose absence would
# otherwise have to be re-checked at each call site.
#
# `update_session_mcp_status` is inherited from McpStatusPersisting rather than
# stubbed, and that is deliberate: the persisting step seeds the `pending`
# placeholders that keep a configured server visible in `mcp_servers_status`
# instead of reading as "not configured". A Pi session's servers should still
# appear in the UI as configured-but-unknown; what is missing is only the
# transition to connected/failed, which no signal supports.
class NullMcpStatusDetector
  include McpStatusPersisting

  # Mirrors the McpLogPollerService / CodexMcpStatusDetector constructor so the
  # runtime bundle can build any of them the same way.
  #
  # @param session [Session]
  # @param file_system [FileSystemAdapter] accepted for contract symmetry; unused
  # @param min_timestamp [Time, nil] accepted for contract symmetry; unused
  def initialize(session, file_system: nil, min_timestamp: nil, logger: nil)
    @session = session
    @file_system = file_system
    @min_timestamp = min_timestamp
    # McpStatusPersisting logs through @logger, so it has to exist even though
    # this detector never produces a status transition of its own to log.
    @logger = logger || StructuredLogger.new({ session_id: session&.id, service: "NullMcpStatusDetector" })
  end

  # @return [Hash] always `{ logs: [], server_statuses: {} }` — no log lines to
  #   fold into the timeline, and no per-server evidence to report.
  def poll(transcript_content: nil)
    { logs: [], server_statuses: {} }
  end
end
