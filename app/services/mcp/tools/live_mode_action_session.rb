# frozen_string_literal: true

module Mcp
  module Tools
    # action_session as the Live Mode assistant gets it (the `live_mode` tool
    # group). Same tool name and the same action bodies as ActionSession, four
    # actions:
    #
    # - `follow_up` — tell a session something (queued, or `force_immediate` to
    #   redirect it). No goal change, no sync wait, and never a merge: a prompt
    #   carrying the merge-authorization marker is refused, because the only
    #   route to merging by voice is `authorize_merge`, which names the PR once
    #   and needs a fresh yes.
    # - `archive` — never forced. Archiving over a queued message, or over a
    #   turn in flight, is refused with the reason, and the assistant says it.
    # - `unarchive`, `set_carplay_fit`.
    #
    # Everything about how a session is set up — servers, skills, model, goal,
    # scheduling class, precedence, start_now, restart, fork, bulk_archive — is
    # absent. The assistant hands those to `quick_router` in the person's words.
    class LiveModeActionSession < ActionSession
      tool_name "action_session"

      ACTIONS = %w[follow_up archive unarchive set_carplay_fit].freeze

      ACCEPTED_ARGUMENTS = %w[session_id action prompt force_immediate carplay_fit carplay_fit_reason].freeze

      LIVE_ACTION_DESC = 'Action: "follow_up" (needs "prompt"), "archive", "unarchive", "set_carplay_fit" (needs "carplay_fit").'

      LIVE_PROMPT_DESC = 'For "follow_up": what to tell the session, in the person\'s words. Never a merge approval: use authorize_merge for that.'

      LIVE_FORCE_IMMEDIATE_DESC = 'Optional for "follow_up". true interrupts a running session so it reads this now. Only when the message changes what it should be doing; otherwise leave it off and it is read when the current turn ends.'

      REFUSED_MERGE = "Nothing was sent: a follow-up cannot carry a merge authorization. To merge a PR the person " \
                      "approved, use `authorize_merge`, which names the PR once and needs their yes."

      description <<~DESC
        Tell an existing session something with follow_up (never a merge approval; that is authorize_merge), or archive, unarchive or set its CarPlay fit.

        **Actions:**
        - **follow_up**: Deliver "prompt" to the session. A running session reads it when its current turn ends; set
          "force_immediate" to interrupt it when the message changes what it should be doing. A session that is
          `waiting`, "Paused" or "asleep until" a time still takes it straight away and answers, usually within a
          minute or two. Check back with `get_session` and `transcript_last_messages: 2`.
        - **archive**: Archive a session that is done. Refused when a message is still queued for it or it is in
          the middle of a turn; say so, and do not try to get round it.
        - **unarchive**: Bring an archived session back, idle in `needs_input`.
        - **set_carplay_fit**: "carplay_ok" when what it needs from the person can be done by voice; "laptop_only"
          when it needs a screen or keyboard; "clear" removes the mark.

        **Never a merge.** A follow-up that carries the merge-authorization marker is refused. Merging goes only
        through `authorize_merge`.

        Anything else about a session — its servers, model, goal, schedule — is not here: hand it to
        `quick_router` in the person's words.
      DESC

      input_schema({
        type: "object",
        properties: {
          session_id: {
            oneOf: [ { type: "string" }, { type: "number" } ],
            description: "The session's id."
          },
          action: { type: "string", enum: ACTIONS, description: LIVE_ACTION_DESC },
          prompt: { type: "string", description: LIVE_PROMPT_DESC },
          force_immediate: { type: "boolean", description: LIVE_FORCE_IMMEDIATE_DESC },
          carplay_fit: { type: "string", enum: SessionCarplayFit::FITS + [ "clear" ], description: CARPLAY_FIT_DESC },
          carplay_fit_reason: { type: "string", enum: SessionCarplayFit::REASONS, description: CARPLAY_FIT_REASON_DESC }
        },
        required: [ "session_id", "action" ]
      })

      # AutomatedPrompts::MERGE_AUTHORIZATION_MARKER, matched case-insensitively
      # and with any spacing or hyphenation inside the brackets, so
      # "[human authorized merge]" does not slip through. The brackets are
      # required: a question like "has the human authorized merge yet?" is a
      # follow-up, not a forged authorization.
      #
      # The marker is text anyone can type, so this is not what makes a merge
      # authorized — the HumanMessage the Merge button writes is
      # (Sessions::AuthorizeMerge). It keeps the voice assistant from sending
      # something that reads like one.
      # NFKC first, so fullwidth brackets and letters fold to ASCII; any dash,
      # space or zero-width character may separate the words.
      MERGE_MARKER_PATTERN = /\[[\p{Zs}\s\u200B-\u200D]*human[\p{Zs}\p{Pd}\s_\u200B-\u200D]*authori[sz]ed[\p{Zs}\p{Pd}\s_\u200B-\u200D]*merge[\p{Zs}\s\u200B-\u200D]*\]/i

      def self.carries_merge_marker?(text)
        MERGE_MARKER_PATTERN.match?(text.to_s.unicode_normalize(:nfkc))
      end

      # Sliced rather than trusted to the schema: none of these schemas sets
      # `additionalProperties: false`, and the inherited bodies read `force`,
      # `goal`, `sync` and `acting_session_id` straight from the arguments.
      def call(args)
        super(args.slice(*ACCEPTED_ARGUMENTS))
      end

      private

      def allowed_actions
        ACTIONS
      end

      def follow_up(session, args)
        raise ToolError, REFUSED_MERGE if self.class.carries_merge_marker?(args["prompt"])

        super
      end

      def mcp_surface_name
        "Live Mode assistant"
      end
    end
  end
end
