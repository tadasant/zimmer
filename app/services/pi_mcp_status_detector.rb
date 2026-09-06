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
# == This detector reports CONNECTED and nothing else ==
#
# There is no `failed` here, deliberately, and the reason is not timidity.
#
# The adapter connects **lazily**: at spawn every server reads "not listening;
# disconnected", and that is the healthy resting state. A server nobody called is
# not a broken server, so `pending` is already the honest word for it.
#
# And a refusal does not mean what it appears to. `Server "x" requires OAuth
# authentication` is the adapter's message for **any 401 during connect**
# (`isUnauthorizedHttpError` → `getAuthRequiredMessage` in `proxy-modes.ts`),
# whether Zimmer supplied a credential or not — so it equally means "no token"
# and "the token was rejected", including a token that merely expired mid-turn.
# `McpStatusPersisting` escalates a *configured* server's `failed` to a
# session-level failure, one-shot and irreversible. Reporting `failed` on that
# message would therefore invent a new way to kill a Pi session, on a signal that
# cannot distinguish a misconfiguration from a bad minute at the provider.
# Reporting only what connected is a strict improvement on reporting nothing, and
# it adds no failure path at all.
#
# == What counts as evidence, and why a tool CALL is not enough ==
#
# Both signals below require the call's **result**, not just the call.
#
# The tempting shortcut — "the adapter registers `mcp__<server>` only for a
# server whose metadata cache is valid, so the tool existing proves a
# connection" — is wrong, and wrong in the direction that produces false greens.
# That cache (`metadata-cache.ts`) lives at `<agent dir>/mcp-cache.json`, is
# **host-global**, and is valid for seven days: `mcp__notion` is registered at
# spawn because some *other* session connected notion six days ago. Invoking it
# then forwards to `executeCall`, which answers `requires OAuth authentication`,
# `not available (last failed Ns ago)` or `not connected` without connecting
# anything. A detector keyed on the call alone would paint that green.
#
#   1. **A `mcp__<server>` namespace-proxy call whose result is not a refusal.**
#      The server name is in the tool name, so nothing is parsed out of prose;
#      the result is only inspected to rule out the adapter's refusal shapes.
#   2. **An `mcp({ connect: "<server>" })` call whose result announces a tool
#      count.** This is the first-turn signal: with no cache there is no
#      namespace proxy, so the agent reaches the server through the bare proxy.
#
# `mcp({ server: "x" })` is deliberately NOT a signal. It routes to `executeList`,
# a pure cache read that attempts no connection, and it renders success and
# failure with the *same* `<server> (<n> tools` prefix — the failures merely add a
# parenthetical (`(lazy: … not connected yet …)`, `(needs auth — …)`). Treating it
# as a connect is how a needs-auth server reads green.
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

  # The adapter's rendering of a successful `connect`: `context7 (16 tools):`.
  #
  # `\)` at the end is what separates it from `executeList`'s cached renderings,
  # which open a second parenthesis instead — `(16 tools (lazy: … not connected
  # yet …))`, `(16 tools (needs auth — …))`. Matching those would green a server
  # the adapter is saying is NOT connected.
  CONNECT_SUCCESS = /\A\s*\(\s*\d+\s+tools?\s*\)/

  # The shapes `executeCall` / `executeList` answer with instead of a tool result
  # when the server did not actually connect (`proxy-modes.ts`, `direct-tools.ts`,
  # `ui-server.ts`). A result carrying any of these is not evidence of a
  # connection. Matching one only withholds a `connected`, so a false positive
  # here costs a gray pill and never a wrong one.
  REFUSAL_MARKERS = [
    /requires OAuth authentication/i,
    /OAuth authentication failed/i,
    /needs auth/i,
    /not connected/i,
    /not available \(last failed/i,
    /\bis disabled\b/i
  ].freeze

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
  # @return [Hash] { logs: [], server_statuses: { name => { status:, connected_at: } } }
  #   `logs` is always empty — Pi writes no per-server MCP log lines to fold into
  #   the timeline, so the status pills are driven purely by server_statuses.
  #   Every status is `connected`; see the class comment.
  def poll(transcript_content: nil)
    trackable = session.all_mcp_servers
    return { logs: [], server_statuses: {} } if trackable.empty? || transcript_content.blank?

    { logs: [], server_statuses: connected_servers(transcript_content, trackable) }
  rescue => e
    @logger.error("Error detecting Pi MCP status", error: e.message)
    { logs: [], server_statuses: {} }
  end

  private

  def connected_servers(transcript_content, trackable)
    # Map every trackable server's namespace-proxy tool name back to the server.
    # Built from the CONFIGURED names rather than parsed out of the tool name,
    # because the adapter's mapping is lossy (`a-b` and `a_b` both become `a_b`).
    # A name that two servers share identifies neither, so it is dropped: a
    # status on the wrong server is worse than no status.
    by_proxy_name = trackable.group_by { |name| namespace_proxy_name(name) }
      .select { |_proxy, names| names.one? }
      .transform_values(&:first)

    statuses = {}
    # call id => [server, kind, timestamp]. A call is remembered, never recorded:
    # only its result says whether the server answered.
    pending_calls = {}

    each_entry(transcript_content) do |entry, timestamp|
      message = entry["message"]
      next unless message.is_a?(Hash)

      case message["role"]
      when "assistant"
        each_tool_call(message) do |call|
          id = call["id"]
          next if id.blank?

          if (server = by_proxy_name[call["name"]])
            pending_calls[id] = [ server, :proxy, timestamp ]
          elsif call["name"] == BARE_PROXY_TOOL && (server = connect_argument(call, trackable))
            pending_calls[id] = [ server, :connect, timestamp ]
          end
        end
      when "toolResult"
        server, kind, call_timestamp = pending_calls[message["toolCallId"]]
        next unless server

        text = result_text(message)
        next unless connected?(kind, server, text, message)

        record_connected(statuses, server, call_timestamp || timestamp)
      end
    end

    statuses
  end

  # @param kind [Symbol] :proxy (a `mcp__<server>` call) or :connect (the bare proxy)
  def connected?(kind, server, text, message)
    # `isError` is the runtime's own verdict and costs nothing to honour.
    return false if message["isError"]
    return false if REFUSAL_MARKERS.any? { |pattern| text.match?(pattern) }

    case kind
    when :connect
      # Anchored on the server's own name, so a name mentioned inside prose
      # cannot match, and closed on `)` so `executeList`'s cached renderings
      # cannot either.
      stripped = text.strip
      remainder = stripped.delete_prefix(server)
      remainder != stripped && remainder.match?(CONNECT_SUCCESS)
    else
      # A namespace-proxy call that came back without a refusal reached the
      # server: `executeCall` answers every non-connection case with one of the
      # shapes above, and anything else is the MCP tool's own output.
      true
    end
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

  # `Time.zone.parse` RETURNS NIL for unparseable input rather than raising, so
  # the nil check is the guard and the rescue is only for the shapes that do
  # raise. Getting this wrong turned one junk line into a NoMethodError that the
  # blanket rescue in #poll swallowed as "no statuses" — for the whole
  # transcript, on every later poll, since the line stays in the file.
  def stale?(timestamp)
    return false if min_timestamp.nil? || timestamp.blank?

    parsed = Time.zone.parse(timestamp.to_s)
    return false if parsed.nil?

    parsed < min_timestamp
  rescue ArgumentError, TypeError
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

  # The server named by an `mcp({ connect: "x" })` call. `server:` is NOT
  # accepted — see the class comment. Only a name this session actually has.
  def connect_argument(call, trackable)
    args = call["arguments"]
    return nil unless args.is_a?(Hash)

    name = args["connect"]
    return nil unless name.is_a?(String)

    trackable.include?(name) ? name : nil
  end

  def result_text(message)
    content = message["content"]
    return "" unless content.is_a?(Array)

    content.filter_map { |part| part["text"] if part.is_a?(Hash) && part["type"] == "text" }.join("\n")
  end

  # Keep the earliest evidence per server, so `connected_at` is when the server
  # first answered rather than whenever it was last used.
  def record_connected(statuses, server, timestamp)
    existing = statuses[server]
    return if existing && !earlier?(timestamp, existing[:connected_at])

    statuses[server] = { status: "connected", connected_at: timestamp }
  end

  # Compared as parsed times rather than as strings: Pi writes `toISOString`
  # today, which sorts correctly lexicographically, but `…:29Z` and `…:29.100Z`
  # do not sort against each other, so a change of shape would silently invert
  # this. Unparseable values fall back to string order rather than raising.
  def earlier?(candidate, current)
    return false if candidate.blank?
    return true if current.blank?

    a = Time.zone.parse(candidate.to_s)
    b = Time.zone.parse(current.to_s)
    return a < b if a && b

    candidate.to_s < current.to_s
  rescue ArgumentError, TypeError
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
