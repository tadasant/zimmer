# Detects per-MCP-server connection status for Codex runtime sessions.
#
# Codex does NOT write per-server log files the way Claude Code does (so the
# file-based McpLogPollerService produces nothing for Codex — that is the root
# cause of #3991, where Codex status pills stay gray forever). Instead, the
# authoritative "connected" signal lives in the rollout transcript itself:
#
#   Codex records an MCP tool call in two ways, either of which proves the server
#   is up and usable:
#     * `event_msg` / `mcp_tool_call_end` — emitted when an MCP call completes;
#       `payload.invocation.server` names the server VERBATIM (no sanitization).
#       This is the precise, collision-free signal.
#     * `response_item` / `function_call` — the model issuing the call. Codex
#       exposes a server's tools only after it connects, and names every MCP tool
#       `mcp__<server>__<tool>` (codex-rs `MCP_TOOL_NAME_DELIMITER = "__"`, then
#       sanitized so any char outside [a-zA-Z0-9_-] becomes "_"; hyphens are
#       preserved). A name beginning with `mcp__<server>__` is proof of connection.
#
# This detector mirrors McpLogPollerService's interface (`poll(transcript_content:)`
# -> { logs:, server_statuses: } and the shared `update_session_mcp_status`) so
# TranscriptPollerService can drive either runtime's detector identically.
#
# Connected detection (authoritative): scan the rollout for both MCP-call shapes
# above. Both are scanned because codex lazy-loads MCP tools via `tool_search`;
# relying on a single shape risks missing a connection depending on how the call
# was routed.
#
# Startup detection (count-based): a server that connected but was never called
# leaves NO evidence in the rollout — Codex writes no `mcp_servers` into
# `session_meta`, no tool list into `turn_context`, and no tool definitions
# anywhere (verified against real rollouts). The ONLY runtime signal that such a
# server connected is the rmcp `Service initialized as client` line Codex emits
# on stderr, once per connected MCP server, when `RUST_LOG` enables `rmcp=info`
# (CodexRuntimeAdapter sets this on spawn). That line reports the server's
# self-declared name, not the AO config key, so it cannot be mapped to a specific
# server — only counted. When the number of fresh init lines reaches the total
# number of servers Codex is expected to connect to, every expected server
# connected, so all trackable servers are marked connected. This never
# false-greens a broken server: a server that fails to start emits no init line,
# so the count stays below the expected total and the threshold is not met. See
# the #3991 follow-up.
#
# Failed detection (best-effort): Codex surfaces MCP startup failures on the CLI's
# stderr, which AO captures to `<working_directory>/codex_stderr.log`. We scan it
# for lines naming a server that failed to start. This is conservative — a server
# that produced a successful tool call is never marked failed — because a
# configured-server failure escalates to a session-level failure.
class CodexMcpStatusDetector
  include DatabaseRetry
  include McpStatusPersisting

  # codex-rs joins the server name and tool name with this delimiter to form the
  # tool name the model sees. Mirrored from `MCP_TOOL_NAME_DELIMITER`.
  MCP_TOOL_NAME_DELIMITER = "__"
  MCP_TOOL_NAME_PREFIX = "mcp#{MCP_TOOL_NAME_DELIMITER}"

  # The rmcp client logs this exactly once per MCP server it finishes the
  # initialize handshake with. Counting these (after the stale-run cutoff) is the
  # only connected-but-never-called signal Codex exposes; see the class comment.
  RMCP_INIT_MARKER = "rmcp::service: Service initialized as client"

  # Conservative patterns for MCP startup failures on Codex stderr. Each captures
  # the offending server name so we can map it back to a trackable server. Kept
  # deliberately narrow to avoid false-positive failure escalation; verified and
  # tuned against real staging stderr.
  STDERR_FAILURE_PATTERNS = [
    /MCP client for (?:server )?[`'"]?(?<server>[\w.\/-]+)[`'"]?\s+failed/i,
    /failed to (?:start|initialize|spawn|connect(?: to)?)\s+MCP server[`'":\s]+(?<server>[\w.\/-]+)/i
  ].freeze

  attr_reader :session, :file_system, :min_timestamp

  # @param session [Session] The session to detect MCP status for
  # @param file_system [Object] File system adapter (for testing)
  # @param min_timestamp [Time, nil] Optional minimum timestamp. Rollout events
  #   older than this are ignored so a restarted session doesn't read connection
  #   state from a previous run (see issue #716 for the Claude analogue).
  def initialize(session, file_system: nil, min_timestamp: nil)
    @session = session
    @file_system = file_system || RealFileSystemAdapter.new
    @min_timestamp = min_timestamp
    @logger = StructuredLogger.new({ session_id: session.id, service: "CodexMcpStatusDetector" })
  end

  # Detect MCP server statuses from the Codex rollout (and stderr).
  #
  # @param transcript_content [String, nil] the already-read rollout JSONL. When
  #   nil/blank there is nothing to derive connection state from yet.
  # @return [Hash] { logs: Array<Hash>, server_statuses: Hash<String, Hash> }
  #   - logs: always empty — Codex has no per-server log lines to fold into the
  #     timeline; status pills are driven purely by server_statuses.
  #   - server_statuses: server_name => { status:, error:, connected_at:, failed_at: }
  def poll(transcript_content: nil)
    trackable_servers = @session.all_mcp_servers
    return { logs: [], server_statuses: {} } if trackable_servers.empty?

    connected = connected_servers(transcript_content, trackable_servers)
    failed = failed_servers(trackable_servers, connected.keys)
    started = startup_connected_servers(trackable_servers, connected.keys, failed.keys)

    # Precedence: tool-call `connected` (precise connected_at) and explicit
    # `failed` both override the count-based `started` fallback, which only fills
    # in servers with no other evidence.
    { logs: [], server_statuses: started.merge(connected).merge(failed) }
  rescue => e
    @logger.error("Error detecting Codex MCP status", error: e.message)
    { logs: [], server_statuses: {} }
  end

  private

  # Map each trackable server that has at least one MCP tool call in the rollout
  # to a "connected" status, stamped with the earliest such call's timestamp.
  def connected_servers(transcript_content, trackable_servers)
    return {} if transcript_content.blank?

    # Precompute both the raw `mcp__<name>__` and sanitized `mcp__<sanitize(name)>__`
    # prefix for every trackable server. Codex sanitizes the tool name it exposes, so
    # the sanitized prefix is what normally matches; the raw prefix is preferred when
    # present so two servers whose names sanitize to the same string don't collide.
    prefixes = trackable_servers.map do |name|
      {
        server: name,
        raw: "#{MCP_TOOL_NAME_PREFIX}#{name}#{MCP_TOOL_NAME_DELIMITER}",
        sanitized: "#{MCP_TOOL_NAME_PREFIX}#{sanitize(name)}#{MCP_TOOL_NAME_DELIMITER}"
      }
    end

    statuses = {}
    mcp_connection_events(transcript_content).each do |(raw_server, tool_name, timestamp)|
      # mcp_tool_call_end names the server verbatim (raw_server); a function_call
      # name carries the sanitized server inside an `mcp__<server>__` prefix.
      server_name = raw_server ? match_trackable_server(raw_server, trackable_servers) : match_connected_server(tool_name, prefixes)
      next unless server_name

      # Keep the earliest connection timestamp per server.
      existing = statuses[server_name]
      if existing.nil? || earlier?(timestamp, existing[:connected_at])
        statuses[server_name] = { status: "connected", connected_at: timestamp }
      end
    end

    statuses
  end

  # Count-based fallback for servers that connected but were never called and so
  # left no rollout evidence. Returns a "connected" status for every trackable
  # server lacking other evidence ONLY when the number of fresh rmcp init lines
  # reaches the total number of servers Codex is expected to connect to (so we
  # know they all connected — see the class comment). Returns {} otherwise, which
  # leaves those servers gray rather than risking a false green.
  def startup_connected_servers(trackable_servers, connected_names, failed_names)
    expected = expected_connection_count
    return {} if expected <= 0

    init_timestamps = fresh_rmcp_init_timestamps
    return {} if init_timestamps.size < expected

    # Approximate connected_at with the latest fresh init line: every expected
    # server has connected by then. Tool-call evidence supplies a precise time
    # where available and overrides this in `poll`.
    connected_at = init_timestamps.max

    trackable_servers.each_with_object({}) do |name, statuses|
      next if connected_names.include?(name) || failed_names.include?(name)

      statuses[name] = { status: "connected", connected_at: connected_at }
    end
  end

  # Total number of MCP servers Codex is expected to connect to for this session.
  # Session#all_mcp_servers includes directly selected, plugin-bundled, and
  # auto-injected servers. The init-line count is
  # compared against this FULL set (not just the displayed/trackable set) so a
  # plugin- or injection-contributed server's init line can never push the count
  # to threshold while a configured server silently failed to start.
  def expected_connection_count
    @session.all_mcp_servers.size
  end

  # Timestamps of the rmcp "Service initialized as client" lines in Codex stderr
  # that pass the stale-run cutoff. One line is emitted per connected server.
  def fresh_rmcp_init_timestamps
    log_path = stderr_log_path
    return [] unless log_path && @file_system.exists?(log_path)

    content = @file_system.read(log_path)
    return [] if content.blank?

    content.each_line.filter_map do |line|
      next unless line.include?(RMCP_INIT_MARKER)

      timestamp = line[/\A(\S+)/, 1]
      next if stale?(timestamp)

      timestamp
    end
  rescue => e
    @logger.warn("Error reading Codex stderr for MCP init lines", error: e.message)
    []
  end

  # Resolve an `mcp__<server>__<tool>` tool name to a trackable server, preferring an
  # exact raw-name prefix over the sanitized-name prefix so a sanitization collision
  # (two servers whose names sanitize to the same string) binds to the exact match.
  def match_connected_server(name, prefixes)
    prefixes.find { |p| name.start_with?(p[:raw]) }&.fetch(:server) ||
      prefixes.find { |p| name.start_with?(p[:sanitized]) }&.fetch(:server)
  end

  # True when `candidate` is a strictly earlier timestamp than `current`. A nil
  # candidate never wins; a nil `current` is always replaced by a non-nil candidate,
  # so connected_at converges to a real timestamp even if the first matching call
  # lacked one. Parses to Time rather than comparing ISO8601 strings lexicographically.
  def earlier?(candidate, current)
    return false if candidate.nil?
    return true if current.nil?

    Time.parse(candidate) < Time.parse(current)
  rescue ArgumentError
    false
  end

  # Extract connection evidence as [raw_server, tool_name, timestamp] for every MCP
  # tool interaction in the rollout, honoring min_timestamp so stale events from a
  # prior run are skipped. Two authoritative shapes, both proof a server connected:
  #
  #   1. event_msg / mcp_tool_call_end — codex emits this when an MCP tool call
  #      completes. `payload.invocation.server` names the server VERBATIM (no
  #      sanitization), so it is the precise, collision-free signal. Yielded as
  #      [raw_server, nil, timestamp].
  #   2. response_item / function_call — the model issuing the call. Its `name` is
  #      the sanitized `mcp__<server>__<tool>` tool name. Yielded as
  #      [nil, name, timestamp].
  def mcp_connection_events(transcript_content)
    source = TranscriptRuntime.source_for(@session, file_system: @file_system)
    source.parse_events(transcript_content).filter_map do |event|
      next unless event.is_a?(Hash)

      timestamp = event["timestamp"]
      next if stale?(timestamp)

      payload = event["payload"]
      next unless payload.is_a?(Hash)

      case event["type"]
      when "event_msg"
        next unless payload["type"] == "mcp_tool_call_end"

        server = payload.dig("invocation", "server")
        next unless server.is_a?(String) && server.present?

        [ server, nil, timestamp ]
      when "response_item"
        next unless payload["type"] == "function_call"

        name = payload["name"]
        next unless name.is_a?(String) && name.start_with?(MCP_TOOL_NAME_PREFIX)

        [ nil, name, timestamp ]
      end
    end
  end

  # Best-effort: scan captured Codex stderr for MCP startup failures, mapping each
  # to a trackable server. Servers already proven connected are never marked
  # failed (a successful tool call is definitive; Codex retries transient errors).
  def failed_servers(trackable_servers, connected_names)
    log_path = stderr_log_path
    return {} unless log_path && @file_system.exists?(log_path)

    content = @file_system.read(log_path)
    return {} if content.blank?

    statuses = {}
    content.each_line do |line|
      STDERR_FAILURE_PATTERNS.each do |pattern|
        match = line.match(pattern)
        next unless match

        server_name = match_trackable_server(match[:server], trackable_servers)
        next unless server_name
        next if connected_names.include?(server_name)

        statuses[server_name] = { status: "failed", error: line.strip }
      end
    end
    statuses
  rescue => e
    @logger.warn("Error reading Codex stderr for MCP failures", error: e.message)
    {}
  end

  # Resolve a server token captured from stderr to a trackable server name,
  # matching on the raw name first (Codex config keys servers by raw name) and
  # the sanitized name as a fallback.
  def match_trackable_server(token, trackable_servers)
    return nil if token.blank?

    trackable_servers.find { |name| name == token || sanitize(name) == sanitize(token) }
  end

  def stderr_log_path
    working_directory = @session.metadata&.dig("working_directory")
    return nil unless working_directory

    File.join(working_directory, "codex_stderr.log")
  end

  def stale?(timestamp)
    return false unless @min_timestamp && timestamp

    Time.parse(timestamp) < @min_timestamp
  rescue ArgumentError
    # Unparseable timestamp: keep the event (safer to include than exclude).
    false
  end

  # Mirror codex-rs `sanitize_responses_api_tool_name`: any char outside
  # [a-zA-Z0-9_-] becomes "_". Hyphens are preserved.
  def sanitize(name)
    name.to_s.gsub(/[^a-zA-Z0-9_-]/, "_")
  end
end
