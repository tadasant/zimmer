# frozen_string_literal: true

module Mcp
  module Tools
    # The Quick Router, as a tool: a request in plain language becomes a router
    # session, exactly as it does from the chat bubble, the dashboard quick prompt
    # and the browser extension. The router decides which agent root, servers and
    # goal the work needs, so a client that knows nothing about Zimmer — Claude.ai
    # in voice mode, say — can get anything done in one call.
    #
    # Same flow, not a parallel one: the prompt is composed by QuickRouterPrompt,
    # the session is created against AgentRootsConfig.router_root_name with
    # Session.create_from_agent_root!, and the job is enqueued the same way.
    #
    # Three decisions differ from the browser surfaces, and each follows from who
    # can be on the other end of /mcp:
    #
    # * **No HumanMessage.** The browser surfaces record the prompt because a
    #   human typed it there. Here the arguments are written by the calling
    #   model. On an API key that model is one of the fleet's agents; on an OAuth
    #   grant it is a human's assistant (Claude.ai) paraphrasing them, and the
    #   grant names who approved the client, not who wrote these words. Either way
    #   it is a composed prompt, which HumanMessageCapture never records.
    #
    # * **Restricted connections need the router root on their allowlist.** The
    #   router can start sessions on any root, so on a connection fenced to a few
    #   roots this would be a way around the fence. It is refused unless the
    #   connection could already have called start_session on the router root
    #   itself — which adds nothing that connection did not already have.
    #
    # * **Scheduling class.** The browser surfaces are `web_ui` genesis, priority
    #   by default, because a human is waiting. Here a caller that names a class
    #   gets it. Otherwise an OAuth caller gets priority, since a person is waiting
    #   on that assistant, and an API-key caller gets what any agent spawn gets:
    #   its parent's lineage when the connection names a calling session, the
    #   `api` genesis's default otherwise.
    class QuickRouter < Tool
      tool_name "quick_router"

      SOURCE = "mcp_quick_router"

      # Prepended to the server's `instructions` whenever this tool is on the
      # connection — see McpController#instructions.
      SERVER_INSTRUCTIONS = "Start with `quick_router`: give it any request in plain language and Zimmer " \
                            "routes it to the right agent and tools itself. It is the quickest way to get an " \
                            "answer or get anything done here, and you do not need to know how Zimmer is " \
                            "configured to use it."

      description <<~DESC
        **The quickest way to get an answer or get anything done in Zimmer.** Describe what you want in plain
        language, the way you would to a colleague, and Zimmer does it: answer a question about its sessions
        or code, fix a bug, open a pull request, check on running work, send a message through a connected
        service. Zimmer can do anything through this tool.

        It starts a Quick Router session (the same one Zimmer's in-app chat bubble starts). That session reads
        your request, works out which repository, tools and goal it needs, and starts and supervises whatever
        work follows. You do not pick any of that.

        **Prefer this over `start_session` unless you already know Zimmer's agent roots and MCP servers.**
        Hand-composing `start_session` means calling `get_configs`, choosing an agent root, its MCP servers
        and a goal yourself, and getting a list wrong silently drops a server the work needed. If you are
        an assistant acting for a person and are not sure how Zimmer works, use this and let Zimmer figure
        it out.

        Returns the new session's id and URL straight away; the work runs in the background. To follow it:
        - `get_session` with that id. When its status is `needs_input` or `archived` the router has replied,
          and its **Status summary** is the short answer. For the router's full reply, call `get_session`
          with `include_transcript: true` and `transcript_format: "text"` (this can be long).
        - `action_session` with `follow_up` to answer a question the router asked or to add instructions.

        On a connection restricted to specific agent roots this is refused unless the router's root is one
        of them, because the router can start work on any root.
      DESC

      input_schema({
        type: "object",
        properties: {
          prompt: {
            type: "string",
            description: "What you want, in plain language. Include everything you know that matters: names, " \
                         "links, the outcome you want. Up to #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters."
          },
          context: {
            type: "string",
            description: "Optional. What the person is looking at or talking about, e.g. the text of a page or " \
                         "message. Passed to the router as background, marked as data rather than instructions."
          },
          context_url: {
            type: "string",
            description: "Optional. The URL that `context` came from."
          },
          scheduling_class: {
            type: "string",
            enum: SessionGenesis::CLASSES,
            description: "Optional. \"priority\" starts as soon as possible; \"spot\" waits for spare quota. " \
                         "Defaults to priority for a remote assistant connected over OAuth (a person is waiting), " \
                         "and to the usual default for an agent spawn otherwise. Pass \"spot\" for work nobody " \
                         "is waiting on."
          }
        },
        required: [ "prompt" ]
      })

      def call(args)
        enforce_any_allowed_root!(AgentRootsConfig::ROUTER_ROOT_NAMES)

        prompt = require_arg(args, "prompt").to_s.strip
        raise ToolError, "Missing required parameter: prompt" if prompt.empty?
        if prompt.length > Session::PROMPT_MAX_LENGTH
          raise ToolError, "prompt is too long (maximum #{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters)"
        end

        context_text = args["context"].to_s.strip.truncate(QuickRouterPrompt::PAGE_CONTEXT_MAX_LENGTH)
        context_url = args["context_url"].to_s.strip.truncate(Api::V1::QuickRouterController::PAGE_URL_MAX_LENGTH)
        augmented_prompt = QuickRouterPrompt.augment(prompt: prompt, page_context: context_text, current_url: context_url)
        if augmented_prompt.length > Session::PROMPT_MAX_LENGTH
          raise ToolError, "prompt and context together are too long; send less context"
        end

        parent = calling_session
        session = Session.create_from_agent_root!(
          agent_root_name: AgentRootsConfig.router_root_name,
          prompt: augmented_prompt,
          parent_session_id: parent&.id,
          # Nothing connects a parentless call to a human, so it is classified the
          # way a parentless start_session is. With a parent it inherits.
          genesis: parent ? nil : SessionGenesis::API,
          scheduling_class: scheduling_class(args),
          metadata: {
            source: SOURCE,
            original_prompt: prompt,
            current_url: context_url,
            mcp_auth: context.oauth? ? "oauth" : "api_key",
            oauth_grant_id: context.oauth_grant_id
          }.compact_blank,
          skip_enqueue: true
        )

        AgentSessionJob.enqueue_new_session(session.id)

        format_result(session)
      rescue AgentRootsConfig::AgentRootNotFoundError => e
        raise ToolError, "Router agent root not configured: #{e.message}"
      end

      private

      # The session this connection was written for, when it names one that
      # exists — the same lineage edge the chat bubble draws from the page it is
      # opened on. A connection with no session (Claude.ai, a human's curl) has no
      # parent, and a stale id is ignored rather than refused: a missing parent
      # costs a lineage edge, not the request.
      def calling_session
        return nil unless context.self_session_id

        Session.find_by(id: context.self_session_id)
      end

      def scheduling_class(args)
        requested = args["scheduling_class"].to_s.strip
        return requested if SessionGenesis::CLASSES.include?(requested)
        raise ToolError, "scheduling_class must be one of: #{SessionGenesis::CLASSES.join(', ')}" if requested.present?

        SessionGenesis::PRIORITY if context.oauth?
      end

      def format_result(session)
        [
          "## Quick Router session started",
          "",
          "- **ID:** #{session.id}",
          "- **URL:** #{session_url(session)}",
          "- **Status:** #{session.status}",
          "",
          "The router is working on it in the background. It usually takes a minute or more before it has " \
          "an answer, and longer when the request turns into real work.",
          "",
          "To follow up:",
          "- Call `get_session` with id `#{session.id}`. When the status is `needs_input` or `archived`, the " \
          "router has replied; its **Status summary** is the short answer. For the full reply, pass " \
          "`include_transcript: true` and `transcript_format: \"text\"`.",
          "- Use `action_session` with `follow_up` to answer the router or add instructions.",
          "- Share the URL with the person you are helping; they can watch the session there."
        ].join("\n")
      end
    end
  end
end
