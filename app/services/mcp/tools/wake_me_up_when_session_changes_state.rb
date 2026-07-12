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
        Schedule this session to be woken up when another session transitions to `needs_input`, `failed`, or `archived`. The requester session is put to sleep (waiting status) and a one-time trigger fires when the watched session enters the matching state. If the requester is manually resumed before the watched session transitions, the trigger is silently consumed and won't re-fire.

        This is the **state-based analog of `wake_me_up_later`**. Use `wake_me_up_later` when you know *when* to wake up (a clock time). Use this tool when you know *what event* to wake up on but not when it will happen — e.g., a subagent session you spawned will eventually finish (self-archive), pause for input, or crash, and you want to be the first to handle it without polling.

        **Triple-wake pattern (typical use).** When you spawn a downstream session and want to wake up on whatever outcome it produces, you'll TYPICALLY want to schedule THREE state-change triggers — one for each terminal/idle event — so you wake on whichever happens first:
        - `session_archived` — the watched session self-archived on success (common for closed-loop tasks like "open a PR and self-archive when CI is green"). A downstream session that self-archives goes `running` → `archived` directly, skipping `needs_input`, so a trigger on `session_needs_input` alone would NEVER fire for these tasks.
        - `session_needs_input` — the watched session paused for user input or finished a turn awaiting follow-up.
        - `session_failed` — the watched session crashed.

        Pair these three triggers with ONE `wake_me_up_later` deadline backstop so a hung watched session can't keep you sleeping forever. The first trigger to fire wakes the requester. **Picking only ONE of the three is a footgun** — if you only schedule `session_needs_input` and the downstream session self-archives directly, the only thing that wakes you is the deadline (long, wasteful). Schedule all three unless you have a specific reason to wake only on one outcome.

        **⚠️ Sibling-destroy semantics (read carefully — this is a footgun).** When ANY one of the registered wake-ups fires for the requester (any of the three state-change triggers OR the `wake_me_up_later` deadline backstop), Zimmer's firing path **destroys all of the requester's other one-time wake-up triggers as a side effect** — they are not just "consumed," they are deleted from the database. This applies across event names *and* across tool types: a fired `session_needs_input` watcher destroys the `session_archived` watcher, the `session_failed` watcher, and the `wake_me_up_later` deadline. After any wake fires, the requester has zero remaining scheduled wakes.

        This matters when a wake fires *prematurely* — for example, a watched session that flaps `running → needs_input → running` during startup will fire your `session_needs_input` watcher even though the session is still in flight. Your woken-up turn will look at the watched session, see it's still working, and want to go back to sleep. **You must re-register the wakes you still need before going back to sleep** (the other two state events plus a fresh deadline backstop) — the originals are gone. The same applies if your deadline backstop fires while the watched session is still progressing: re-register the state-change watchers and a new deadline if you want to keep waiting.

        Concretely, in a woken-up turn that determines the watched session has not actually reached its terminal/idle state:
        1. Inspect the watched session's current state and decide whether to keep waiting.
        2. If keeping waiting: call `wake_me_up_when_session_changes_state` again for each of the state events you care about (typically all three), and call `wake_me_up_later` again for a fresh deadline. Then end the turn.
        3. The originals are NOT still pending in the background — assume nothing remains.

        **IMPORTANT — Use this tool instead of polling.** When this tool is available, it is the correct way to wait on another session's state. Do NOT use these alternatives:
        - **Repeated `get_session` calls in a poll loop**: wastes compute, racks up tool-call overhead, and either polls too often (waste) or too rarely (latency). The trigger fires immediately on transition with no polling latency.
        - **`wake_me_up_later` with a guessed duration**: time-based wake-ups are wrong as the *primary* signal here — you don't know when the watched session will transition, and a guess is either too short (you wake up early and have to re-sleep) or too long (the watched session has been sitting in `needs_input` / archived while you sleep). Use `wake_me_up_later` only as a deadline backstop alongside the state-change triggers.

        **The watched session can be ANY session**, not just one the requester spawned. You can watch a peer session, a session a different agent created, or even a session run by a different user — as long as the requester knows the watched session's id.

        **One-shot semantics.** Each trigger auto-disables after firing. If the watched session transitions, the requester wakes up exactly once and only the first-firing trigger's prompt is delivered; any companion triggers (the other two state events plus the deadline backstop) are destroyed as a side effect of the fire — see the sibling-destroy semantics above. To wake on a future transition too, schedule another trigger from the woken-up turn.

        **Important — fires on transitions, not on current state.** The trigger fires when the watched session *moves into* the target state, not when it is *already in* it. `failed` and `archived` are both terminal under typical flow — a session that is already `failed` will not transition to `failed` again, and a session that is already `archived` will not transition to `archived` again unless someone unarchives it and re-archives it (rare and surprising). `needs_input` is non-terminal: if the watched session is already `needs_input` when you create the trigger, it waits for the next transition out and back in. This tool rejects up front any case where the trigger could never fire — already-failed and already-archived watched sessions (terminal states), plus the self-watch case (requester == watched) — so the requester doesn't sleep on a trigger that can never fire.

        **Deadline backstop pattern.** Always pair the state-change triggers with one `wake_me_up_later` trigger so the requester eventually wakes even if the watched session hangs. First trigger to fire wins; firing destroys the requester's other one-time wake-ups (see sibling-destroy semantics above), so a woken-up turn that wants to keep waiting must re-register the wakes it still needs.

        **Parameters:**
        - **session_id**: The session to wake up (the requester). Works from either `needs_input` or `running` state — if you call this tool from within your own currently-running session, the sleep transition is recorded and takes effect after the current turn ends.
        - **watched_session_id**: The session to watch. Must be a positive integer. The Rails API rejects unknown ids with a clear 422.
        - **event_name**: Which transition to wake on:
          - `session_needs_input`: watched session moves to `needs_input` (typically: it finished a turn, or it asked a clarifying question).
          - `session_failed`: watched session moves to `failed` (a hard error — the session crashed or was killed).
          - `session_archived`: watched session moves to `archived` (typically: it self-archived after completing closed-loop work, OR a user manually archived it).

          When in doubt, schedule all three (see the triple-wake pattern above) — the first to fire wins.
        - **prompt**: The prompt to send when waking up the session. Include enough context that the woken-up turn knows what to do (e.g., "session #N you were watching just transitioned — check its output and decide next steps"). If you scheduled multiple triggers (the typical case), each trigger's prompt should make clear which event fired so the woken-up turn knows the outcome without re-checking.

        **What happens:**
        1. Creates a one-time `ao_event` trigger bound to the requester (`reuse_session: true`, `last_session_id: session_id`) with a single condition scoped to `watched_session_id` and `event_name`.
        2. As a side effect of creating the trigger, Zimmer transitions the requester to sleeping (waiting) status — immediately if currently `needs_input`, or after the current turn ends if currently `running`.
        3. When the watched session transitions to the matching state, the trigger fires and resumes the requester with the provided prompt. The trigger then auto-deletes (one-shot).
        4. If the requester is manually resumed first, the pending trigger is consumed (won't fire). If the watched session is archived without ever transitioning to the matching state (e.g., you only scheduled `session_needs_input` and it went straight to `archived`), the trigger is cleaned up — and you'll only wake when your deadline backstop fires.

        **End your conversation turn after scheduling.** Two mechanisms together make wake delivery durable:
        1. **Auto-sleep** — ending your turn transitions the requester from `running` to `waiting`, where the trigger resumes it directly when the watched event fires.
        2. **Cross-turn queuing** — if the watched event fires while the requester is still in `running` (the turn hadn't ended yet when the watched event happened), the wake-up prompt is durably queued onto the requester via `enqueued_messages` and picked up at the next turn boundary by Zimmer's pre-pause handoff. It is NOT silently dropped.

        You should still end your turn promptly — queuing is the safety net, not a substitute for ending the turn. When scheduling multiple triggers (the typical triple-wake + deadline pattern), call this tool repeatedly within the same turn before ending it.

        **Wake-ups override `enqueue_messages: false`.** For ordinary triggers (Slack, recurring schedules), `enqueue_messages: false` means "don't barge a busy session." Wake-ups are one-shot signals, not recurring drumbeats, so they queue onto a running requester regardless of that flag.
      DESC

      input_schema({
        type: "object",
        properties: {
          session_id: {
            oneOf: [ { type: "string" }, { type: "number" } ],
            description: "Session ID (numeric) or slug (string) for the session to wake up (the requester). Accepts sessions in needs_input or running state — from a running session, the sleep takes effect after the current turn ends."
          },
          watched_session_id: {
            type: "number",
            description: "ID of the session to watch. Must be a positive integer. The trigger fires when this session transitions to the matching event_name state."
          },
          event_name: {
            type: "string",
            enum: AO_EVENT_NAMES,
            description: 'Which transition to wake on: "session_needs_input" (watched session is waiting for input), "session_failed" (watched session crashed), or "session_archived" (watched session self-archived or was archived by a user). Typically schedule all three (plus a wake_me_up_later deadline backstop) for a downstream session you spawned — see the triple-wake pattern in the tool description.'
          },
          prompt: {
            type: "string",
            description: "The prompt to send when waking up the requester session."
          }
        },
        required: [ "session_id", "watched_session_id", "event_name", "prompt" ]
      })

      def call(args)
        watched_session_id = parse_watched_session_id(args)
        event_name = require_arg(args, :event_name).to_s
        prompt = require_arg(args, :prompt).to_s

        unless AO_EVENT_NAMES.include?(event_name)
          raise ToolError, "Invalid arguments — event_name: must be one of #{AO_EVENT_NAMES.join(', ')}. " \
                           "No trigger was created and no session state was changed."
        end

        session = find_session(args["session_id"])

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
        reject_unfireable_watched_state!(watched_session, event_name)

        trigger = create_wake_trigger!(session, watched_session_id, event_name, prompt)

        <<~TEXT.strip
          ## Wake-Up Scheduled Successfully

          - **Requester Session ID:** #{session.id}
          - **Watched Session ID:** #{watched_session_id}
          - **Event:** #{event_name}
          - **Trigger ID:** #{trigger.id}
          - **Trigger Name:** #{trigger.name}

          **You must end your conversation turn now.** The requester session will be automatically transitioned to waiting (immediately if currently needs_input; after the current turn ends if currently running) and resumed when the watched session transitions to the matching state.

          ℹ️ **Cross-turn safety net:** If the watched session transitions before you end this turn, the wake-up prompt is durably queued onto the requester via `enqueued_messages` and processed at the next turn boundary by Zimmer's pre-pause handoff — it is NOT silently dropped. Still end your turn promptly; queuing is the safety net, not a substitute for ending the turn.

          **One-shot:** the trigger auto-deletes after firing. If you want to wake on the next transition too, schedule another trigger from the woken-up turn.

          **Sibling-destroy reminder:** when ANY of this requester's one-time wakes fires (this trigger, a companion state-change trigger, or a `wake_me_up_later` deadline), Zimmer's firing path destroys all the others. If the woken-up turn determines the watched session is still in flight (e.g., a transient `needs_input` flap during startup), you MUST re-register the wakes you still need before going back to sleep — they are gone, not pending.
        TEXT
      end

      private

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

      def create_wake_trigger!(session, watched_session_id, event_name, prompt)
        Trigger.create!(
          name: "Wake session ##{session.id} on #{event_name} of session ##{watched_session_id}",
          agent_root_name: trigger_agent_root_name(session),
          prompt_template: prompt,
          reuse_session: true,
          last_session_id: session.id,
          trigger_conditions_attributes: [
            {
              condition_type: "ao_event",
              configuration: { "event_name" => event_name, "watched_session_id" => watched_session_id }
            }
          ]
        )
      rescue ActiveRecord::RecordInvalid => e
        raise ToolError, "Trigger creation failed: #{e.record.errors.full_messages.join(', ')}. " \
                         "The session is still in its original state — no changes were made."
      end

      # See WakeMeUpLater#trigger_agent_root_name — bookkeeping only for a per-session
      # wake-up trigger, which always reuses its target session rather than spawning.
      def trigger_agent_root_name(session)
        session.agent_root_key.presence || session.agent_runtime
      end
    end
  end
end
