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
    attr_reader :tool_groups, :allowed_agent_roots, :base_url, :caller_fingerprint, :self_session_id, :oauth_grant_id,
                :request_started_at

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
    # @param request_started_at [Float, nil] when the request arrived, on Process::CLOCK_MONOTONIC.
    #   `sync: true` measures its budget from here rather than from the start of its wait, so the
    #   work done before the wait (authentication, the create) comes out of the caller's
    #   `sync_timeout_seconds` instead of being added to it. Nil for a context that outlives one
    #   request (Live Mode's tool bridge), where the tool call's own start is the clock.
    # @param live_conversation [LiveConversation, nil] the Live Mode conversation whose
    #   assistant is calling, set only by LiveConversations::ToolBridge, which runs tools
    #   in process. McpController never sets it: nothing on POST /mcp — no query
    #   parameter, header or argument — reaches this. It makes the words a tool
    #   delivers into a session a candidate `live_mode` HumanMessage, recorded only
    #   when the conversation's latest `user` turn was authored by a person
    #   (HumanMessageCapture.record_live_mode_message).
    def initialize(tool_groups: nil, allowed_agent_roots: nil, base_url: nil, caller_fingerprint: nil,
                   session_id: nil, oauth_grant_id: nil, oauth_grant: nil, turn_source: nil,
                   request_started_at: nil, live_conversation: nil)
      @tool_groups = Registry.parse_groups(tool_groups)
      @allowed_agent_roots = parse_list(allowed_agent_roots).presence
      @base_url = base_url.presence || SelfSessionInjector.new.self_target[:base_url]
      @caller_fingerprint = caller_fingerprint.presence || HealthActionCooldown::ANONYMOUS
      @self_session_id = normalize_session_id(session_id)
      @oauth_grant_id = oauth_grant&.id || oauth_grant_id
      @oauth_grant = oauth_grant
      @turn_source = turn_source
      @request_started_at = request_started_at
      @live_conversation = live_conversation
    end

    # Where the words this connection delivers into a session came from, for the
    # turn-source note (TurnSource). A caller that knows better passes it — Live
    # Mode's tool bridge says which conversation and mode the delegation came out
    # of. Otherwise it follows the credential: a connection stamped with the
    # session it was written for is that agent session, and anything else — an
    # OAuth connector, an unstamped API key — is an MCP client whose modality
    # Zimmer cannot see. A style hint only; it grants and scopes nothing.
    #
    # @return [TurnSource]
    def turn_source
      @turn_source ||= if !oauth? && @self_session_id
        TurnSource.agent
      else
        TurnSource.new(surface: "mcp")
      end
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
    # behalf, or Live Mode's assistant answering a person whose words the
    # conversation's boundary authenticated. Every other connection records
    # nothing, which is the safe outcome. Called by the tools that carry text
    # into a session, after the text landed.
    #
    # @param entry_point [String] the tool's own, "oauth.<action>"; a Live Mode
    #   delivery is recorded as "live_mode.<action>"
    # @return [HumanMessage, nil]
    def capture_assistant_message(session, content, entry_point)
      if @live_conversation
        message = HumanMessageCapture.record_live_mode_message(
          session: session, conversation: @live_conversation, content: content,
          entry_point: entry_point.to_s.sub(/\Aoauth\./, "live_mode.")
        )
        note_live_capture_declined(session) if message.nil?
        return message
      end
      return nil unless oauth?

      HumanMessageCapture.record_assistant_message(
        session: session, grant: oauth_grant, content: content, entry_point: entry_point
      )
    end

    # Why a Live Mode delivery this context made was not recorded as the
    # person's, one sentence per delivery, for the tool bridge to hand back to
    # the live model so it can say so out loud. Drained by the reader.
    #
    # @return [Array<String>]
    def take_live_capture_declines
      declines = @live_capture_declines.to_a
      @live_capture_declines = []
      declines
    end

    def session_url(session)
      "#{base_url.chomp('/')}/sessions/#{session.id}"
    end

    private

    # Said once per delivery, and logged: until this existed a declined capture
    # left no trace anywhere, and a person could approve the same PR by voice
    # night after night without anyone being able to say why it never counted.
    def note_live_capture_declined(session)
      reason = HumanMessageCapture.live_mode_words(@live_conversation).declined ||
               "Zimmer could not record it"
      Rails.logger.info("[HumanMessageCapture] live_mode capture declined: live_conversation=#{@live_conversation.id} " \
                        "session=#{session&.id} reason=#{reason.truncate(300)}")
      (@live_capture_declines ||= []) << "Session #{session&.id}: not recorded as the person's own words, because #{reason}."
    rescue => e
      Rails.logger.error("[Mcp::Context] could not explain a declined Live Mode capture: #{e.class}: #{e.message}")
    end

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
