# frozen_string_literal: true

module Mcp
  module Tools
    # The action_session a session gets pointed at *itself* (the self_session
    # tool group). Same tool name and the same action bodies as ActionSession —
    # only the self-management subset is exposed, so a session cannot drive other
    # sessions' lifecycles through the server injected into it.
    class SelfSessionActionSession < ActionSession
      tool_name "action_session"

      # `message_parent` is on this surface and NOT on the full one, which is the
      # only action of which that is true. It is not a self-management action
      # that happens to be safe here — it is only definable here: it takes no
      # target, because the target is whatever `parent_session_id` says, and a
      # caller that could name the target would be holding a general
      # session-to-session messaging primitive instead. The full surface already
      # has that, spelled `follow_up`.
      ACTIONS = %w[update_notes update_title set_heartbeat pause_into_spot_queue message_parent archive].freeze

      SELF_ACTION_DESC = 'Action to perform: "update_notes", "update_title", "set_heartbeat", "pause_into_spot_queue", "message_parent", "archive"'

      SELF_QUEUE_PROMPT_DESC = 'Optional for "pause_into_spot_queue": what you want to be resumed with when the queue reaches you, in place of the default nudge. Write it to your future self — you will read it cold, with no memory of this turn beyond the transcript.'

      SELF_FORCE_DESC = 'Optional for "archive". Archiving discards any message still queued for this session — nothing delivers a queued message once the session is in the trash — so an archive over a non-empty queue is refused by default, and the error names what would be lost. Leave this alone in almost every case: a message sitting in the queue arrived while you were working and you have not seen it, so the right move is to NOT archive, end your turn, and let it be delivered as your next turn — archiving after that succeeds because the queue is empty. Set it to true ONLY when you have read the message in the error and are deliberately throwing it away.'
      SELF_ACTING_SESSION_ID_DESC = 'Optional for "archive": your own session ID, recorded as provenance on the archived session\'s timeline. Set it when you archive yourself, so the line reads as a self-archive rather than as an undeclared caller — that distinction is what lets a human later tell a session that finished its work from one that was archived out from under it by something else.'

      SELF_MESSAGE_DESC = 'Required for "message_parent": what you are telling the session that started you. Write it to another agent, not to a human: what you were asked to do, the specific thing that stopped you, and what would unblock it — the agent root you think owns the work, or the MCP server / credential / privilege you were not given. It is delivered as that session\'s next prompt with your session ID and this reason attached, so do not repeat them.'

      SELF_MESSAGE_REASON_DESC = 'Required for "message_parent": why you are reporting back. "wrong_scope" — the work belongs to a different agent root than the one you are running under. "missing_tools" — you were not given an MCP server, credential, or privilege the work needs. "other" — a real reason that is neither of those; say what it is in "message". Pick the one that is true rather than the closest fit, because a parent branches on this.'

      SELF_MESSAGE_FORCE_IMMEDIATE_DESC = 'Optional for "message_parent". By default a running parent takes your report on its queue and reads it when its current turn ends, which is usually right: it is most likely mid-delegation, and killing that turn costs the other work in flight. Set this to true only when the news cannot keep — when the parent is actively spending effort on something your report makes pointless. It terminates the parent\'s in-flight turn; the parent then resumes the same conversation with your report as its next turn.'

      SELF_UNARCHIVE_PARENT_DESC = 'Optional for "message_parent". An archived parent is refused by default, because nothing delivers a message to a session in the trash and sending it would throw it away silently. Set this to true to bring that session back out of the trash and deliver to it. Do that when the work you were given still has to happen and only your parent can re-route it — not to file a note, because it re-clones the repository and interrupts a session that considered its work finished.'

      description <<~DESC
        Perform a self-management action on a session.

        **Actions (limited to self-management):**
        - **update_notes**: Update the notes on a session (requires "session_notes")
        - **update_title**: Update the title of a session (requires "title")
        - **set_heartbeat**: Toggle this session's own heartbeat and/or set its interval (provide "enabled" and/or "interval_seconds"). When the heartbeat is enabled and this session sits in needs_input, a recurring nudge prompts it to keep working toward its goal. If you are genuinely blocked or done, set "enabled" to false to stop the nudges.
        - **message_parent**: Send a message to the session that started this one (requires "message" and "reason"; optional "force_immediate", "unarchive_parent"). You name no target — Zimmer resolves your parent itself, and there is no way to message any other session from here. Reach for it when you were handed a goal you cannot accomplish because of what you ARE rather than what you did: the work belongs to a different agent root ("wrong_scope"), or you were not given an MCP server, credential, or privilege it needs ("missing_tools"). Your parent is the session that chose your scope and your tools, so it is the one that can fix either — tell it what went wrong and what would unblock it, rather than filing an issue or parking in needs_input for a human. A running parent takes the report on its queue and reads it when its turn ends; a parent asleep or waiting takes it now. An archived or failed parent is refused, with the error naming what to do instead.
        - **pause_into_spot_queue**: Put yourself to sleep in the spot queue instead of at a wall-clock time. Use it in place of `wake_me_up_later` whenever the honest answer to "when should I come back" is "whenever there is quota headroom for me" rather than a time you would be inventing — waiting on nothing in particular, or on work that is not yours and has no deadline. You go dormant in "waiting" with NO wake-up trigger, and Zimmer resumes you when a Claude Code account is under both quota targets and a session slot is free, highest precedence first. It also cancels any one-time wake you had armed, and makes this session "spot" if it was "priority" — a priority session cannot sit in the queue. This is NOT the tool for waiting on a specific event or a deadline: `wake_me_up_later` and `wake_me_up_when_session_changes_state` are, and a session parked here is behind however much of the queue outranks it. End your turn after calling it.
        - **archive**: Archive a session (marks as completed). Refused when a message is still queued for the session — archiving discards it, and nothing delivers a queued message once the session is in the trash. The refusal is almost always right: a message that arrived while you were working is one you have not seen, so end your turn instead and it is delivered as your next turn, after which archiving succeeds. Set "force" to true only when you have read the message and are deliberately throwing it away.

        **Use cases:**
        - Update session notes to record progress or context
        - Set a meaningful session title
        - Turn off this session's heartbeat when blocked or finished (set_heartbeat with enabled=false)
        - Park yourself in the spot queue when there is nothing to wait FOR, only quota to wait ON
        - Tell the session that started you that it handed you work you cannot do — the wrong agent root, or a missing MCP server or credential (message_parent)
        - Archive the session when work is complete

        **Reporting back to your parent:**
        - A goal you cannot accomplish because of your scope or your tools is your PARENT's problem to fix, not a GitHub issue and not a question for a human. `message_parent` is the route: it is the only way a child can reach the session above it, and without it your final message reaches your parent only if it happens to be reading you
        - Say what would unblock it — the agent root you think owns the work, or the specific server or credential you needed. Your parent chose both, so it can change both
        - The message goes through the same queue a human follow-up does, so it cannot be accepted and then silently lost: your parent cannot archive over an unread report
        - Then decide your own ending on its merits. Reporting to your parent is what lets you archive instead of parking in `needs_input`: the first sanctioned reason for parking is lacking the scope or tools to finish AND having no parent to report back to AND being unable to spawn a session that has them

        **Archive guidelines:**
        - Self-archival is how a session signals it ran to completion, so archiving is the normal ending — not something that needs a specific instruction to permit it
        - Sessions in `needs_input` appear on the user's homepage as their action queue, so staying there is a claim on a person's attention. Make it only for one of the four sanctioned reasons in the Session Lifecycle Management section of your system prompt: you lacked the scope or tools to finish, have no parent to report back to, and cannot spawn a session that does; you are holding a PR whose merge disposition is unsettled; a human invoked this session to explore something or answer a question; or, rarely, you hit an ambiguity too dangerous and too irreversible to guess at
        - "The user should read this" is not one of them. Put it in your final message, or in a Slack channel if the outcome is a read-only FYI and you have a Slack server, and archive — an archived session's transcript stays readable
        - A session that opened a PR is the exception to the timing: it holds that PR rather than ending. How it holds is the `open-pr` skill's terminal steps — asleep in `waiting` on a bounded self-wake while the merge gate is still rating the PR, since that is a machine wait, and at rest in `needs_input` once the gate *holds* it, the `ready to merge` label comes off, the wake budget is spent, or the PR state cannot be read. Zimmer's pull-request poller reaches unarchived sessions only, and it delivers a message on the open → merged transition — that message is the signal to archive. A PR a merge gate holds sends none until a human merges it, which is how the session comes to rest in the queue for that human. If Zimmer recorded no PR URL for the session, no message can ever arrive — report the URL and archive rather than waiting
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
          message: { type: "string", description: SELF_MESSAGE_DESC },
          reason: { type: "string", enum: Sessions::MessageParent::REASONS.keys, description: SELF_MESSAGE_REASON_DESC },
          force_immediate: { type: "boolean", description: SELF_MESSAGE_FORCE_IMMEDIATE_DESC },
          unarchive_parent: { type: "boolean", description: SELF_UNARCHIVE_PARENT_DESC },
          acting_session_id: { type: [ "number", "string" ], description: SELF_ACTING_SESSION_ID_DESC }
        },
        required: [ "session_id", "action" ]
      })

      private

      def allowed_actions
        ACTIONS
      end

      # `message_parent` is dispatched here rather than in ActionSession's case
      # statement because it exists only here. Everything else on this surface is
      # a narrowing of the full one and shares its single action body; this one
      # would be a new capability on the full surface, and the capability it would
      # be there ("make some other session message its parent") is not one
      # anybody asked for.
      def dispatch(action, args)
        return message_parent(args) if action == "message_parent"

        super
      end

      # Report back to the session that started this one.
      #
      # The target is never an argument. `session_id` names the REPORTER — it is
      # required by this schema like every other action here, and
      # Sessions::MessageParent reads `parent_session_id` from there. A caller
      # that could name the parent would hold a general session-to-session
      # messaging primitive, which is exactly what this surface exists not to
      # hand out.
      def message_parent(args)
        child = requester_session(args)
        enforce_self_report!(child)

        result = Sessions::MessageParent.call(
          child: child,
          message: args["message"].to_s,
          reason: args["reason"].to_s,
          force_immediate: boolean(args["force_immediate"]),
          unarchive_parent: boolean(args["unarchive_parent"]),
          source: "mcp:action_session.message_parent"
        )

        raise ToolError, result.error unless result.success?

        message_parent_result(child, result)
      end

      # The one place this surface DOES enforce its aim, and the exception is
      # narrow on purpose. Everywhere else, acting on another session's id is a
      # lifecycle action whose effect is visible on that session and attributable
      # to a declared actor. Here the effect lands on a THIRD session — the
      # target's parent — in a message that speaks in the target's name. The
      # connection knows which session it was written for, so where that is known
      # it is worth checking; a connection that carries no session identity (a
      # human client on `?tool_groups=self_session`) is unchanged, and the REST
      # endpoint cannot check at all. See docs/limitations.
      def enforce_self_report!(child)
        return if context.self_session_id.blank?
        return if context.self_session_id == child.id

        raise ToolError, "\"message_parent\" reports on behalf of the session making the call, and this MCP " \
                         "connection belongs to session ##{context.self_session_id} — it cannot send session " \
                         "##{child.id}'s report to session ##{child.id}'s parent. Pass \"session_id\": " \
                         "#{context.self_session_id}, your own. To message another session directly, use the " \
                         "full session tool surface."
      end

      def message_parent_result(child, result)
        parent = result.parent
        headline = case result.delivery
        when :queued then "queued for your parent — it will read it when its current turn ends"
        when :interrupted then "delivered to your parent immediately, ending the turn it was in"
        else "delivered to your parent now"
        end

        lines = [
          "## Report Sent to Parent Session",
          "",
          "- **Parent Session ID:** #{parent.id}",
          "- **Title:** #{parent.title}",
          "- **Parent Status:** #{parent.status}",
          "- **Delivery:** #{headline}",
          "- **Reported by:** session ##{child.id}",
          "- **Link:** #{session_url(parent)}"
        ]
        lines << "- **Note:** that session was archived and has been restored from the trash to receive this." if result.unarchived
        lines.concat(EnqueuedMessageSections.queue_depth_lines(parent, queued_message: result.enqueued_message))
        lines << ""
        lines << "Nothing else will chase this. If the reply matters to what you do next, wait for it " \
                 "(`wake_me_up_later`, or `wake_me_up_when_session_changes_state` on ##{parent.id}) rather than " \
                 "ending your turn on the assumption that it arrived."
        lines.join("\n")
      end

      # The narrowed schema does not advertise `halt`, and this is what makes
      # that a refusal rather than a suggestion. The action body is inherited
      # whole, reads `args["halt"]` directly, and no schema here sets
      # `additionalProperties: false` — so without this a session could pass the
      # flag anyway and terminate the very process waiting for this reply.
      def pause_into_spot_queue(session, args)
        super(session, args.except("halt"))
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
