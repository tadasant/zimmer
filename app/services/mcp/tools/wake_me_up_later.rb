# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors POST /api/v1/triggers with a one-time schedule condition bound to an
    # existing session (reuse_session + last_session_id).
    #
    # The scheduling itself — validation, the trigger, and the sleep that trigger
    # creation performs as a side effect — lives in Sessions::ScheduleWakeUp.
    # This class is the MCP-shaped wrapper around it: argument coercion, the
    # rendered description, and the markdown receipt.
    class WakeMeUpLater < Tool
      tool_name "wake_me_up_later"

      # Re-exported so the description below and anything reading the tool surface
      # see the same numbers the scheduler enforces.
      WAKE_AT_GRACE_WINDOW = Sessions::ScheduleWakeUp::WAKE_AT_GRACE_WINDOW
      WAKEABLE_STATUSES = Sessions::ScheduleWakeUp::WAKEABLE_STATUSES

      # The description interpolates the current server time, so it is rendered per
      # tools/list call rather than frozen at class-definition time — the model uses
      # it as the reference point for computing relative wake-ups.
      def self.rendered_description
        <<~DESC
          Schedule this session to be woken up at a specific time. The session will be put to sleep (waiting status) and a one-time trigger will fire at the specified time to resume it with the given prompt. If the session is manually resumed before the scheduled time, the trigger will be silently dropped.

          **IMPORTANT — Use this tool instead of workarounds.** When this tool is available, it is the correct way to schedule a delayed wake-up in a Zimmer context. Do NOT use these alternatives:
          - **Bash `sleep`**: Blocks the process and wastes compute resources for the entire sleep duration. The session remains "running" and cannot be reclaimed.
          - **Claude Code `ScheduleWakeup` tool**: Does not integrate with Zimmer's session lifecycle — it won't transition the session to sleeping/waiting state or create a Zimmer trigger, so Zimmer cannot track or manage the wake-up.
          - **Claude Code `Monitor` tool**: Same problem — it operates outside Zimmer's session state management.

          This tool creates a one-time Zimmer wake-up trigger bound to the target session. Creating the trigger atomically transitions the session to sleeping (waiting) state, so Zimmer can reclaim resources and the trigger is guaranteed to resume the correct session at the specified time.

          **If the fire itself errors** (a stale agent root, a bad MCP reference), the wake does NOT happen and the trigger is NOT deleted: it is parked in the `failed` status with the error on it, still listed at `/triggers` with a **Re-arm** button, and an alert is raised. It will not retry on its own. If this connection also has the trigger tools, a `status=failed` search finds wakes that never happened and a toggle re-arms one; otherwise the trigger page is where a human clears it.

          **When there is no time worth naming.** This tool wants a wall-clock time, and inventing one for work that is not on a clock is how a session ends up polling a queue it could have joined. If what you are actually waiting on is quota headroom — not an event, not a deadline — use `action_session` with the "pause_into_spot_queue" action instead: it sleeps the session with no trigger at all and Zimmer resumes it when the spot scheduler reaches it.

          **Current server time:** #{Time.current.utc.iso8601} (UTC). Use this as your reference point when calculating wake-up times.

          **Timezone handling:**
          - The `wake_at` parameter is interpreted in the timezone specified by `timezone` (default: "UTC").
          - To schedule "30 minutes from now": take the current UTC time above, add 30 minutes, and pass that as `wake_at` with timezone "UTC" (or omit timezone).
          - To schedule at a wall-clock time in a specific timezone (e.g., "9am Eastern"): pass `wake_at` as "2026-04-15T09:00:00" with timezone "America/New_York". The server converts to UTC internally.
          - Use IANA timezone names (e.g., "America/New_York", "Europe/London", "Asia/Tokyo"). Do NOT pass UTC offsets like "+05:00" in the timezone parameter.
          - If you omit timezone, wake_at is treated as UTC.

          **Choosing wake_at — adaptive scheduling for unknown durations:**
          When monitoring downstream work whose duration you can't predict (e.g., a subagent or pipeline phase), the bias is **prefer over-polling to under-polling**. A too-frequent poll wastes a few seconds of compute; a too-long sleep wastes minutes of user-facing wall-clock time and erodes trust. When in doubt, go shorter.

          **Rules:**
          - **First wake: MUST be ≤5 minutes from now.** Use less if you have any reason to think the work could already be done (e.g., a 30-second task — pick 1–2 minutes). This is a hard cap, not a default. Do NOT pick a longer first wake just because the work "might take a while" — you have not observed anything yet, so you cannot know.
          - **Second and later wakes:** Now that you've actually observed progress, you may scale the next wake to what you saw:
            - If the work is nearly done (~80%+): a few more minutes.
            - In between: proportional to remaining work, capped at ~15 minutes.
            - If barely started (<20%) AND you have already polled at least twice and confirmed the work is genuinely long-running: you may extend up to ~30 minutes. Do NOT use this tier on the first or second poll.
          - **Never** pick a wake interval ≥10× the expected total task duration. If a downstream task should take ~3 minutes, a 25-minute wake is wrong even on the first poll — pick 2–3 minutes instead.

          This guidance does NOT apply when waking at a known wall-clock time (e.g., "9am tomorrow") — use the calculated time directly.

          **Parameters:**
          - **session_id**: OPTIONAL. The session to wake up. Omit it to wake YOURSELF — a session's own Zimmer MCP entry names it, so the tool already knows who is calling. Pass it only to schedule a wake for a DIFFERENT session. Works from either `needs_input` or `running` state — if you call this tool from within your own currently-running session, the sleep transition is recorded and takes effect after the current turn ends.
          - **wake_at**: ISO 8601 datetime without offset for when to wake up (e.g., "2026-04-15T14:30:00")
          - **timezone**: IANA timezone for interpreting wake_at (default: "UTC", e.g., "America/New_York")
          - **prompt**: The prompt to send when waking up the session

          **What happens:**
          1. Creates a one-time schedule trigger bound to this session that fires at the specified time.
          2. As a side effect of creating the trigger, Zimmer transitions the session to sleeping (waiting) status — immediately if currently `needs_input`, or after the current turn ends if currently `running`.
          3. At the scheduled time, the trigger resumes the session with the provided prompt.

          **End your conversation turn after scheduling.** Two mechanisms together make wake delivery durable:
          1. **Auto-sleep** — ending your turn transitions the requester from `running` to `waiting`, where the trigger resumes it directly at the scheduled time.
          2. **Cross-turn queuing** — if the scheduled time arrives while the requester is still in `running` (the turn hadn't ended yet), the wake-up prompt is durably queued onto the requester via `enqueued_messages` and picked up at the next turn boundary by Zimmer's pre-pause handoff. It is NOT silently dropped.

          You should still end your turn promptly — queuing is the safety net, not a substitute for ending the turn.

          **Wake-ups override `enqueue_messages: false`.** For ordinary triggers (Slack, recurring schedules), `enqueue_messages: false` means "don't barge a busy session." Wake-ups are one-shot signals, not recurring drumbeats, so they queue onto a running requester regardless of that flag.

          **⚠️ Sibling-destroy semantics when paired with state-change wakes.** If this `wake_me_up_later` trigger is acting as a deadline backstop alongside `wake_me_up_when_session_changes_state` triggers (the recommended triple-wake + deadline pattern), Zimmer's firing path destroys ALL of the requester's other one-time wakes whenever any one of them fires — and that cuts both ways:
          - If a state-change trigger fires first, this deadline backstop is destroyed (not pending in the background).
          - If THIS deadline fires first (e.g., a hung watched session never transitioned), all the companion state-change watchers are destroyed.

          In either case, the woken-up turn starts with zero remaining scheduled wakes. If the woken-up turn decides to keep waiting (e.g., the wake fired prematurely on a transient flap, or the deadline hit but the watched session is still progressing), it MUST re-register the wakes it still needs — both the state-change watchers and a fresh deadline — before going back to sleep. The originals are gone.
        DESC
      end

      input_schema({
        type: "object",
        properties: {
          session_id: {
            oneOf: [ { type: "string" }, { type: "number" } ],
            description: "OPTIONAL — omit to wake the calling session. Session ID (numeric) or slug (string). Accepts sessions in needs_input or running state — from a running session, the sleep takes effect after the current turn ends."
          },
          wake_at: {
            type: "string",
            description: 'ISO 8601 datetime for when to wake up (e.g., "2026-04-15T14:30:00").'
          },
          timezone: {
            type: "string",
            description: 'Timezone for the wake_at datetime. Default: "UTC".'
          },
          prompt: {
            type: "string",
            description: "The prompt to send when waking up the session."
          }
        },
        required: [ "wake_at", "prompt" ]
      })

      def call(args)
        wake_at = require_arg(args, :wake_at).to_s
        prompt = require_arg(args, :prompt).to_s
        timezone = args["timezone"].presence || "UTC"

        session = requester_session(args)

        trigger = begin
          Sessions::ScheduleWakeUp.call(session: session, wake_at: wake_at, timezone: timezone, prompt: prompt)
        rescue Sessions::ScheduleWakeUp::Error => e
          raise ToolError, tool_error_message(e)
        end

        scheduled_at = trigger.trigger_conditions.first.scheduled_at

        <<~TEXT.strip
          ## Wake-Up Scheduled Successfully

          - **Session ID:** #{session.id}
          - **Wake At:** #{scheduled_at} (#{timezone})
          - **Trigger ID:** #{trigger.id}
          - **Trigger Name:** #{trigger.name}#{defaulted_requester_notice(session)}

          **You must end your conversation turn now.** The session will be automatically transitioned to waiting (immediately if currently needs_input; after the current turn ends if currently running) and resumed at the scheduled time with the provided prompt.

          ℹ️ **Cross-turn safety net:** If the scheduled wake-up fires before you end this turn, the wake-up prompt is durably queued onto the session via `enqueued_messages` and processed at the next turn boundary by Zimmer's pre-pause handoff — it is NOT silently dropped. Still end your turn promptly; queuing is the safety net, not a substitute for ending the turn.

          **Sibling-destroy reminder:** if this trigger is paired with `wake_me_up_when_session_changes_state` triggers (the triple-wake + deadline pattern), whichever wake fires first destroys ALL the others belonging to this requester. If this deadline fires while the watched session is still progressing, the woken-up turn must re-register the state-change watchers AND a new deadline before going back to sleep — the originals are gone.
        TEXT
      end

      private

      # The scheduler's rejection, plus the one remediation sentence that only
      # makes sense to a model: recompute against the server time the description
      # renders. The web UI's remediation is different, which is why it is spliced
      # on here rather than baked into Sessions::ScheduleWakeUp.
      def tool_error_message(error)
        return error.message unless error.code == :wake_at_too_soon

        "#{error.message} Recompute relative to the current server time shown in the tool description " \
          "and call again — wake_at must be more than #{WAKE_AT_GRACE_WINDOW.to_i} seconds in the future."
      end
    end
  end
end
