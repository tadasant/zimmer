# frozen_string_literal: true

module Mcp
  module Tools
    # quick_router as the Live Mode assistant gets it (the `live_mode` tool
    # group): the prompt and nothing else. No scheduling class, no context, no
    # sync wait — a voice call cannot hold a tool call open for minutes — and no
    # idempotency key. It is that surface's only way to start work, so how the
    # work is set up (root, servers, class) is always the router's decision.
    #
    # The description's first sentence is what the voice model sees: the gateway
    # summarises each tool to about 160 characters (ToolBridge::SUMMARY_LIMIT).
    class LiveModeQuickRouter < QuickRouter
      tool_name "quick_router"

      ACCEPTED_ARGUMENTS = %w[prompt].freeze

      REFUSED_MERGE = "Nothing was started: a router session cannot carry a merge authorization. To merge a PR the " \
                      "person approved, use `authorize_merge`, which reads it back and needs their yes."

      description <<~DESC
        Hand new work to a background agent in plain words (never a merge; that is authorize_merge); Zimmer picks the agent, tools and repo.

        This is the only way to start work from here. Put everything the person said that matters in `prompt`:
        names, links, the outcome they want. It returns the new session's id straight away; the work runs in the
        background. Check on it later with `get_session`, and pass the person's answers to it with
        `action_session` `follow_up`.

        Anything you cannot do yourself — changing how a session is set up, schedules, servers, settings —
        goes here too, as a request in the person's words.

        **Never use it to merge.** A router cannot carry a merge authorization, and a prompt carrying the merge
        marker is refused. Merging goes only through `authorize_merge`.
      DESC

      input_schema({
        type: "object",
        properties: {
          prompt: {
            type: "string",
            description: "What to do, in plain language, with everything the person said that matters. Up to " \
                         "#{Session::PROMPT_MAX_LENGTH.to_fs(:delimited)} characters."
          }
        },
        required: [ "prompt" ]
      })

      # Sliced rather than trusted to the schema: no schema here sets
      # `additionalProperties: false`, so an argument this surface does not
      # advertise would otherwise reach the parent's body.
      def call(args)
        prompt = args["prompt"].to_s
        raise ToolError, REFUSED_MERGE if LiveModeActionSession.carries_merge_marker?(prompt)

        super(args.slice(*ACCEPTED_ARGUMENTS))
      end
    end
  end
end
