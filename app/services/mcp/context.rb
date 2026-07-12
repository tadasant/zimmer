# frozen_string_literal: true

module Mcp
  # Per-request scoping for a native MCP connection.
  #
  # The decoupled agent-orchestrator MCP server took its scoping from process
  # environment variables (TOOL_GROUPS, ALLOWED_AGENT_ROOTS) because each client
  # spawned its own process. A native server has one process serving every
  # client, so the same two knobs arrive as query parameters on the endpoint:
  #
  #   POST /mcp?tool_groups=self_session
  #   POST /mcp?tool_groups=sessions&allowed_agent_roots=zimmer,pulsemcp
  #
  # tool_groups selects which tools are registered (see Mcp::Registry).
  # allowed_agent_roots restricts which agent roots start_session may spawn and
  # which sessions the cross-session wake tool may watch.
  class Context
    attr_reader :tool_groups, :allowed_agent_roots, :base_url

    # The SDK wraps whatever is handed to `MCP::Server.new(server_context:)` in an
    # MCP::ServerContext (which carries progress/cancellation plumbing and
    # delegates everything else here). Tools want the real Context, so unwrap it.
    def self.unwrap(server_context)
      return server_context if server_context.is_a?(self)

      server_context.zimmer_context
    end

    # Identity, so #unwrap resolves through MCP::ServerContext's delegation.
    def zimmer_context
      self
    end

    # @param tool_groups [String, Array<String>, nil] comma-separated groups, or nil for the default set
    # @param allowed_agent_roots [String, Array<String>, nil] comma-separated root names, or nil for no restriction
    # @param base_url [String, nil] the externally reachable base URL of this Zimmer instance,
    #   used to build absolute links (session URLs, transcript archive downloads) in tool output
    def initialize(tool_groups: nil, allowed_agent_roots: nil, base_url: nil)
      @tool_groups = Registry.parse_groups(tool_groups)
      @allowed_agent_roots = parse_list(allowed_agent_roots).presence
      @base_url = base_url.presence || SelfSessionInjector.new.self_target[:base_url]
    end

    def tools
      @tools ||= Registry.tools_for(@tool_groups)
    end

    # Agent roots this connection may spawn sessions for, nil when unrestricted.
    def restricted?
      !@allowed_agent_roots.nil?
    end

    def session_url(session)
      "#{base_url.chomp('/')}/sessions/#{session.id}"
    end

    private

    def parse_list(value)
      case value
      when nil then []
      when Array then value.map { |v| v.to_s.strip }.reject(&:empty?)
      else value.to_s.split(",").map(&:strip).reject(&:empty?)
      end
    end
  end
end
