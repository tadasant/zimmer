# frozen_string_literal: true

require "automated_prompts"
require "path_sanitizer"

module Mcp
  module Tools
    # Mirrors the member actions of Api::V1::SessionsController — follow_up,
    # pause, restart, archive, unarchive, mcp_servers, model, heartbeat, fork,
    # refresh, refresh_all, notes, title, toggle_favorite, bulk_archive — behind
    # one `action` switch, exactly as the decoupled server's action_session did.
    #
    # Mcp::Tools::SelfSessionActionSession subclasses this to expose only the
    # self-management subset; the action bodies below are the single copy.
    class ActionSession < Tool
      include PrecedenceArgument

      tool_name "action_session"

      SESSION_ID_DESC = 'Session ID (numeric) or slug (string). Required for most actions. Not required for "refresh_all" and "bulk_archive".'
      ACTION_DESC = 'Action to perform: "follow_up", "pause", "restart", "start_now", "archive", "unarchive", "change_mcp_servers", "change_model", "change_skills", "change_hooks", "change_plugins", "change_goal", "change_auto_compact_window", "change_scheduling_class", "change_precedence", "pause_into_spot_queue", "change_category", "toggle_push_notifications", "set_heartbeat", "fork", "regenerate_status_summary", "refresh", "refresh_all", "update_notes", "update_title", "toggle_favorite", "set_visibility", "bulk_archive"'

      SCHEDULING_CLASS_DESC = 'Required for "change_scheduling_class" action. "priority" (starts whenever it is ready) or "spot" (starts only while a Claude Code account is under both quota targets and a session slot is free, and then in precedence order). Send null to clear the choice and go back to deriving the class from the session\'s origin. This moves ONE session: use it to release a spot session held behind the quota gate without touching the trigger that spawned it or the policy every other session of its genesis shares. Demoting to "spot" without also passing "precedence" or "place" leaves the session wherever its existing rank puts it, which is usually the bottom — pass one of them when you mean it to be worked on soon, and "place": "top_of_spot" when you mean it to be worked on first.'
      PROMPT_DESC = 'Required for "follow_up" action. The prompt to send to the agent. Not used for other actions.'
      FORCE_DESC = 'Optional for the "archive" and "bulk_archive" actions. Archiving a session discards any message still queued for it — nothing delivers a queued message once the session is in the trash — so an archive over a non-empty queue is refused by default, and the error names what would be lost. Set this to true ONLY when you have read those messages and are deliberately throwing them away. It is not the recommended path: the usual reason a message is sitting in the queue is that it arrived while the session was working and the session has not seen it yet, in which case the right move is to NOT archive, let the turn end, and let the message be delivered as the next turn. On "bulk_archive" it applies to every session in the batch, not one of them.'
      FORCE_IMMEDIATE_DESC = 'Optional for "follow_up" action. When true, interrupts a running session to deliver the prompt immediately instead of queuing it. Set it whenever the prompt would change what the agent should be doing — a correction, a new constraint, a "you are on the wrong track". A queued prompt is not seen until the current turn ends, which can be many minutes of work in a direction you already know is wrong. Interrupting ends the in-flight turn. The agent then resumes the same conversation with your prompt as its next turn, so it keeps the context it had. Leave it off when the prompt is additive and the current turn is worth finishing. Not used for other actions.'
      MCP_SERVERS_DESC = 'Required for "change_mcp_servers" action. Array of MCP server names to set for the session. REPLACES the existing set — this is not a merge, so whatever you pass is the complete final list and every server the session currently has but you did not name is dropped. To add or remove one, read the session\'s current mcp_servers with get_session, copy that list, and edit it — do not write a fresh list from what the change seems to need.'
      MODEL_DESC = 'Required for "change_model" action. The model identifier to use (e.g., "opus", "sonnet", "fable", "gpt-5.6-sol"). Must be valid for the session runtime.'
      SKILLS_DESC = 'Required for "change_skills" action. Array of catalog skill IDs to set for the session (replaces the existing set — this is not a merge). Invalid IDs are rejected. Call get_configs / the skills catalog for valid IDs.'
      HOOKS_DESC = 'Required for "change_hooks" action. Array of catalog hook IDs to set for the session (replaces the existing set — this is not a merge). Invalid IDs are rejected.'
      PLUGINS_DESC = 'Required for "change_plugins" action. Array of catalog plugin IDs to set for the session (replaces the existing set — this is not a merge). Invalid IDs are rejected.'
      GOAL_DESC = 'Required for "change_goal" action. The goal text to set for the session; pass an empty string to clear the goal. Also optional for "follow_up": a non-blank goal is applied to the session along with the prompt, while a blank or omitted one leaves the session\'s current goal alone (use "change_goal" to clear it).'
      AUTO_COMPACT_WINDOW_DESC = 'Required for "change_auto_compact_window" action. The context (auto-compact) window in tokens, a positive integer. Applies on the next turn or restart, not the currently running process.'
      CATEGORY_ID_DESC = 'Required for "change_category" action (the key must be present). The organizational category ID to assign; pass null to move the session back to Uncategorized.'
      ENABLED_DESC = 'Optional for "set_heartbeat" action. When true, enables the session heartbeat; when false, disables it. Omit to leave the enabled state unchanged (at least one of "enabled" or "interval_seconds" must be provided).'
      INTERVAL_SECONDS_DESC = 'Optional for "set_heartbeat" action. Heartbeat cadence in seconds (30–86400). Omit to leave the interval unchanged (at least one of "enabled" or "interval_seconds" must be provided).'
      MESSAGE_INDEX_DESC = 'Required for "fork" action. The transcript message index to fork from.'
      SESSION_NOTES_DESC = 'Required for "update_notes" action. The notes text to set on the session.'
      SESSION_IDS_DESC = 'Required for "bulk_archive" action. Array of session IDs to archive.'
      TITLE_DESC = 'Required for "update_title" action. The new title for the session.'
      # The `source` stamped on an uncle edge recorded by follow_up, whichever
      # delivery branch it took — the branch is an implementation detail of
      # "this session followed up that one".
      FOLLOW_UP_EDGE_SOURCE = "mcp:action_session.follow_up"

      ACTING_SESSION_ID_DESC = 'Optional for "follow_up" and "archive". On "archive" it is provenance and nothing else: the archived session\'s timeline names you as the actor, so a human reading it later can tell an agent archiving that session from a human clicking Trash. Set it whenever an agent session drives an archive — including archiving yourself. On "follow_up", if you are an agent session sending this follow-up to ANOTHER session, set this to your own session ID. Zimmer records a lineage edge marking you as a senior ("uncle") of the target session, on the assumption that a session which inspected another and decided to redirect it holds information that session does not. That edge widens the target\'s hierarchy to include yours, so the human messages recorded in your hierarchy become visible to it as context. Omit it if a human is driving this call, or if you are messaging yourself — Zimmer cannot tell who is calling, so an omitted value records no edge, and an undeclared archive is logged as exactly that.'

      VISIBILITY_DESC = 'Required for "set_visibility". One of "visible", "hidden", or "snoozed". Board visibility is a SECOND axis, completely orthogonal to status: it decides whether the session\'s card is on the human\'s dashboard and has no effect on scheduling or execution whatsoever.'

      SNOOZED_UNTIL_DESC = 'Required for "set_visibility" with visibility "snoozed", and ignored otherwise. When the card comes back on the board, as a naive wall-clock ISO-8601 datetime ("2026-09-05T09:00:00") interpreted in "timezone". Must be in the future. The snooze expires on its own — no follow-up call is needed, and nothing is written to the session when it does.'

      TIMEZONE_DESC = 'Optional for "set_visibility": the IANA timezone name (e.g. "America/New_York") that "snoozed_until" is expressed in. Defaults to "UTC". Send the wall-clock time the human means plus their zone, rather than converting to UTC yourself.'

      PRECEDENCE_DESC = PrecedenceDocs::ACTION_SESSION

      PLACE_DESC = PrecedenceDocs::PLACE

      HALT_DESC = 'Optional for "pause_into_spot_queue": stop the target session\'s turn where it stands instead of letting it finish. Terminates the agent process — work already written to disk survives, the tool call in flight does not. Do NOT set it on your own session: you would be killing the process that is waiting for this call to return.'

      ACTIONS = %w[
        follow_up
        pause
        pause_into_spot_queue
        restart
        start_now
        archive
        unarchive
        change_mcp_servers
        change_model
        change_skills
        change_hooks
        change_plugins
        change_goal
        change_auto_compact_window
        change_scheduling_class
        change_precedence
        change_category
        toggle_push_notifications
        set_heartbeat
        fork
        regenerate_status_summary
        refresh
        refresh_all
        update_notes
        update_title
        toggle_favorite
        set_visibility
        bulk_archive
      ].freeze

      # Every action but the two bulk ones operates on a single session.
      SESSIONLESS_ACTIONS = %w[refresh_all bulk_archive].freeze

      MAX_MCP_SERVERS = 50
      MAX_MCP_SERVER_NAME_LENGTH = 100
      MAX_CATALOG_SKILLS = 100
      MAX_CATALOG_HOOKS = 100
      MAX_CATALOG_PLUGINS = 50
      MAX_CATALOG_ITEM_ID_LENGTH = 100
      MAX_SESSION_NOTES_LENGTH = 50_000
      REFRESH_ALL_LIMIT = 50

      # Shared spec for the three replace-semantics catalog list fields
      # (skills/hooks/plugins). Each mirrors change_mcp_servers: validate every id
      # against its catalog, persist the whole list (replace, not merge), and log
      # the delta. Config regeneration is deliberately deferred to the next
      # prepare/unarchive — the same as change_mcp_servers — so an archived session
      # picks the new set up when it is next prepared.
      CATALOG_LIST_FIELDS = {
        "change_skills" => { attribute: :catalog_skills, param: "skills", label: "Skills", max: MAX_CATALOG_SKILLS, config: "SkillsConfig" },
        "change_hooks" => { attribute: :catalog_hooks, param: "hooks", label: "Hooks", max: MAX_CATALOG_HOOKS, config: "HooksConfig" },
        "change_plugins" => { attribute: :catalog_plugins, param: "plugins", label: "Plugins", max: MAX_CATALOG_PLUGINS, config: "PluginsConfig" }
      }.freeze

      description <<~DESC
        Perform an action on an agent session.

        **Actions:**
        - **follow_up**: Send a follow-up prompt to a session (requires "prompt"; optional "force_immediate" to interrupt a running session — see "Interrupting vs queuing" below, and reach for it whenever the prompt would redirect the agent). Without "force_immediate", uses smart routing: sends immediately if idle, auto-queues if running. Optionally takes "goal" to give the session a new definition of done along with the prompt; a blank or omitted goal preserves the session's current one.
        - **pause**: Pause a running session, transitioning it to idle "needs_input" status
        - **pause_into_spot_queue**: Put this session to sleep in the spot queue instead of at a wall-clock time — the counterpart of `wake_me_up_later` when there is no time worth naming. The session goes dormant in "waiting" with NO wake-up trigger and no time attached, and resumes when the spot scheduler reaches it: a Claude Code account under both quota targets, a free session slot, highest precedence first. Any unfired one-time wake this session had is cancelled, since it was replaced by this. A session that resolves to "priority" is set to "spot" (a priority session cannot sit in the queue) — reverse it with `change_scheduling_class`, which resumes it on the next sweep. Optionally takes "prompt": what the session should be resumed with, in place of the default recovery nudge. A running session sleeps when its current turn ends, not mid-turn — pass "halt": true to stop the turn where it stands instead. Only use "halt" on a session that is NOT you: it terminates the agent process, so a session halting itself never gets a reply to this call. Any message still queued for the session waits with it, and unlike a timed pause nothing bounds how long — drain the queue first if that matters. Use this instead of a made-up wake time when the answer to "when should this come back" is "whenever there is quota headroom for it".
        - **restart**: Restart an idle or failed session without providing new input
        - **start_now**: Take a waiting session's queued turn immediately instead of when the scheduler gets round to it — the tool half of the Ranked view's ⋮ menu entry. Reach for it when one session should not wait out the gate's deferred re-check, which can be up to an hour: this releases that one session without touching its scheduling class, its precedence, or anything else. A session with nothing queued has no turn to bring forward and is refused, with the error naming "follow_up" or "restart" instead; so is one asleep on a wake-up it has not reached, because a pause outranks precedence and it wakes on its own schedule.
        - **archive**: Archive a session (marks as completed). Refused when messages are still queued for the session, since archiving discards them — the error names them, and "force" overrides it deliberately.
        - **unarchive**: Restore an archived session to idle "needs_input" status
        - **change_mcp_servers**: Update the MCP servers for a session (requires "mcp_servers" parameter; replaces the set)
        - **change_model**: Update the model for a session (requires "model" parameter, e.g., "opus", "sonnet", "fable", "gpt-5.6-sol")
        - **change_skills**: Update the catalog skills for a session (requires "skills" parameter; replaces the set). Invalid skill IDs are rejected.
        - **change_hooks**: Update the catalog hooks for a session (requires "hooks" parameter; replaces the set). Invalid hook IDs are rejected.
        - **change_plugins**: Update the catalog plugins for a session (requires "plugins" parameter; replaces the set). Invalid plugin IDs are rejected.
        - **change_goal**: Update the goal for a session (requires "goal" parameter; empty string clears it)
        - **change_auto_compact_window**: Update the context (auto-compact) window in tokens (requires "auto_compact_window"; applies on the next turn/restart)
        - **change_scheduling_class**: Move this one session between "spot" and "priority" (requires "scheduling_class"; null clears it back to derived). Optionally takes "precedence" (an absolute rank) or "place" (a symbolic one, e.g. "top_of_spot") to place it in the spot queue in the same call — which is what a demotion usually wants, since a demoted session otherwise keeps whatever rank it already had. "place": "top_of_spot" is what the web UI's Demote to spot button does. It applies whichever class you are moving the session to — precedence is carried on a priority session too, and is what a later demotion lands on.
        - **change_precedence**: Set where this session sits in the spot queue (requires "precedence" or "place"). Higher is handled sooner, on an absolute scale — 100000 comes before 50. Pass "place": "top_of_spot" instead of a number to put the session at the head of the queue, worked out server-side against the live queue.
        - **change_category**: Assign the session's organizational category (requires "category_id"; null moves it to Uncategorized)
        - **toggle_push_notifications**: Toggle push notifications on a session
        - **set_heartbeat**: Toggle a session's heartbeat and/or set its interval (provide "enabled" and/or "interval_seconds"). When enabled and the session sits in needs_input, a recurring nudge prompts it to keep working toward its goal; set "enabled" to false to stop the nudges.
        - **fork**: Fork a session from a specific transcript message (requires "message_index")
        - **regenerate_status_summary**: Rewrite the session's Status blurb — the 2-3 sentence "where things stand" shown at the top of its detail page, and returned by get_session. Forced: it regenerates even when Zimmer considers the cached blurb current. Zimmer writes this automatically when a session comes to rest (needs_input or failed) and at no other time, so reach for this only when you need a summary of a session that has NOT changed status since its last one — never in a loop, and never to poll: it forks the session and spends a full agent turn. Errors, rather than queuing work that cannot run, in the two cases that cannot produce a summary at all: a session with no transcript, or one that is itself a summary fork. An archived session is a normal candidate, however long ago it was archived — the fork answers from the session's conversation, so Zimmer having reclaimed the working clone does not stop it.
        - **refresh**: Refresh a single session's status from the execution provider
        - **refresh_all**: Refresh all active sessions (no session_id needed)
        - **update_notes**: Update the notes on a session (requires "session_notes")
        - **update_title**: Update the title of a session (requires "title")
        - **toggle_favorite**: Toggle favorite status on a session
        - **set_visibility**: Set a session's BOARD VISIBILITY — whether its card is on the human's dashboard (requires "visibility": "visible", "hidden" or "snoozed"; "snoozed" also requires "snoozed_until", with an optional "timezone"). **This is a visual-organization device and nothing else.** It does not start, stop, pause, sleep, wake, reorder or reschedule anything, no scheduler reads it, and a snoozed session runs exactly when it would have run had nobody touched it. Use it when a human asks you to tidy their board; never use it to try to stop or defer work — `pause`, `pause_into_spot_queue` and `change_precedence` are the actions that do that. A snooze ends by itself: once "snoozed_until" passes the session is back on the board with nothing having been written to it.
        - **bulk_archive**: Archive multiple sessions at once (requires "session_ids", no session_id needed). Sessions with queued messages are reported as errors and left alone unless "force" is set for the batch.

        **Interrupting vs queuing a follow_up.** Interrupting is opt-in, and worth reaching for more often than the default suggests. Send with "force_immediate": true whenever the prompt would redirect the agent: a correction, a constraint it does not know about, information that makes its current approach wrong. An agent twenty minutes into the wrong approach cannot see a queued message until it finishes, so the message that would have saved the work arrives after the work is wasted. The cost of interrupting is bounded: the in-flight turn is terminated (an uncommitted tool call is lost, files already written stay written) and the agent picks up from the same conversation with your prompt as the next turn. Queue when the prompt only adds to what the agent is already doing.

        **List-valued fields (mcp_servers, skills, hooks, plugins) replace, they never merge.** The array you pass becomes the whole set, so it must be the complete final list: anything the session currently holds and you did not name is dropped. Read the session's current list with get_session, copy it, and add to or subtract from that — writing a fresh list from what the change seems to need is how a session silently loses a server or skill it was relying on. These changes persist to the session and take effect the next time the session's runtime config is prepared (e.g. on the next turn or unarchive), matching how change_mcp_servers behaves — they do not hot-reconfigure a currently running process.

        **Use cases:**
        - Provide additional instructions to an agent
        - Control session lifecycle (pause, restart, fork, refresh)
        - Organize sessions (archive, unarchive, bulk_archive, toggle_favorite, set_visibility, update_notes, update_title, change_category, toggle_push_notifications)
        - Tidy a human's dashboard without touching their work (set_visibility)
        - Reconfigure session capabilities (MCP servers, skills, hooks, plugins, model, context window)
        - Set or clear a session's goal
      DESC

      input_schema({
        type: "object",
        properties: {
          session_id: {
            oneOf: [ { type: "string" }, { type: "number" } ],
            description: SESSION_ID_DESC
          },
          action: { type: "string", enum: ACTIONS, description: ACTION_DESC },
          prompt: { type: "string", description: PROMPT_DESC },
          force_immediate: { type: "boolean", description: FORCE_IMMEDIATE_DESC },
          force: { type: "boolean", description: FORCE_DESC },
          halt: { type: "boolean", description: HALT_DESC },
          mcp_servers: { type: "array", items: { type: "string" }, description: MCP_SERVERS_DESC },
          model: { type: "string", description: MODEL_DESC },
          skills: { type: "array", items: { type: "string" }, description: SKILLS_DESC },
          hooks: { type: "array", items: { type: "string" }, description: HOOKS_DESC },
          plugins: { type: "array", items: { type: "string" }, description: PLUGINS_DESC },
          goal: { type: "string", description: GOAL_DESC },
          auto_compact_window: { type: "integer", description: AUTO_COMPACT_WINDOW_DESC },
          scheduling_class: {
            type: [ "string", "null" ],
            enum: SessionGenesis::CLASSES + [ nil ],
            description: SCHEDULING_CLASS_DESC
          },
          precedence: { type: "integer", description: PRECEDENCE_DESC },
          place: { type: "string", enum: SessionPrecedence::PLACES, description: PLACE_DESC },
          category_id: { type: [ "number", "null" ], description: CATEGORY_ID_DESC },
          enabled: { type: "boolean", description: ENABLED_DESC },
          interval_seconds: { type: "number", description: INTERVAL_SECONDS_DESC },
          message_index: { type: "number", description: MESSAGE_INDEX_DESC },
          session_notes: { type: "string", description: SESSION_NOTES_DESC },
          session_ids: { type: "array", items: { type: "number" }, description: SESSION_IDS_DESC },
          title: { type: "string", description: TITLE_DESC },
          visibility: { type: "string", enum: SessionVisibility::VISIBILITIES, description: VISIBILITY_DESC },
          snoozed_until: { type: "string", description: SNOOZED_UNTIL_DESC },
          timezone: { type: "string", description: TIMEZONE_DESC },
          acting_session_id: { type: [ "number", "string" ], description: ACTING_SESSION_ID_DESC }
        },
        required: [ "action" ]
      })

      def call(args)
        action = require_arg(args, :action).to_s

        unless allowed_actions.include?(action)
          raise ToolError, "Unknown action \"#{action}\". Allowed actions: #{allowed_actions.join(', ')}"
        end

        if requires_session_id?(action) && args["session_id"].blank?
          raise ToolError, "The \"session_id\" parameter is required for the \"#{action}\" action."
        end

        dispatch(action, args)
      end

      private

      # The action list this variant exposes. SelfSessionActionSession narrows it.
      def allowed_actions
        ACTIONS
      end

      def requires_session_id?(action)
        !SESSIONLESS_ACTIONS.include?(action)
      end

      def dispatch(action, args)
        case action
        when "follow_up" then follow_up(find_session(args["session_id"]), args)
        when "pause" then pause(find_session(args["session_id"]))
        when "pause_into_spot_queue" then pause_into_spot_queue(find_session(args["session_id"]), args)
        when "restart" then restart(find_session(args["session_id"]))
        when "start_now" then start_now(find_session(args["session_id"]))
        when "archive" then archive(find_session(args["session_id"]), args)
        when "unarchive" then unarchive(find_session(args["session_id"]))
        when "change_mcp_servers" then change_mcp_servers(find_session(args["session_id"]), args)
        when "change_model" then change_model(find_session(args["session_id"]), args)
        when "change_skills", "change_hooks", "change_plugins" then change_catalog_list(find_session(args["session_id"]), action, args)
        when "change_goal" then change_goal(find_session(args["session_id"]), args)
        when "change_auto_compact_window" then change_auto_compact_window(find_session(args["session_id"]), args)
        when "change_scheduling_class" then change_scheduling_class(find_session(args["session_id"]), args)
        when "change_precedence" then change_precedence(find_session(args["session_id"]), args)
        when "change_category" then change_category(find_session(args["session_id"]), args)
        when "toggle_push_notifications" then toggle_push_notifications(find_session(args["session_id"]))
        when "set_heartbeat" then set_heartbeat(find_session(args["session_id"]), args)
        when "fork" then fork_session(find_session(args["session_id"]), args)
        when "regenerate_status_summary" then regenerate_status_summary(find_session(args["session_id"]))
        when "refresh" then refresh(find_session(args["session_id"]))
        when "refresh_all" then refresh_all
        when "update_notes" then update_notes(find_session(args["session_id"]), args)
        when "update_title" then update_title(find_session(args["session_id"]), args)
        when "toggle_favorite" then toggle_favorite(find_session(args["session_id"]))
        when "set_visibility" then set_visibility(find_session(args["session_id"]), args)
        when "bulk_archive" then bulk_archive(args)
        end
      end

      # --- Actions --------------------------------------------------------------

      def follow_up(session, args)
        prompt = args["prompt"].to_s.strip
        raise ToolError, "The \"prompt\" parameter is required for the \"follow_up\" action." if prompt.blank?

        if prompt.length > Session::PROMPT_MAX_LENGTH
          raise ToolError, "prompt is too long (maximum #{Session::PROMPT_MAX_LENGTH} characters)"
        end

        # Rejected before any branch mutates state, so an over-long goal fails the
        # same way whether the message is queued, interrupted in, or sent directly.
        goal = args["goal"].to_s.strip.presence
        if goal && goal.length > Session::GOAL_MAX_LENGTH
          raise ToolError, "goal is too long (maximum #{Session::GOAL_MAX_LENGTH} characters)"
        end

        # The edge is recorded only after the message has actually landed — every
        # branch below raises rather than returning on failure, so an edge is
        # never written for a delivery that did not happen.
        #
        # The direct branch is the exception, and records inside its own
        # transaction instead: it enqueues the job that will build the very next
        # prompt, and a job that starts before the edge is visible would render a
        # hierarchy missing exactly the human context the edge exists to carry.
        if boolean(args["force_immediate"])
          force_immediate_follow_up(session, prompt, goal).tap do
            record_uncle_edge(session, args, FOLLOW_UP_EDGE_SOURCE)
          end
        elsif session.running?
          queue_follow_up(session, prompt, goal).tap do
            record_uncle_edge(session, args, FOLLOW_UP_EDGE_SOURCE)
          end
        else
          direct_follow_up(session, prompt, goal, args)
        end
      end

      # An idle session takes the prompt directly. This still records an uncle
      # edge: "queue or interrupt" is the shape the rule was described in, but
      # the thing being recorded is one session deciding to redirect another, and
      # a router following up an idle worker is the most common instance of it.
      def direct_follow_up(session, prompt, goal, args)
        unless session.waiting? || session.needs_input?
          raise ToolError, "Session is #{session.status}. Follow-up prompts can only be sent to running, waiting, or needs_input sessions."
        end

        ActiveRecord::Base.transaction do
          # The goal is applied to the session here; the queue and interrupt
          # branches carry it on the EnqueuedMessage and let
          # EnqueuedMessageProcessorService apply it on claim. Same rule
          # everywhere: a non-blank goal overwrites, a blank or absent one leaves
          # the session's goal alone (clearing it is the "change_goal" action).
          if goal && goal != session.goal
            session.update!(prompt: prompt, goal: goal)
            session.logs.create!(content: "Goal updated from follow-up", level: "info")
          else
            session.update!(prompt: prompt)
          end
          session.resume! if session.may_resume?
          # Before the enqueue, and in the same transaction: the job this line
          # creates builds the next prompt, and it must see the edge. Rolling
          # back takes the edge with it, so a failed send still records nothing.
          record_uncle_edge(session, args, FOLLOW_UP_EDGE_SOURCE)
          job = AgentSessionJob.enqueue_with_prompt(session.id, prompt)
          session.update!(running_job_id: job.job_id)
        end

        follow_up_result(session.reload, "Follow-up prompt sent")
      end

      # force_immediate goes through the one race-free interrupt path
      # (Sessions::InterruptService) the web and REST "Send Now" buttons use, so
      # "deliver now, terminating the current turn" cannot diverge across entry points.
      def force_immediate_follow_up(session, prompt, goal)
        unless session.running? || session.waiting? || session.needs_input?
          raise ToolError, "Session is #{session.status}. Follow-up prompts can only be sent to running, waiting, or needs_input sessions."
        end

        enqueued_message = nil
        ActiveRecord::Base.transaction do
          max_position = session.enqueued_messages.maximum(:position) || 0
          enqueued_message = session.enqueued_messages.create!(
            content: prompt,
            goal: goal,
            position: max_position + 1,
            status: "pending"
          )
        end

        result = Sessions::InterruptService.new(
          session: session,
          enqueued_message: enqueued_message,
          actor: "mcp_force_immediate"
        ).call

        unless result.success?
          # All-or-nothing: drop the staged message so it is not silently delivered
          # later as a surprise queued follow-up. A concurrent interrupt may have
          # already claimed it, which is fine.
          begin
            enqueued_message.reload
            enqueued_message.destroy! if enqueued_message.status == "pending"
          rescue ActiveRecord::RecordNotFound
            # already claimed by a concurrent interrupt — nothing to clean up
          end
          raise ToolError, "Cannot send follow-up: #{result.error}"
        end

        follow_up_result(session.reload, "Follow-up prompt sent immediately")
      end

      # A running session queues the message rather than rejecting it, so a caller
      # that raced the end of a turn does not lose the prompt.
      def queue_follow_up(session, prompt, goal)
        max_position = session.enqueued_messages.maximum(:position) || 0
        enqueued_message = session.enqueued_messages.create!(
          content: prompt,
          goal: goal,
          position: max_position + 1,
          status: "pending"
        )
        session.logs.create!(
          content: "Message queued at position #{enqueued_message.position} (session is running)",
          level: "info"
        )

        follow_up_result(
          session.reload,
          "Message queued (session is running). It will be sent when the agent completes its current task.",
          queued_message: enqueued_message
        )
      end

      def pause(session)
        raise ToolError, "Session is not running" unless session.running?

        # Mark as user-initiated so the pause push notification is skipped.
        session.update!(metadata: (session.metadata || {}).merge("paused_by" => "user"))
        session.pause!

        summary("Session Paused", session, status_label: "New Status")
      end

      # Park a session in the spot queue. Everything about
      # the park lives in the service, including which of `needs_input` /
      # `running` / `waiting` it is being applied to; this is the tool surface.
      #
      # `halt` is opt-in, and that default is deliberate rather than timid. This
      # tool's commonest caller is a session parking ITSELF (see
      # SelfSessionActionSession, which does not expose `halt` at all) — and a
      # session that halted itself would terminate the process waiting on this
      # very call, so the default has to stay "sleep when this turn ends". A
      # caller driving somebody else's running session passes `halt` and gets the
      # turn stopped where it stands.
      def pause_into_spot_queue(session, args)
        was = session.priority_class
        was_running = session.running?
        result = Sessions::PauseIntoSpotQueue.call(session: session, prompt: args["prompt"])

        halted = false
        if was_running && args["halt"]
          halted = Sessions::HaltRunningTurn.call(session: session.reload, reason: :pause_into_spot_queue).halted
        end
        session.reload
        pending_sleep = session.metadata&.dig("pending_sleep") == true

        [
          "## Parked In The Spot Queue",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Status:** #{session.status}#{" (sleeps when the current turn ends)" if pending_sleep}#{" — its turn was stopped" if halted}",
          "- **Scheduling class:** #{session.priority_class}#{" (was #{was})" if result.pinned_to_spot}",
          "- **Queue position:** precedence #{session.precedence} (higher is handled sooner)",
          "- **Resumes when:** a Claude Code account is under both quota targets and a session slot " \
          "is free. No wake-up time is set — use \"change_scheduling_class\" with \"priority\" to " \
          "take it out of the queue, or \"change_precedence\" to move it up."
        ].join("\n")
      rescue Sessions::PauseIntoSpotQueue::Error => e
        raise ToolError, e.message
      end

      def restart(session)
        unless session.may_resume?
          raise ToolError, "Session cannot be restarted from current status: #{session.status}"
        end

        refuse_if_paused!(session)

        # No conversation to prompt into — setup never completed (e.g. the git
        # clone failed), or the session never ran at all — so re-run the whole
        # setup pipeline instead of prompting a clone that does not exist.
        return restart_from_scratch(session) if session.needs_restart_from_scratch?

        # Everything past here resumes a conversation, so it needs the id that
        # conversation is filed under. A session with no id but a transcript to
        # lose reaches this point (#needs_restart_from_scratch? deliberately does
        # not claim it), and is refused rather than silently started over.
        raise ToolError, "Session has no session_id" if session.session_id.blank?

        # Must be read before the stale metadata (which carries failure_reason) is cleared.
        use_initial_prompt = session.failed_before_initial_prompt? && session.prompt.present?
        restart_prompt = use_initial_prompt ? session.prompt : AutomatedPrompts::SYSTEM_RECOVERY

        ActiveRecord::Base.transaction do
          cleaned_metadata = (session.metadata || {}).except(*Session::STALE_RETRY_METADATA_KEYS)
          # For pre-prompt failures, drop runtime_started so the restart uses
          # --session-id (with --mcp-config) instead of --resume.
          cleaned_metadata = cleaned_metadata.except("runtime_started") if use_initial_prompt

          session.update!(running_job_id: nil, metadata: cleaned_metadata)
          session.resume!

          AgentSessionJob.enqueue_with_prompt(session.id, restart_prompt)
        end

        summary("Session Restarted", session.reload, status_label: "New Status", message: "Session restarted")
      end

      def restart_from_scratch(session)
        raise ToolError, "No git_root configured for restart from scratch" if session.git_root.blank?

        refuse_if_paused!(session)

        cleaned_metadata = (session.metadata || {}).except(
          *Session::STALE_RETRY_METADATA_KEYS,
          *Session::SETUP_ARTIFACT_KEYS,
          *SpotSessionHold::METADATA_KEYS
        )

        # The replacement turn IS the original first turn — same prompt, new
        # clone, new session_id — so it carries the attachments that turn was
        # created with (Sessions::FirstTurnAttachments, which never raises, so the
        # fleet sweep's restart cannot start failing on an unreadable volume).
        # Replaying all of them is deliberate: this path is reached only when
        # there is no conversation to prompt into — a pre-prompt failure with setup
        # incomplete, or a session that never ran — and a restart from scratch
        # discards the conversation any earlier delivery went to.
        images, files = Sessions::FirstTurnAttachments.for(session)
        carrying = Sessions::FirstTurnAttachments.carrying_clause(images, files)

        ActiveRecord::Base.transaction do
          session.logs.create!(
            content: "Restarting session from scratch: re-running full setup pipeline " \
                     "(git clone, MCP config, process spawn)#{carrying}",
            level: "info"
          )
          session.update!(running_job_id: nil, session_id: nil, metadata: cleaned_metadata)
          session.resume! if session.may_resume?
          AgentSessionJob.enqueue_new_session(session.id, images: images.presence, files: files.presence)
          session.logs.create!(
            content: "Session resumed - status changed to running, full setup will be re-attempted",
            level: "info"
          )
        end

        summary("Session Restarted", session.reload, status_label: "New Status", message: "Session restarted from scratch")
      end

      # A pause outranks every reason an agent has to start this session.
      #
      # `restart` is the start path in the awaken-waiting-sessions skill, which is
      # how the fleet-maintenance session hands out compute after a quota recovery.
      # It works the ranked queue in precedence order, and precedence says nothing
      # about whether a session asked to be left alone — so without this, the wake
      # starts a paused session the moment its rank comes up.
      #
      # Refusing rather than silently no-opping, and refusing HERE rather than
      # further down: `restart` resumes the session before it enqueues anything,
      # and `resume`'s cancel_pending_one_time_wake_triggers callback consumes the
      # pause on the way past. By the time a job could decline, the pause is gone.
      # The error names the next move, because the caller is an agent working a
      # queue and "skip it and take the next one" is exactly what it should do.
      #
      # Deliberately not applied to the web UI's Restart button or to `follow_up`:
      # a person driving one session, or an agent addressing one directly, is
      # taking it over, and consuming the now-moot wake is the documented
      # behaviour. This is about a selector working a list.
      # "Start it now": take a waiting session's next turn immediately instead of
      # when the scheduler gets round to it — the tool half of the Ranked view's
      # ⋮ menu entry. This is what a fleet-maintenance agent working the queue
      # reaches for when it decides one session should not wait out the gate's
      # deferred re-check; `change_scheduling_class` to "priority" does it too,
      # as a side effect of the promotion.
      def start_now(session)
        result = Sessions::StartNow.call(session, actor: "an agent through MCP")
        raise ToolError, result.message if result.refused?

        if result.nothing_queued?
          raise ToolError,
            "#{result.message} There is no turn to bring forward: send it a \"follow_up\" prompt, " \
            "or \"restart\" it if it is stuck."
        end

        summary("Session Starting Now", session.reload, message: result.message)
      end

      def refuse_if_paused!(session)
        return unless session.paused_until_scheduled_time?

        raise ToolError,
          "Session #{session.id} is asleep on a wake-up it has not reached yet (#{session.pending_wake_phrase}). " \
          "A pause outranks precedence and scheduling class, so this session does not start early — " \
          "skip it and take the next candidate. It wakes on its own schedule."
      end

      def archive(session, args)
        unless session.may_archive?
          raise ToolError, "Session cannot be trashed from current status: #{session.status}"
        end

        refuse_archive_over_queued_messages(session, args)

        session.archive_actor = archive_actor_phrase(args)
        session.archive_forced = boolean(args["force"])
        session.archive!
        session.reload

        [
          "## Session Archived",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **New Status:** #{session.status}",
          "- **Archived At:** #{session.archived_at&.iso8601}"
        ].join("\n")
      end

      # Refuse to archive a session that still has messages queued for it,
      # unless the caller explicitly forced it.
      #
      # Archiving is what cancels the delivery: AgentSessionJob's monitoring loop
      # sees `archived?` and terminates the process instead of pausing and
      # calling EnqueuedMessageProcessorService, and
      # Session#strand_pending_enqueued_messages then retires whatever was
      # queued. That records the discard; it does not make it intended.
      #
      # Every state that can archive is covered, `needs_input` and `failed`
      # included. Nothing drains their queues, which makes the discard there
      # certain rather than merely likely — and `force` is what keeps a certain
      # discard from being a trap, so the refusal can apply wherever the loss is
      # real rather than only where it is recoverable.
      def refuse_archive_over_queued_messages(session, args, batch: false)
        return if boolean(args["force"])

        queued = Sessions::ArchiveGuard.pending_messages(session)
        return if queued.empty?

        raise ToolError, Sessions::ArchiveGuard.refusal_message(session, queued, batch: batch)
      end

      def unarchive(session)
        raise ToolError, "Session is not in trash" unless session.archived?

        result = UnarchiveSessionService.call(session: session)
        raise ToolError, "Failed to restore: #{result.error}" unless result.success?

        summary("Session Unarchived", session.reload, status_label: "New Status")
      end

      def change_mcp_servers(session, args)
        if context.restricted?
          raise ToolError, "The \"change_mcp_servers\" action is not allowed when this connection is restricted to " \
                           "specific agent roots. MCP servers are locked to the defaults configured for each allowed agent root."
        end

        unless args["mcp_servers"].is_a?(Array)
          raise ToolError, "The \"mcp_servers\" parameter is required for the \"change_mcp_servers\" action."
        end

        mcp_servers = args["mcp_servers"]
        raise ToolError, "Maximum #{MAX_MCP_SERVERS} MCP servers" if mcp_servers.length > MAX_MCP_SERVERS

        mcp_servers = mcp_servers.reject(&:blank?).map { |s| s.to_s.strip.first(100) }

        invalid = mcp_servers.reject { |name| ServersConfig.exists?(name) }
        raise ToolError, "Invalid MCP servers: #{invalid.join(', ')}" if invalid.any?

        old_servers = session.mcp_servers || []
        # Without this, clearing the list is undone the next time the config is
        # regenerated: McpServerBackfill reads the empty column as an accident
        # and restores the root's defaults. See Session#record_explicit_mcp_servers.
        session.record_explicit_mcp_servers(mcp_servers)
        session.update!(mcp_servers: mcp_servers)

        added = mcp_servers - old_servers
        removed = old_servers - mcp_servers

        # A deliberate removal is not an unexplained loss — forget its status so
        # later config regenerations don't report it as one.
        session.forget_mcp_server_status!(removed)

        changes = []
        changes << "added: #{added.join(', ')}" if added.any?
        changes << "removed: #{removed.join(', ')}" if removed.any?
        session.logs.create!(content: "MCP servers updated via MCP (#{changes.join('; ')})", level: "info") if changes.any?

        [
          "## MCP Servers Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **MCP Servers:** #{format_list(session.mcp_servers)}"
        ].join("\n")
      end

      def change_model(session, args)
        model = args["model"]
        unless model.is_a?(String) && model.present?
          raise ToolError, "The \"model\" parameter is required for the \"change_model\" action."
        end

        model = model.strip.first(100)

        unless ModelCatalog.valid_model?(session.agent_runtime, model)
          allowed = ModelCatalog.model_ids_for(session.agent_runtime)
          raise ToolError, "model #{model.inspect} is not valid for runtime #{session.agent_runtime}. Valid models: #{allowed.join(', ')}"
        end

        old_model = session.config&.dig("model")
        session.update!(config: (session.config || {}).merge("model" => model))
        session.logs.create!(content: "Model updated via MCP (#{old_model} → #{model})", level: "info") if old_model != model

        [
          "## Model Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Model:** #{session.config&.dig('model').presence || '(default)'}"
        ].join("\n")
      end

      # Shared body for change_skills / change_hooks / change_plugins. Mirrors
      # change_mcp_servers: replace-not-merge, reject any id outside the catalog
      # (listing valid options so a rename like `pr` → `open-pr` is easy to fix),
      # persist, and log the delta. The unknown-id rejection is what prevents an
      # invalid value from being persisted and bricking the session on next prepare.
      def change_catalog_list(session, action, args)
        spec = CATALOG_LIST_FIELDS.fetch(action)
        param = spec[:param]

        # Plugins can bundle MCP servers (see Session#derive_mcp_servers_from_plugins),
        # so on a restricted connection they are a bypass of the same agent-root MCP
        # lock change_mcp_servers enforces. Skills and hooks carry no such server
        # expansion, so only plugins inherit the guard.
        if action == "change_plugins" && context.restricted?
          raise ToolError, "The \"change_plugins\" action is not allowed when this connection is restricted to " \
                           "specific agent roots. Plugins can add MCP servers, which are locked to the defaults configured for each allowed agent root."
        end

        unless args[param].is_a?(Array)
          raise ToolError, "The \"#{param}\" parameter is required for the \"#{action}\" action."
        end

        items = args[param]
        raise ToolError, "Maximum #{spec[:max]} #{spec[:label].downcase}" if items.length > spec[:max]

        items = items.reject(&:blank?).map { |s| s.to_s.strip.first(MAX_CATALOG_ITEM_ID_LENGTH) }

        config = spec[:config].constantize
        invalid = items.reject { |id| config.exists?(id) }
        if invalid.any?
          valid = config.all.map(&:id).sort
          raise ToolError, "Invalid #{spec[:label].downcase}: #{invalid.join(', ')}. Valid #{spec[:label].downcase}: #{valid.join(', ')}"
        end

        old_items = session.public_send(spec[:attribute]) || []
        session.update!(spec[:attribute] => items)

        added = items - old_items
        removed = old_items - items
        changes = []
        changes << "added: #{added.join(', ')}" if added.any?
        changes << "removed: #{removed.join(', ')}" if removed.any?
        session.logs.create!(content: "#{spec[:label]} updated via MCP (#{changes.join('; ')})", level: "info") if changes.any?

        [
          "## #{spec[:label]} Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **#{spec[:label]}:** #{format_list(session.public_send(spec[:attribute]))}"
        ].join("\n")
      end

      def change_goal(session, args)
        unless args.key?("goal")
          raise ToolError, "The \"goal\" parameter is required for the \"change_goal\" action."
        end

        goal = args["goal"].to_s.strip.presence
        if goal && goal.length > Session::GOAL_MAX_LENGTH
          raise ToolError, "Goal is too long (maximum #{Session::GOAL_MAX_LENGTH} characters)"
        end

        old_goal = session.goal
        session.update!(goal: goal)

        if old_goal != goal
          change_desc = if goal.blank?
            "Goal cleared"
          elsif old_goal.blank?
            "Goal set"
          else
            "Goal updated"
          end
          session.logs.create!(content: "#{change_desc} via MCP", level: "info")
        end

        [
          "## Goal Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Goal:** #{session.goal.presence || '(none)'}"
        ].join("\n")
      end

      # One session, not a whole genesis. The genesis-wide lever exists for the
      # origins nothing triggers; a trigger's feed moves on the trigger. This is
      # the third case — this session, now — and it is what releases a held spot
      # session without moving anything else.
      def change_scheduling_class(session, args)
        unless args.key?("scheduling_class")
          raise ToolError, "The \"scheduling_class\" parameter is required for the \"change_scheduling_class\" action. " \
                           "Valid: #{SessionGenesis::CLASSES.join(', ')}, or null to derive it."
        end

        raw = args["scheduling_class"]
        klass = raw.nil? ? nil : raw.to_s
        if klass.present? && !SessionGenesis::CLASSES.include?(klass)
          raise ToolError, "Unknown scheduling_class: #{klass}. Valid: #{SessionGenesis::CLASSES.join(', ')}, or null to derive it."
        end

        previous = session.priority_class
        previous_precedence = session.precedence

        attrs = { scheduling_class: klass.presence }
        attrs[:precedence] = resolved_precedence(args, exclude: session) if precedence_named?(args)
        session.update!(attrs)

        if previous != session.priority_class
          session.logs.create!(content: "Scheduling class set via MCP to #{session.priority_class} (was #{previous})", level: "info")
        end
        if previous_precedence != session.precedence
          session.logs.create!(content: "Precedence set via MCP to #{session.precedence} (was #{previous_precedence})", level: "info")
        end

        # Promoting a waiting session starts it, the same as pressing Promote on
        # the Ranked view. The hold this releases is carrying a deferred re-check
        # up to an hour out, and "release this one session" is not a request to
        # keep waiting that long. A session with nothing queued is left alone —
        # `start_now` is the action for a stranded one, and it says so.
        start = if previous != SessionGenesis::PRIORITY &&
                   session.priority_class == SessionGenesis::PRIORITY && session.waiting?
          Sessions::StartNow.call(session, actor: "an agent promoting it through MCP")
        end

        [
          "## Scheduling Class Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Scheduling class:** #{session.priority_class} (was #{previous})",
          "- **Source:** #{session.scheduling_class_source}",
          "- **Precedence:** #{session.precedence}#{" (was #{previous_precedence})" if previous_precedence != session.precedence}",
          ("- **Start:** #{start.message}" if start && !start.nothing_queued?)
        ].compact.join("\n")
      end

      # Where this session sits in the spot queue. Answered for every session,
      # priority included: the value is carried on the row either way, and a
      # priority session that is later demoted lands on the rank it is holding.
      def change_precedence(session, args)
        unless precedence_named?(args)
          raise ToolError, "The \"precedence\" parameter is required for the \"change_precedence\" action. " \
                           "Pass an absolute integer, or \"place\": \"#{SessionPrecedence::PLACE_TOP_OF_SPOT}\" " \
                           "to put this session at the head of the spot queue."
        end

        previous = session.precedence
        session.update!(precedence: resolved_precedence(args, exclude: session))

        if previous != session.precedence
          session.logs.create!(content: "Precedence set via MCP to #{session.precedence} (was #{previous})", level: "info")
        end

        [
          "## Precedence Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Precedence:** #{session.precedence} (was #{previous})",
          "- **Scheduling class:** #{session.priority_class}",
          ("- Note: this session is priority, so precedence does not affect when it starts — " \
           "it applies if the session is later demoted to spot." if session.priority?)
        ].compact.join("\n")
      end

      def change_auto_compact_window(session, args)
        raw = args["auto_compact_window"]
        unless raw.to_s.match?(/\A\d+\z/)
          raise ToolError, "The \"auto_compact_window\" parameter is required for the \"change_auto_compact_window\" action and must be a positive integer."
        end

        window = raw.to_i
        if window <= 0 || window > Session::MAX_AUTO_COMPACT_WINDOW
          raise ToolError, "\"auto_compact_window\" must be between 1 and #{Session::MAX_AUTO_COMPACT_WINDOW}."
        end

        old_window = session.auto_compact_window
        session.update!(auto_compact_window: window)
        session.logs.create!(content: "Context window updated via MCP (#{old_window} → #{window}); applies on next turn or restart", level: "info") if old_window != window

        [
          "## Context Window Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Auto-compact Window:** #{session.auto_compact_window} tokens"
        ].join("\n")
      end

      def change_category(session, args)
        unless args.key?("category_id")
          raise ToolError, "The \"category_id\" parameter is required for the \"change_category\" action (pass null to clear)."
        end

        category_id = args["category_id"].presence
        category = nil
        if category_id
          category = Category.find_by(id: category_id)
          raise ToolError, "Category ##{category_id} not found" unless category
        end

        session.update!(category_id: category&.id)

        [
          "## Category Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Category:** #{category&.name || '(uncategorized)'}"
        ].join("\n")
      end

      def toggle_push_notifications(session)
        session.update!(push_notifications_enabled: !session.push_notifications_enabled)

        [
          "## Push Notifications Toggled",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Push Notifications:** #{session.push_notifications_enabled ? 'Enabled' : 'Disabled'}"
        ].join("\n")
      end

      def set_heartbeat(session, args)
        attrs = {}

        unless args["enabled"].nil?
          casted = ActiveModel::Type::Boolean.new.cast(args["enabled"])
          raise ToolError, "\"enabled\" must be a boolean." if casted.nil?
          attrs[:heartbeat_enabled] = casted
        end

        unless args["interval_seconds"].nil?
          interval = args["interval_seconds"]
          raise ToolError, "\"interval_seconds\" must be an integer." unless interval.to_s.match?(/\A\d+\z/)

          interval = interval.to_i
          unless interval.between?(Session::HEARTBEAT_MIN_INTERVAL_SECONDS, Session::HEARTBEAT_MAX_INTERVAL_SECONDS)
            raise ToolError, "\"interval_seconds\" must be between #{Session::HEARTBEAT_MIN_INTERVAL_SECONDS} and #{Session::HEARTBEAT_MAX_INTERVAL_SECONDS}."
          end
          attrs[:heartbeat_interval_seconds] = interval
        end

        if attrs.empty?
          raise ToolError, "The \"set_heartbeat\" action requires at least one of \"enabled\" or \"interval_seconds\"."
        end

        session.update!(attrs)

        [
          "## Heartbeat Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Heartbeat Enabled:** #{session.heartbeat_enabled ? 'Yes' : 'No'}",
          "- **Interval:** #{session.heartbeat_interval_seconds} seconds"
        ].join("\n")
      end

      def fork_session(session, args)
        message_index = args["message_index"]
        if message_index.nil?
          raise ToolError, "The \"message_index\" parameter is required for the \"fork\" action."
        end

        result = ForkSessionService.call(source_session: session, message_index: message_index.to_i)
        raise ToolError, "Fork failed: #{result.error}" unless result.success?

        forked = result.forked_session
        [
          "## Session Forked",
          "",
          "- **New Session ID:** #{forked.id}",
          "- **Title:** #{forked.title}",
          "- **Status:** #{forked.status}",
          "- **Message:** Session forked successfully"
        ].join("\n")
      end

      # The MCP twin of the Status panel's "Regenerate" button. Enqueued rather
      # than run inline: generation normally forks the session and waits on a
      # whole agent turn, which is far longer than a tool call should block.
      # (With no login-pool account free it takes the one-shot path instead —
      # still not something to block a tool call on.)
      def regenerate_status_summary(session)
        # Refused up front rather than by the job, which has nowhere to report a
        # refusal to. An archived session is fine, and so is one whose clone has
        # been reclaimed — the fork is scaffolded a working directory. What is
        # left is genuinely impossible, and the caller is told which it hit
        # instead of being handed a queued job that declines in silence.
        unavailable = SessionStatusSummaryGenerator.unavailable_reason(session: session, force: true)
        raise ToolError, unavailable.message if unavailable

        SessionStatusSummaryJob.set(priority: SessionStatusSummaryJob::FORCED_PRIORITY).perform_later(session.id, force: true)

        [
          "## Status Summary Regenerating",
          "",
          "- **Session:** ##{session.id}",
          "- **Message:** A generation was queued to rewrite the status summary. Read it back with get_session once it finishes."
        ].join("\n")
      end

      # Re-read the transcript the runtime writes to disk into the session record.
      def refresh(session)
        transcript_dir = transcript_directory(session)
        raise ToolError, "No clone path found for this session" if transcript_dir.nil?

        transcript_file = Dir.exist?(transcript_dir) ? find_main_transcript(session, transcript_dir) : nil
        raise ToolError, "No transcript files found on filesystem" unless transcript_file

        # Through the runtime's TranscriptSource, not File.read: that is where
        # TranscriptRedactor runs, so a manual refresh cannot write an unredacted
        # transcript over the redacted one the poller stored. It also decompresses a
        # Codex .zst rollout, which a raw read would have stored as binary.
        content = TranscriptRuntime.source_for(session).read(transcript_file)
        message_count = count_transcript_messages(content)

        # Never let a refresh shrink the stored transcript: a shorter filesystem
        # transcript means the clone was recreated at a new path and started a
        # fresh file, and session.transcript is the only durable record.
        if Session.transcript_regression?(session.transcript, content)
          Rails.logger.warn "[Mcp::Tools::ActionSession] Refused transcript regression for session #{session.id} " \
                            "(stored #{Session.transcript_line_count(session.transcript)} events, filesystem #{message_count}); preserving stored transcript"
          return summary(
            "Session Refreshed",
            session,
            message: "Filesystem transcript is shorter than the stored one (clone likely recreated); kept the stored transcript"
          )
        end

        session.update!(
          transcript: content,
          metadata: (session.metadata || {}).merge("broadcast_message_count" => message_count)
        )
        session.logs.create!(content: "Transcript refreshed via MCP (#{message_count} messages)", level: "info")

        summary("Session Refreshed", session, message: "Transcript refreshed (#{message_count} messages)")
      end

      # Bulk sweep: restart failed sessions, continue auto-continuable paused ones.
      # Sessions in a frozen category are a parked bucket and stay parked.
      def refresh_all
        # A status-summary fork sitting in needs_input between its pause and the
        # harvest is not work anyone is waiting on — resuming it would spend a
        # whole agent turn against a throwaway clone, outside the fork lifecycle.
        sessions = Session.not_in_frozen_category.excluding_status_summary_forks.where.not(status: :archived)

        if sessions.empty?
          return refresh_all_result("No non-archived sessions to refresh", 0, 0, 0, 0)
        end

        refreshed = 0
        restarted = 0
        continued = 0
        errors = 0

        failed_sessions = sessions.where(status: :failed).limit(REFRESH_ALL_LIMIT).load
        remaining_limit = [ REFRESH_ALL_LIMIT - failed_sessions.size, 0 ].max
        needs_input_sessions = sessions
          .where(status: :needs_input)
          .where("metadata->>'paused_by' IS NULL OR metadata->>'paused_by' != 'user'")
          .limit(remaining_limit)
          .load

        # Captured before the loops below flip these sessions to :running, so the
        # transcript pass cannot pick one up again and overwrite a transcript its
        # freshly enqueued job is about to rewrite.
        restarted_ids = (failed_sessions + needs_input_sessions).map(&:id)

        failed_sessions.each do |session|
          if session.may_resume?
            session.resume!
            AgentSessionJob.enqueue_with_prompt(session.id, AutomatedPrompts::SYSTEM_RECOVERY)
            restarted += 1
          end
        rescue StandardError => e
          errors += 1
          Rails.logger.warn "[Mcp::Tools::ActionSession] Failed to restart session #{session.id}: #{e.message}"
        end

        needs_input_sessions.each do |session|
          if session.may_resume?
            session.resume!
            AgentSessionJob.enqueue_with_prompt(session.id, AutomatedPrompts::SYSTEM_RECOVERY)
            continued += 1
          end
        rescue StandardError => e
          errors += 1
          Rails.logger.warn "[Mcp::Tools::ActionSession] Failed to continue session #{session.id}: #{e.message}"
        end

        # Everything not restarted or continued still gets its transcript re-read
        # from disk — that is what "refreshed" counts, and reporting a hardcoded 0
        # made the tool disagree with the web bulk refresh it mirrors. Capped at
        # the same limit as the restart passes: each iteration is a whole-file read
        # plus a broadcasting UPDATE, so an instance with hundreds of live sessions
        # would otherwise make one tool call an unbounded fan-out.
        sessions
          .where.not(status: [ :failed, :needs_input ])
          .where.not(id: restarted_ids)
          .limit(REFRESH_ALL_LIMIT)
          .each do |session|
            refreshed += 1 if refresh_transcript_from_disk(session)
          rescue StandardError => e
            errors += 1
            Rails.logger.error "[Mcp::Tools::ActionSession] Failed to refresh session #{session.id}: #{e.message}"
          end

        refresh_all_result("Refresh complete", refreshed, restarted, continued, errors)
      end

      # Re-read one session's transcript from disk. Returns true only when the
      # stored transcript actually changed — nothing to read, a byte-identical
      # copy, or a shorter filesystem copy (clone recreated at a new path) is not
      # a refresh.
      def refresh_transcript_from_disk(session)
        transcript_dir = transcript_directory(session)
        return false if transcript_dir.nil? || !Dir.exist?(transcript_dir)

        transcript_file = find_main_transcript(session, transcript_dir)
        return false unless transcript_file

        # Through the runtime's TranscriptSource, not File.read — see #refresh.
        # The equality short-circuit below is why this matters twice over: it
        # compares against the poller's redacted copy, so a raw read here would
        # never compare equal once a redaction has fired, and the two writers
        # would overwrite each other on every pass.
        content = TranscriptRuntime.source_for(session).read(transcript_file)
        return false if session.transcript == content

        message_count = count_transcript_messages(content)

        if Session.transcript_regression?(session.transcript, content)
          Rails.logger.warn "[Mcp::Tools::ActionSession] Skipped transcript regression for session #{session.id} " \
                            "(stored #{Session.transcript_line_count(session.transcript)} events, filesystem #{message_count}); preserving stored transcript"
          return false
        end

        session.update!(
          transcript: content,
          metadata: (session.metadata || {}).merge("broadcast_message_count" => message_count)
        )
        session.logs.create!(content: "Transcript refreshed via MCP bulk refresh (#{message_count} messages)", level: "info")

        true
      end

      def update_notes(session, args)
        notes = args["session_notes"]
        if notes.nil?
          raise ToolError, "The \"session_notes\" parameter is required for the \"update_notes\" action."
        end

        if notes.length > MAX_SESSION_NOTES_LENGTH
          raise ToolError, "Notes are too long (maximum #{MAX_SESSION_NOTES_LENGTH} characters)"
        end

        session.update!(
          session_notes: notes.presence,
          session_notes_updated_at: notes.present? ? Time.current : nil
        )

        [
          "## Session Notes Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}"
        ].join("\n")
      end

      def update_title(session, args)
        title = args["title"].to_s.strip
        raise ToolError, "The \"title\" parameter is required for the \"update_title\" action." if title.blank?

        session.update!(title: title)

        [
          "## Session Title Updated",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}"
        ].join("\n")
      end

      def toggle_favorite(session)
        session.update!(favorited: !session.favorited)

        [
          "## Favorite Toggled",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Favorited:** #{session.favorited ? 'Yes' : 'No'}"
        ].join("\n")
      end

      # Board visibility. One update to two presentation columns, through the same
      # service the web UI and the REST API use, so all three agree on what a
      # snooze time means. Nothing here touches the lifecycle — see
      # Sessions::SetVisibility.
      def set_visibility(session, args)
        Sessions::SetVisibility.call(
          session: session,
          visibility: args["visibility"].to_s,
          snoozed_until: args["snoozed_until"],
          timezone: args["timezone"].presence || "UTC"
        )

        [
          "## Board Visibility Set",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **Visibility:** #{session.visibility}",
          session.snoozed_until ? "- **Snoozed until:** #{session.snoozed_until.utc.iso8601} (UTC)" : nil,
          "",
          "This changed what the dashboard shows and nothing else. The session's status, " \
          "scheduling class, precedence and any armed wake-up are untouched, and it will run " \
          "exactly when it would have run anyway."
        ].compact.join("\n")
      rescue Sessions::SetVisibility::Error => e
        raise ToolError, e.message
      end

      def bulk_archive(args)
        session_ids = args["session_ids"]
        if !session_ids.is_a?(Array) || session_ids.empty?
          raise ToolError, "The \"session_ids\" parameter is required for the \"bulk_archive\" action."
        end

        archived_count = 0
        errors = []

        # One bulk call is one caller action, so it owes the caller one page
        # rather than one per session, and every page in `#alerts` spawns a
        # triage session downstream — which is what makes N of them expensive.
        #
        # Defensive here rather than load-bearing, and worth being honest about
        # which: the only alert this loop can currently burst is the
        # stranded-queue one, which a forced archive no longer raises and an
        # unforced one never reaches (the refusal above stops it). The batch is
        # what keeps that true of the next per-session alert somebody adds.
        # HealthMonitorService's sweep is where it does real work today.
        AlertBatcher.with_batch do
          Session.where(id: session_ids).where.not(status: :archived).each do |session|
            if session.may_archive?
              begin
                # Same refusal as the single-session action: a queue about to be
                # discarded is no less discarded for being archived in a batch.
                # Reported per session rather than aborting the batch, and
                # `force` applies to the whole batch because the argument is one
                # flag.
                refuse_archive_over_queued_messages(session, args, batch: true)
              rescue ToolError => e
                errors << { id: session.id, error: e.message }
                next
              end

              session.archive_actor = "#{archive_actor_phrase(args)} (bulk)"
              session.archive_forced = boolean(args["force"])
              session.archive!
              archived_count += 1
            else
              errors << { id: session.id, error: "Cannot archive from status: #{session.status}" }
            end
          end
        end

        lines = [ "## Bulk Archive Complete", "", "- **Archived:** #{archived_count}" ]
        if errors.any?
          lines << "- **Errors:** #{errors.size}"
          errors.each { |err| lines << "  - Session #{err[:id]}: #{err[:error]}" }
        end
        lines.join("\n")
      end

      # --- Provenance -----------------------------------------------------------

      # How the archived session's timeline will name whoever archived it.
      #
      # Self-declared, for the same reason `acting_session_id` is self-declared
      # on follow_up: nothing about an MCP request identifies the caller, since
      # the API key is shared by the whole fleet. An undeclared archive says so
      # rather than inventing an actor — and "an undeclared MCP caller" is still
      # the answer to "a human, or another agent?", because a human archiving a
      # session does it from the web UI.
      def archive_actor_phrase(args)
        declared = args["acting_session_id"].to_s.strip[/\A\d+\z/]
        return "an undeclared #{mcp_surface_name} caller" if declared.nil?

        "session ##{declared} via the #{mcp_surface_name}"
      end

      # Which MCP surface this tool is exposed on. The fleet-wide server can
      # archive any session; the injected self-session server is pointed at the
      # session itself, so naming them apart is most of the provenance.
      def mcp_surface_name
        "MCP API"
      end

      # --- Formatting -----------------------------------------------------------

      # `queued_message` is the caller's own message when this branch QUEUED it,
      # and nil when it delivered it instead — the queue-depth line reads
      # differently either way, and getting that backwards would misinform the
      # caller in exactly the way #698 exists to stop.
      def follow_up_result(session, message, queued_message: nil)
        heading = message.downcase.include?("immediately") ? "Follow-up Sent Immediately" : "Follow-up Sent"

        lines = [
          "## #{heading}",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **New Status:** #{session.status}",
          "- **Message:** #{message}"
        ]
        lines << "- **Job ID:** #{session.running_job_id}" if session.running_job_id.present?
        # The depth this call left behind, so a caller that just became fourth in
        # line finds out at the moment it happens rather than never. Same reason
        # `get_session` grew a queued-messages section (#698): an unread queue is
        # how four sessions each restate the message above it.
        lines.concat(EnqueuedMessageSections.queue_depth_lines(session, queued_message: queued_message))
        lines.join("\n")
      end

      def summary(heading, session, status_label: "Status", message: nil)
        lines = [
          "## #{heading}",
          "",
          "- **Session ID:** #{session.id}",
          "- **Title:** #{session.title}",
          "- **#{status_label}:** #{session.status}"
        ]
        lines << "- **Message:** #{message}" if message
        lines.join("\n")
      end

      def refresh_all_result(message, refreshed, restarted, continued, errors)
        [
          "## All Sessions Refreshed",
          "",
          "- **Message:** #{message}",
          "- **Refreshed:** #{refreshed}",
          "- **Restarted:** #{restarted}",
          "- **Continued:** #{continued}",
          "- **Errors:** #{errors}"
        ].join("\n")
      end

      def format_list(list)
        list.blank? ? "(none)" : list.join(", ")
      end

      # --- Helpers --------------------------------------------------------------

      def boolean(value)
        ActiveModel::Type::Boolean.new.cast(value) || false
      end

      # The directory holding this session's transcript files, from the
      # session's runtime TranscriptSource — the single place that knows a
      # runtime's on-disk layout.
      def transcript_directory(session)
        working_directory = session.working_directory
        return nil unless working_directory.is_a?(String) && working_directory.present?

        TranscriptRuntime.source_for(session).transcript_directory(working_directory: working_directory)
      rescue StandardError => e
        Rails.logger.error "[Mcp::Tools::ActionSession] Failed to get transcript directory: #{e.message}"
        nil
      end

      # The main transcript file inside that directory — the runtime's own
      # answer, so a Codex directory is never searched with Claude's file-picker.
      def find_main_transcript(session, transcript_dir)
        TranscriptRuntime.source_for(session)
          .find_main_transcript(transcript_directory: transcript_dir, session: session)
      end

      def count_transcript_messages(content)
        return 0 if content.blank?

        content.lines.count do |line|
          line.strip.present? && JSON.parse(line.strip)
        rescue JSON::ParserError
          false
        end
      end
    end
  end
end
