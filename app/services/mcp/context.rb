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
    attr_reader :tool_groups, :allowed_agent_roots, :base_url, :caller_fingerprint, :self_session_id, :oauth_grant_id

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
    # @param caller_fingerprint [String, nil] an opaque digest of this connection's API key, used
    #   only to give HealthActionCooldown a per-caller bucket. It grants nothing and scopes nothing
    #   — tool_groups and allowed_agent_roots above are the only things that govern reach.
    # @param session_id [String, Integer, nil] the session this connection was written FOR.
    #   RuntimeConfigPostProcessor stamps it onto the URL of the Zimmer server it injects into a
    #   session's own runtime config, which is the only place the caller's identity is knowable —
    #   the API key is shared by the whole fleet and the endpoint is stateless, so a request
    #   otherwise says nothing about who is making it. It is mostly a DEFAULT for the "which session
    #   is asking" argument on the self-management tools: it widens no scope, grants no tool, and an
    #   explicit session_id argument still wins.
    #
    #   It is NOT only a default any more, and the exception is worth knowing. It is also the
    #   answer to "is this caller the session it is acting on", which is what exempts a session
    #   archiving ITSELF from the refusal that stops one session killing another's in-flight turn
    #   (Sessions::LiveTurn, #400). So a connection stamped with another session's id inherits that
    #   session's exemption — which is why ForkSessionService prepares a fork's config for the fork.
    # @param oauth_grant_id [Integer, nil] the OauthServer::Grant this request authenticated with, nil
    #   for an API key. A grant is what a remote MCP client such as a Claude.ai connector holds after a
    #   human approved it, so it says the caller is that human's assistant rather than one of the
    #   fleet's agents. It grants nothing and scopes nothing. On its own it names who approved the
    #   CLIENT, not who wrote a given argument; only a grant that also holds
    #   OauthServer::ACT_AS_HUMAN_SCOPE — the approver's explicit choice — makes the words its client
    #   delivers into a session a HumanMessage (see #capture_assistant_message).
    # @param oauth_grant [OauthServer::Grant, nil] the grant itself, when the caller already loaded it
    def initialize(tool_groups: nil, allowed_agent_roots: nil, base_url: nil, caller_fingerprint: nil,
                   session_id: nil, oauth_grant_id: nil, oauth_grant: nil)
      @tool_groups = Registry.parse_groups(tool_groups)
      @allowed_agent_roots = parse_list(allowed_agent_roots).presence
      @base_url = base_url.presence || SelfSessionInjector.new.self_target[:base_url]
      @caller_fingerprint = caller_fingerprint.presence || HealthActionCooldown::ANONYMOUS
      @self_session_id = normalize_session_id(session_id)
      @oauth_grant_id = oauth_grant&.id || oauth_grant_id
      @oauth_grant = oauth_grant
    end

    def tools
      @tools ||= Registry.tools_for(@tool_groups)
    end

    # Agent roots this connection may spawn sessions for, nil when unrestricted.
    def restricted?
      !@allowed_agent_roots.nil?
    end

    # Whether this request authenticated with an OAuth access token rather than an API key.
    def oauth?
      !@oauth_grant_id.nil?
    end

    def oauth_grant
      return nil unless oauth?

      @oauth_grant ||= OauthServer::Grant.find_by(id: @oauth_grant_id)
    end

    # Record words this connection delivered into `session` as the human's, when
    # — and only when — it is an OAuth grant its approver let act on their
    # behalf. Every other connection records nothing, which is the safe outcome.
    # Called by the tools that carry text into a session, after the text landed.
    #
    # @return [HumanMessage, nil]
    def capture_assistant_message(session, content, entry_point)
      return nil unless oauth?

      HumanMessageCapture.record_assistant_message(
        session: session, grant: oauth_grant, content: content, entry_point: entry_point
      )
    end

    def session_url(session)
      "#{base_url.chomp('/')}/sessions/#{session.id}"
    end

    private

    # Positive integers only. A blank, zero, negative or non-numeric value means
    # the connection carries no caller identity, which is the pre-existing
    # behaviour and must stay a clean "not supplied" rather than a bad default
    # that sends a wake at some unrelated session.
    def normalize_session_id(value)
      id = value.to_s.strip
      return nil unless id.match?(/\A\d+\z/)

      id = id.to_i
      id.positive? ? id : nil
    end

    def parse_list(value)
      case value
      when nil then []
      when Array then value.map { |v| v.to_s.strip }.reject(&:empty?)
      else value.to_s.split(",").map(&:strip).reject(&:empty?)
      end
    end
  end
end
