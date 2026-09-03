# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors POST /api/v1/triggers with a session-scoped `ao_event` condition bound
    # to the requester session (reuse_session + last_session_id).
    #
    # As with wake_me_up_later, the requester's sleep is a side effect of persisting
    # the trigger (Trigger's `after_create :sleep_target_session_if_applicable`), so
    # the sleep and the trigger land in one transaction. This tool never transitions
    # the session itself.
    class WakeMeUpWhenSessionChangesState < Tool
      tool_name "wake_me_up_when_session_changes_state"

      AO_EVENT_NAMES = %w[session_needs_input session_failed session_archived].freeze

      # See WakeMeUpLater::WAKEABLE_STATUSES — states the auto-sleep can act on.
      WAKEABLE_STATUSES = %w[needs_input running waiting].freeze

      description <<~DESC
        Schedule this session to be woken up when another session reaches `needs_input`, `failed`, or `archived`. The requester session is put to sleep (waiting status) and a one-time trigger fires when the watched session gets there. If the requester is manually resumed before the watched session transitions, the trigger is silently consumed and won't re-fire.

        This is the **state-based analog of `wake_me_up_later`**. Use `wake_me_up_later` when you know *when* to wake up (a clock time). Use this tool when you know *what event* to wake up on but not when it will happen — e.g., a session you spawned will eventually finish (self-archive), pause for input, or crash, and you want to be the first to handle it without polling.

        **One call, all three events (do this).** Pass `event_names: ["session_archived", "session_needs_input", "session_failed"]` and you get ONE trigger that fires on whichever happens first. Watching only one is a footgun: a session that finishes its work self-archives straight from `running` to `archived`, so a lone `session_needs_input` watcher would never fire for it. Pair the one call with ONE `wake_me_up_later` deadline backstop, and the whole wait costs two tool calls.

        `event_name` (singular) still works and creates a single-event trigger. Prefer `event_names`: three separate calls create three separate triggers, and every one of them is destroyed when any one fires, so you pay to re-create all three.

        **`session_needs_input` means "came to rest", not "crossed the state".** A session emits `needs_input` at every turn boundary, including boundaries it leaves again immediately — one that wakes on its own `wake_me_up_later`, takes a turn and goes back to sleep, or one with a message already queued for it. Zimmer holds the event for a short settle window and drops it unless the watched session is *still* at rest when the window closes, so those turn boundaries do not wake you. What reaches you is a session that has genuinely stopped. `session_failed` and `session_archived` are terminal and fire immediately, with no settle delay.

        This is worth internalizing because it inverts the old rule: **a wake you receive is a real signal.** You should not expect to be woken repeatedly by a healthy watched session that is asleep on its own wake-ups.

        **Sibling-destroy semantics.** When any one of the requester's one-time wakes fires — this trigger or the `wake_me_up_later` deadline backstop — Zimmer's firing path destroys the requester's other one-time wake triggers. They are deleted, not merely consumed. If a woken-up turn decides to keep waiting, re-register: one `wake_me_up_when_session_changes_state` call with `event_names`, and one `wake_me_up_later` deadline. Two calls, not four.

        **IMPORTANT — Use this tool instead of polling.** When this tool is available, it is the correct way to wait on another session's state. Do NOT use these alternatives:
        - **Repeated `get_session` calls in a poll loop**: wastes compute, racks up tool-call overhead, and either polls too often (waste) or too rarely (latency).
        - **`wake_me_up_later` with a guessed duration** as the *primary* signal: you don't know when the watched session will transition, and a guess is either too short or too long. Use `wake_me_up_later` only as a deadline backstop alongside this tool.

        **The watched session can be ANY session**, not just one the requester spawned. You can watch a peer session, a session a different agent created, or even a session run by a different user — as long as the requester knows the watched session's id.

        **One-shot semantics.** The trigger auto-deletes after firing, and only the first-firing event's prompt is delivered. To wake on a future transition too, schedule another trigger from the woken-up turn.

        **Fires on reaching the state, not on already being in it.** `failed` and `archived` are terminal — a session already in one will not enter it again — so this tool rejects those up front, along with the self-watch case, rather than letting the requester sleep on a trigger that can never fire. A watched session that is *already* resting in `needs_input` when you register fires immediately.

        **Parameters:**
        - **session_id**: OPTIONAL. The session to wake up (the requester). Omit it to watch on behalf of YOURSELF — a session's own Zimmer MCP entry names it, so the tool already knows who is calling. Pass it only to schedule a wake for a DIFFERENT session. Works from either `needs_input` or `running` state — from a running session, the sleep takes effect after the current turn ends.
        - **watched_session_id**: The session to watch. Must be a positive integer.
        - **event_names**: The transitions to wake on, as an array. Any subset of:
          - `session_archived` — the watched session self-archived on success (common for closed-loop tasks that finish without needing anyone), OR a user archived it.
          - `session_needs_input` — the watched session came to rest needing something: it asked a question, or ended a turn with nothing else scheduled.
          - `session_failed` — the watched session crashed.

          Pass all three unless you have a specific reason to wake on only one outcome.
        - **event_name**: Accepted as a single-event alternative to `event_names`. Give one or the other.
        - **prompt**: The prompt to send when waking up the session. Include enough context that the woken-up turn knows what to do (e.g., "session #N you were watching reached a resting state — check its output and decide next steps"). With `event_names` a single trigger covers several outcomes, so write a prompt that does not assume which one fired; the wake-up message names the event.

        **What happens:**
        1. Creates ONE one-time `ao_event` trigger bound to the requester (`reuse_session: true`, `last_session_id: session_id`), carrying one condition per requested event, each scoped to `watched_session_id`.
        2. As a side effect of creating the trigger, Zimmer transitions the requester to sleeping (waiting) status — immediately if currently `needs_input`, or after the current turn ends if currently `running`.
        3. When the watched session reaches a matching state, the trigger fires and resumes the requester with the provided prompt, then auto-deletes.
        4. If the requester is manually resumed first, the pending trigger is consumed. If the watched session is archived without ever reaching a state you asked for, the trigger is cleaned up and your deadline backstop is what wakes you.

        **End your conversation turn after scheduling.** Two mechanisms together make wake delivery durable:
        1. **Auto-sleep** — ending your turn transitions the requester from `running` to `waiting`, where the trigger resumes it directly when the watched event fires.
        2. **Cross-turn queuing** — if the watched event fires while the requester is still in `running`, the wake-up prompt is durably queued onto the requester via `enqueued_messages` and picked up at the next turn boundary. It is NOT silently dropped.

        **Wake-ups override `enqueue_messages: false`.** For ordinary triggers (Slack, recurring schedules), `enqueue_messages: false` means "don't barge a busy session." Wake-ups are one-shot signals, not recurring drumbeats, so they queue onto a running requester regardless of that flag.
      DESC

      input_schema({
        type: "object",
        properties: {
          session_id: {
            oneOf: [ { type: "string" }, { type: "number" } ],
            description: "OPTIONAL — omit to have the calling session watch. Session ID (numeric) or slug (string) for the session to wake up (the requester). Accepts sessions in needs_input or running state."
          },
          watched_session_id: {
            type: "number",
            description: "ID of the session to watch. Must be a positive integer. The trigger fires when this session reaches one of the requested states."
          },
          event_names: {
            type: "array",
            items: { type: "string", enum: AO_EVENT_NAMES },
            description: 'Which transitions to wake on. Pass all three — ["session_archived", "session_needs_input", "session_failed"] — unless you have a specific reason to wake on one outcome. They become ONE trigger, so the first to happen wins and there is only one thing to re-register afterwards.'
          },
          event_name: {
            type: "string",
            enum: AO_EVENT_NAMES,
            description: "Single-event alternative to event_names. Give one or the other."
          },
          prompt: {
            type: "string",
            description: "The prompt to send when waking up the requester session."
          }
        },
        required: [ "watched_session_id", "prompt" ]
      })

      def call(args)
        watched_session_id = parse_watched_session_id(args)
        event_names = parse_event_names(args)
        prompt = require_arg(args, :prompt).to_s

        session = requester_session(args)

        # The trigger fires on the requester's auto-sleep+resume cycle when the
        # watched session transitions. If they're the same session, the requester
        # would resume itself in a confusing self-loop. Guard before any state change.
        if session.id == watched_session_id
          raise ToolError, "watched_session_id (#{watched_session_id}) is the same as the requester session id. " \
                           "A session cannot watch itself for state changes — the auto-sleep would never resolve cleanly. " \
                           "Pass a different session id."
        end

        unless WAKEABLE_STATUSES.include?(session.status.to_s)
          raise ToolError, "Session #{session.id} is in \"#{session.status}\" state and cannot be scheduled for wake-up. " \
                           "Only sessions in #{WAKEABLE_STATUSES.join(', ')} can be woken up."
        end

        watched_session = Session.find_by(id: watched_session_id)
        unless watched_session
          raise ToolError, "Could not look up watched session #{watched_session_id}: session not found. " \
                           "No trigger was created and no session state was changed."
        end

        enforce_watched_session_root!(watched_session)
        event_names.each { |name| reject_unfireable_watched_state!(watched_session, name) }

        trigger = create_wake_trigger!(session, watched_session_id, event_names, prompt)

        <<~TEXT.strip
          ## Wake-Up Scheduled Successfully

          - **Requester Session ID:** #{session.id}
          - **Watched Session ID:** #{watched_session_id}
          - **Events:** #{event_names.join(', ')}
          - **Trigger ID:** #{trigger.id}
          - **Trigger Name:** #{trigger.name}#{defaulted_requester_notice(session)}

          **You must end your conversation turn now.** The requester session will be automatically transitioned to waiting (immediately if currently needs_input; after the current turn ends if currently running) and resumed when the watched session reaches one of the states above.

          ℹ️ **Cross-turn safety net:** If the watched session transitions before you end this turn, the wake-up prompt is durably queued onto the requester via `enqueued_messages` and processed at the next turn boundary by Zimmer's pre-pause handoff — it is NOT silently dropped. Still end your turn promptly; queuing is the safety net, not a substitute for ending the turn.

          **One-shot:** the trigger auto-deletes after firing. If you want to wake on the next transition too, schedule another from the woken-up turn.

          **What will NOT wake you:** a `session_needs_input` that the watched session leaves again at once — waking on its own timer, taking a turn and re-sleeping, or draining a queued message. Zimmer settles that event before delivering it, so a wake you receive means the watched session actually came to rest.

          **Sibling-destroy reminder:** when any one-time wake of this requester fires (this trigger or a `wake_me_up_later` deadline), Zimmer's firing path destroys the others. A woken-up turn that decides to keep waiting must re-register — one call here with `event_names`, one `wake_me_up_later` deadline.
        TEXT
      end

      private

      # `event_names` (array) is the shape to use; `event_name` (string) is the
      # single-event spelling every existing caller and every existing piece of
      # harness prose passes. Accept both, reject neither-and-both, and normalize
      # to a deduplicated array so the rest of the method has one shape to handle.
      def parse_event_names(args)
        plural = args["event_names"]
        singular = args["event_name"]

        if plural.present? && singular.present?
          raise ToolError, "Pass either event_names (an array) or event_name (a single string), not both. " \
                           "No trigger was created and no session state was changed."
        end

        names = Array(plural.presence || singular.presence).map { |name| name.to_s.strip }.reject(&:empty?).uniq

        if names.empty?
          raise ToolError, "Missing required parameter: event_names. Pass an array of " \
                           "#{AO_EVENT_NAMES.join(', ')} — normally all three, so the first outcome to happen wakes you."
        end

        invalid = names - AO_EVENT_NAMES
        if invalid.any?
          raise ToolError, "Invalid arguments — event_names: #{invalid.join(', ')} " \
                           "#{invalid.one? ? 'is not a' : 'are not'} valid event#{'s' unless invalid.one?}. " \
                           "Must be one of #{AO_EVENT_NAMES.join(', ')}. " \
                           "No trigger was created and no session state was changed."
        end

        names
      end

      def parse_watched_session_id(args)
        raw = require_arg(args, :watched_session_id)
        watched_session_id = raw.to_s.to_i

        unless raw.to_s.match?(/\A\d+\z/) && watched_session_id.positive?
          raise ToolError, "Invalid arguments — watched_session_id: must be a positive integer. " \
                           "No trigger was created and no session state was changed."
        end

        watched_session_id
      end

      # allowed_agent_roots scopes which agent roots this connection may operate on.
      # The requester is by definition already on an allowed root (it is the calling
      # agent's own session, and a session waking itself is never restricted), so only
      # the watched session needs checking — otherwise a restricted connection could
      # schedule wakes off the back of sessions outside its scope.
      def enforce_watched_session_root!(watched_session)
        return unless context.restricted?

        allowed = context.allowed_agent_roots
        watched_root = watched_session.agent_root_key
        return if watched_root.present? && allowed.include?(watched_root)

        raise ToolError, "ALLOWED_AGENT_ROOTS is set — watched session #{watched_session.id} belongs to agent root " \
                         "\"#{watched_root.presence || '(unknown)'}\", which is not in the allowed list [#{allowed.join(', ')}]. " \
                         "The trigger would let this server schedule wakes on a session outside its permitted scope. " \
                         "Pass a watched_session_id whose agent root is in the allowed list, or run this tool from a server " \
                         "without ALLOWED_AGENT_ROOTS restrictions."
      end

      # The firing path (AoEventTriggerJob, fired from the session state machine's
      # transition callbacks) only fires on actual *transitions* into the target
      # state. A watched session already sitting in a terminal state can never
      # transition into it again, so the requester would sleep forever.
      def reject_unfireable_watched_state!(watched_session, event_name)
        if event_name == "session_failed" && watched_session.failed?
          raise ToolError, "Watched session #{watched_session.id} is already in \"failed\" state. The trigger fires on " \
                           "transitions only — a session that is already failed will not transition to failed again, so the " \
                           "requester would sleep forever. Inspect the failed session directly instead of waiting on it."
        end

        if event_name == "session_archived" && watched_session.archived?
          raise ToolError, "Watched session #{watched_session.id} is already in \"archived\" state. The trigger fires on " \
                           "transitions only — a session that is already archived will not transition to archived again " \
                           "(barring an unarchive + re-archive, which is rare), so the requester would sleep forever. " \
                           "Pass an active session id, or inspect the archived session directly."
        end

        if watched_session.archived?
          raise ToolError, "Watched session #{watched_session.id} is archived and will not transition further. The trigger " \
                           "would never fire. Pass an active session id, or inspect the archived session directly."
        end
      end

      # ONE trigger carrying one condition per event, rather than one trigger each.
      #
      # A Trigger ORs its conditions, so the shapes are equivalent in what they
      # fire on — but not in what they cost. A fired one-time wake destroys the
      # requester's sibling wake triggers, so three separate triggers mean three
      # writes to make and three to re-make on every wake; one trigger means one.
      # Trigger#one_time_reuse_trigger? already asks `all?` of the conditions, and
      # AoEventTriggerJob fires per condition and then destroys the trigger, so a
      # multi-condition wake needs nothing new from either.
      def create_wake_trigger!(session, watched_session_id, event_names, prompt)
        Trigger.create!(
          name: "Wake session ##{session.id} on #{event_names.join('/')} of session ##{watched_session_id}",
          agent_root_name: trigger_agent_root_name(session),
          prompt_template: prompt,
          reuse_session: true,
          last_session_id: session.id,
          trigger_conditions_attributes: event_names.map do |event_name|
            {
              condition_type: "ao_event",
              configuration: { "event_name" => event_name, "watched_session_id" => watched_session_id }
            }
          end
        )
      rescue ActiveRecord::RecordInvalid => e
        raise ToolError, "Trigger creation failed: #{e.record.errors.full_messages.join(', ')}. " \
                         "The session is still in its original state — no changes were made."
      end

      # See Sessions::ScheduleWakeUp#trigger_agent_root_name — a label only, for a
      # per-session wake-up trigger, which always reuses its target session rather
      # than spawning. That comment carries the reasoning, including why an
      # unresolvable name is safe here and why guessing a default root is not.
      def trigger_agent_root_name(session)
        session.agent_root_key.presence || session.agent_runtime
      end
    end
  end
end
