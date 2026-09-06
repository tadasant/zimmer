# frozen_string_literal: true

# Detects per-MCP-server connection status for Pi runtime sessions.
#
# == Why this exists, when NullMcpStatusDetector was the documented answer ==
#
# Pi's bundle used to carry NullMcpStatusDetector, on the argument that
# "the pi-mcp-adapter extension routes every server through a single `mcp` proxy
# tool, so a Pi transcript shows `mcp` being called and never names the server
# behind it." That was true of an older adapter. It is NOT true of the pinned one
# (`pi-mcp-adapter` 2.32.1, see PiExtensions), which registers a **namespace
# proxy tool per server**, named `mcp__<server>` — `namespaceProxyName` in the
# adapter's `mcp-references.ts`. A Pi transcript therefore does name the server,
# structurally, in the tool name.
#
# The cost of the stale assumption was not cosmetic. `mcp_servers_status` stayed
# `pending` for every server of every Pi session forever, which is what the
# Zimmer UI renders — so a Pi session whose MCP servers were connected and being
# called successfully was indistinguishable, on the session page, from one whose
# MCP was dead. That is how a working Pi session came to be reported as "MCP
# connectors don't work with Pi": five of its six servers were fine, and nothing
# in Zimmer could say so.
#
# == The two signals, and why only these two ==
#
# Both are read out of the Pi session JSONL. Both are conservative: the default
# is to say nothing (leaving `pending`) rather than to guess.
#
#   1. **A `mcp__<server>` namespace-proxy tool call — CONNECTED.** The adapter
#      registers that tool only for a server whose metadata cache is valid and
#      holds callable targets (`namespaceProxyCandidate` in `namespace-tools.ts`),
#      so the tool existing at all means the server connected and published a
#      tool list. The server name is in the tool name, so no text is parsed.
#
#   2. **An `mcp({ connect: "<server>" })` call whose result announces a tool
#      count — CONNECTED.** This is the first-turn signal: before any successful
#      connection there is no cache, so no namespace proxy is registered, and the
#      agent reaches the server through the bare `mcp` proxy. The server name
#      comes from the call's own `connect` argument (structural), and the result
#      is only inspected to tell success from refusal — anchored on
#      `<server> (<n> tools`, which is the adapter's own success rendering.
#
# A failed connect is deliberately NOT escalated to `failed`. The adapter
# connects **lazily**: at spawn every server reads "not listening; disconnected",
# and that is the normal, healthy resting state rather than a fault. A server
# nobody ever called has no evidence either way, and `pending` is the honest word
# for it. Marking a refusal `failed` would also escalate to a session-level
# failure for a *configured* server (see McpStatusPersisting), which would kill
# sessions over a server the agent merely poked at and did not need.
#
# The one exception is an OAuth refusal, which is not a transient miss but a
# standing statement that Zimmer never gave the runtime a usable credential. It
# is recorded as `failed` with the adapter's own message so the session page says
# why. See PiMcpCredentialWriter for the other half of that story.
class PiMcpStatusDetector
  # McpStatusPersisting brings DatabaseRetry with it.
  include McpStatusPersisting

  # `namespaceProxyName` in pi-mcp-adapter's `mcp-references.ts`.
  NAMESPACE_PROXY_PREFIX = "mcp__"

  # The adapter's own marker for a server part it had to hex-encode because the
  # name does not survive the plain hyphen-to-underscore mapping.
  ENCODED_NAMESPACE_MARKER = "_mcpns_"

  # The bare proxy tool every Pi session gets, through which a server is
  # connected on demand.
  BARE_PROXY_TOOL = "mcp"

  # The adapter's rendering of a successful `connect`: `<server> (16 tools):`.
  # Anchored at the start so a server name merely mentioned inside an error
  # cannot match.
  CONNECT_SUCCESS = /\A[^\S\n]*\(?\s*\d+\s+tools?\b/

  # The adapter's standing "Zimmer never gave me a credential" refusal
  # (`getAuthRequiredMessage` in `proxy-modes.ts`, and the same string in
  # `direct-tools.ts` / `ui-server.ts`).
  OAUTH_REQUIRED = /requires OAuth authentication/i

  attr_reader :session, :file_system, :min_timestamp

  # Mirrors the McpLogPollerService / CodexMcpStatusDetector constructor so the
  # runtime bundle can build any of them the same way.
  #
  # @param session [Session]
  # @param file_system [FileSystemAdapter] accepted for contract symmetry; unused
  # @param min_timestamp [Time, nil] transcript entries older than this are
  #   ignored, so a resumed session does not read connection state from a run
  #   whose processes are long gone.
  def initialize(session, file_system: nil, min_timestamp: nil, logger: nil)
    @session = session
    @file_system = file_system || RealFileSystemAdapter.new
    @min_timestamp = min_timestamp
    @logger = logger || StructuredLogger.new({ session_id: session&.id, service: "PiMcpStatusDetector" })
  end

  # @param transcript_content [String, nil] the Pi session JSONL read so far
  # @return [Hash] { logs: [], server_statuses: { name => { status:, ... } } }
  #   `logs` is always empty — Pi writes no per-server MCP log lines to fold into
  #   the timeline, so the status pills are driven purely by server_statuses.
  def poll(transcript_content: nil)
    trackable = session.all_mcp_servers
    return { logs: [], server_statuses: {} } if trackable.empty? || transcript_content.blank?

    { logs: [], server_statuses: statuses_from(transcript_content, trackable) }
  rescue => e
    @logger.error("Error detecting Pi MCP status", error: e.message)
    { logs: [], server_statuses: {} }
  end

  private

  def statuses_from(transcript_content, trackable)
    # Map every trackable server's namespace-proxy tool name back to the server.
    # Built from the CONFIGURED names rather than parsed out of the tool name,
    # because the adapter's mapping is lossy (`a-b` and `a_b` both become `a_b`).
    # A name that two servers share identifies neither, so it is dropped: a
    # status on the wrong server is worse than no status.
    by_proxy_name = trackable.group_by { |name| namespace_proxy_name(name) }
      .select { |_proxy, names| names.one? }
      .transform_values(&:first)

    statuses = {}
    connect_calls = {}

    each_entry(transcript_content) do |entry, timestamp|
      message = entry["message"]
      next unless message.is_a?(Hash)

      case message["role"]
      when "assistant"
        each_tool_call(message) do |call|
          name = call["name"]
          if (server = by_proxy_name[name])
            record_connected(statuses, server, timestamp)
          elsif name == BARE_PROXY_TOOL && (server = connect_argument(call, trackable))
            # Remembered, not recorded: the call proves an attempt, and only the
            # result says whether it landed.
            connect_calls[call["id"]] = server if call["id"].present?
          end
        end
      when "toolResult"
        server = connect_calls[message["toolCallId"]]
        next unless server

        apply_connect_result(statuses, server, result_text(message), timestamp)
      end
    end

    statuses
  end

  # Walk the JSONL, skipping malformed lines and anything older than the cutoff.
  def each_entry(transcript_content)
    transcript_content.each_line do |line|
      line = line.strip
      next if line.empty?

      entry = begin
        JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      next unless entry.is_a?(Hash) && entry["type"] == "message"

      timestamp = entry["timestamp"]
      next if stale?(timestamp)

      yield entry, timestamp
    end
  end

  def stale?(timestamp)
    return false if min_timestamp.nil? || timestamp.blank?

    Time.zone.parse(timestamp.to_s) < min_timestamp
  rescue ArgumentError, TypeError
    # An unparseable timestamp is not evidence of staleness; keep the entry.
    false
  end

  def each_tool_call(message)
    content = message["content"]
    return unless content.is_a?(Array)

    content.each do |part|
      next unless part.is_a?(Hash) && part["type"] == "toolCall"

      yield part
    end
  end

  # The server named by an `mcp({ connect: "x" })` / `mcp({ server: "x" })` call.
  # Only a name this session actually has is accepted.
  def connect_argument(call, trackable)
    args = call["arguments"]
    return nil unless args.is_a?(Hash)

    name = args["connect"] || args["server"]
    return nil unless name.is_a?(String)

    trackable.include?(name) ? name : nil
  end

  def result_text(message)
    content = message["content"]
    return "" unless content.is_a?(Array)

    content.filter_map { |part| part["text"] if part.is_a?(Hash) && part["type"] == "text" }.join("\n")
  end

  # Read one `connect` result. Success is anchored immediately after the server
  # name so a name mentioned inside prose cannot green a server; an OAuth refusal
  # is the one failure worth recording (see the class comment).
  def apply_connect_result(statuses, server, text, timestamp)
    remainder = text.strip.delete_prefix(server)

    if remainder != text.strip && remainder.match?(CONNECT_SUCCESS)
      record_connected(statuses, server, timestamp)
    elsif text.match?(OAUTH_REQUIRED)
      # Never downgrade a server that has already proven it connected.
      return if statuses[server]&.dig(:status) == "connected"

      statuses[server] = { status: "failed", error: text.strip.truncate(500), failed_at: timestamp }
    end
  end

  # Keep the earliest evidence per server, so `connected_at` is when the server
  # first answered rather than whenever it was last used.
  def record_connected(statuses, server, timestamp)
    existing = statuses[server]
    return if existing && existing[:status] == "connected" && !earlier?(timestamp, existing[:connected_at])

    statuses[server] = { status: "connected", connected_at: timestamp }
  end

  def earlier?(candidate, current)
    return false if candidate.blank?
    return true if current.blank?

    candidate.to_s < current.to_s
  end

  # Ruby mirror of `namespaceServerPart` + `namespaceProxyName` in
  # pi-mcp-adapter's `mcp-references.ts`. Kept literal rather than tidied so a
  # future adapter bump can be diffed against it directly.
  def namespace_proxy_name(server_name)
    normalized = server_name.to_s.tr("-", "_")
    part =
      if normalized.empty? || (normalized.match?(/\A[A-Za-z0-9_]+\z/) && !normalized.start_with?(ENCODED_NAMESPACE_MARKER))
        normalized
      else
        "#{ENCODED_NAMESPACE_MARKER}#{normalized.each_codepoint.map { |c| c.to_s(16) }.join('_')}"
      end
    "#{NAMESPACE_PROXY_PREFIX}#{part}"
  end
end
