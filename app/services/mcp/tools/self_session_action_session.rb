# frozen_string_literal: true

module Mcp
  module Tools
    # The action_session a session gets pointed at *itself* (the self_session
    # tool group). Same tool name and the same action bodies as ActionSession —
    # only the self-management subset is exposed, so a session cannot drive other
    # sessions' lifecycles through the server injected into it.
    class SelfSessionActionSession < ActionSession
      tool_name "action_session"

      ACTIONS = %w[update_notes update_title set_heartbeat pause_into_spot_queue archive].freeze

      SELF_ACTION_DESC = 'Action to perform: "update_notes", "update_title", "set_heartbeat", "pause_into_spot_queue", "archive"'

      SELF_QUEUE_PROMPT_DESC = 'Optional for "pause_into_spot_queue": what you want to be resumed with when the queue reaches you, in place of the default nudge. Write it to your future self — you will read it cold, with no memory of this turn beyond the transcript.'

      SELF_FORCE_DESC = 'Optional for "archive". Archiving discards any message still queued for this session — nothing delivers a queued message once the session is in the trash — so an archive over a non-empty queue is refused by default, and the error names what would be lost. Leave this alone in almost every case: a message sitting in the queue arrived while you were working and you have not seen it, so the right move is to NOT archive, end your turn, and let it be delivered as your next turn — archiving after that succeeds because the queue is empty. Set it to true ONLY when you have read the message in the error and are deliberately throwing it away.'
      SELF_ACTING_SESSION_ID_DESC = 'Optional for "archive": your own session ID, recorded as provenance on the archived session\'s timeline. Set it when you archive yourself, so the line reads as a self-archive rather than as an undeclared caller — that distinction is what lets a human later tell a session that finished its work from one that was archived out from under it by something else.'

      description <<~DESC
        Perform a self-management action on a session.

        **Actions (limited to self-management):**
        - **update_notes**: Update the notes on a session (requires "session_notes")
        - **update_title**: Update the title of a session (requires "title")
        - **set_heartbeat**: Toggle this session's own heartbeat and/or set its interval (provide "enabled" and/or "interval_seconds"). When the heartbeat is enabled and this session sits in needs_input, a recurring nudge prompts it to keep working toward its goal. If you are genuinely blocked or done, set "enabled" to false to stop the nudges.
        - **pause_into_spot_queue**: Put yourself to sleep in the spot queue instead of at a wall-clock time. Use it in place of `wake_me_up_later` whenever the honest answer to "when should I come back" is "whenever there is quota headroom for me" rather than a time you would be inventing — waiting on nothing in particular, or on work that is not yours and has no deadline. You go dormant in "waiting" with NO wake-up trigger, and Zimmer resumes you when a Claude Code account is under both quota targets and a session slot is free, highest precedence first. It also cancels any one-time wake you had armed, and makes this session "spot" if it was "priority" — a priority session cannot sit in the queue. This is NOT the tool for waiting on a specific event or a deadline: `wake_me_up_later` and `wake_me_up_when_session_changes_state` are, and a session parked here is behind however much of the queue outranks it. End your turn after calling it.
        - **archive**: Archive a session (marks as completed). Refused when a message is still queued for the session — archiving discards it, and nothing delivers a queued message once the session is in the trash. The refusal is almost always right: a message that arrived while you were working is one you have not seen, so end your turn instead and it is delivered as your next turn, after which archiving succeeds. Set "force" to true only when you have read the message and are deliberately throwing it away.

        **Use cases:**
        - Update session notes to record progress or context
        - Set a meaningful session title
        - Turn off this session's heartbeat when blocked or finished (set_heartbeat with enabled=false)
        - Park yourself in the spot queue when there is nothing to wait FOR, only quota to wait ON
        - Archive the session when work is complete

        **Archive guidelines:**
        - Self-archival is how a session signals it ran to completion, so archiving is the normal ending — not something that needs a specific instruction to permit it
        - Sessions in `needs_input` appear on the user's homepage as their action queue, so staying there is a claim on a person's attention. Make it only for one of the four sanctioned reasons in the Session Lifecycle Management section of your system prompt: you lacked the scope or tools to finish and have no parent to report back to; you are holding a PR whose merge disposition is unsettled; a human invoked this session to explore something or answer a question; or, rarely, you hit an ambiguity too dangerous and too irreversible to guess at
        - "The user should read this" is not one of them. Put it in your final message, or in a Slack channel if the outcome is a read-only FYI and you have a Slack server, and archive — an archived session's transcript stays readable
        - A session that opened a PR is the exception to the timing: stay in `needs_input` until that PR merges. Zimmer's pull-request poller reaches unarchived sessions only, and it delivers a message on the open → merged transition — that message is the signal to archive. A PR a merge gate holds sends none until a human merges it, which is how the session stays in the queue for that human. If Zimmer recorded no PR URL for the session, no message can ever arrive — report the URL and archive rather than waiting
        - Anything you noticed but could not fix belongs in a GitHub issue, not in a parked session. File it, then archive
      DESC

      input_schema({
        type: "object",
        properties: {
          session_id: {
            oneOf: [ { type: "string" }, { type: "number" } ],
            description: SESSION_ID_DESC
          },
          action: { type: "string", enum: ACTIONS, description: SELF_ACTION_DESC },
          session_notes: { type: "string", description: SESSION_NOTES_DESC },
          title: { type: "string", description: TITLE_DESC },
          enabled: { type: "boolean", description: ENABLED_DESC },
          interval_seconds: { type: "number", description: INTERVAL_SECONDS_DESC },
          prompt: { type: "string", description: SELF_QUEUE_PROMPT_DESC },
          # Carried on this narrowed schema deliberately. A session archiving
          # itself is the caller that meets the queued-message refusal most, and
          # without `force` here it would be the one caller with no way past it.
          force: { type: "boolean", description: SELF_FORCE_DESC },
          acting_session_id: { type: [ "number", "string" ], description: SELF_ACTING_SESSION_ID_DESC }
        },
        required: [ "session_id", "action" ]
      })

      private

      def allowed_actions
        ACTIONS
      end

      # This server is injected into a session and pointed at that session, but
      # nothing enforces the aim: the tool group narrows the *actions*, not the
      # `session_id`. So the surface is named for what it is rather than
      # claiming a self-archive, and `acting_session_id` is what turns "someone
      # on the self-session server" into "this session, archiving itself".
      def mcp_surface_name
        "self-session MCP server"
      end
    end
  end
end
