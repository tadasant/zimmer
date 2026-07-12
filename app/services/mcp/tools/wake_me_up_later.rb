# frozen_string_literal: true

module Mcp
  module Tools
    # Mirrors POST /api/v1/triggers with a one-time schedule condition bound to an
    # existing session (reuse_session + last_session_id).
    #
    # The sleep is NOT a separate step: Trigger's `after_create
    # :sleep_target_session_if_applicable` callback transitions the target session
    # to waiting (or sets pending_sleep on a running one) inside the same
    # transaction that persists the trigger. Creating the trigger IS the atomic
    # sleep+schedule, which is why this tool never calls Session#sleep! itself.
    class WakeMeUpLater < Tool
      tool_name "wake_me_up_later"

      # Reject wake-ups that resolve to <= 30 seconds in the future. Anything inside
      # this window is effectively "now" — and the past-dated case (the bug this
      # guards against) silently fires-and-drops in the scheduler, leaving the
      # session permanently asleep.
      WAKE_AT_GRACE_WINDOW = 30.seconds

      # Reject inputs that don't look like a calendar+time: bare dates ("2026-04-15"),
      # trailing offsets ("...+05:00"), and `Z` paired with a non-UTC IANA timezone
      # (ambiguous — we'd have to pick one to honor and the other to ignore).
      NAIVE_DATETIME_REGEX = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?Z?\z/
      EXPLICIT_OFFSET_REGEX = /[+-]\d{2}:?\d{2}\z/

      UTC_ZONE_NAMES = %w[UTC Etc/UTC].freeze

      # `needs_input` → immediate sleep; `running` → deferred sleep via pending_sleep
      # metadata; `waiting` → already dormant, the trigger fires normally. Anything
      # else (failed, archived) would silently no-op the auto-sleep and leave the
      # caller with a trigger targeting a session that can't be woken.
      WAKEABLE_STATUSES = %w[needs_input running waiting].freeze

      # The description interpolates the current server time, so it is rendered per
      # tools/list call rather than frozen at class-definition time — the model uses
      # it as the reference point for computing relative wake-ups.
      def self.description
        <<~DESC
          Schedule this session to be woken up at a specific time. The session will be put to sleep (waiting status) and a one-time trigger will fire at the specified time to resume it with the given prompt. If the session is manually resumed before the scheduled time, the trigger will be silently dropped.

          **IMPORTANT — Use this tool instead of workarounds.** When this tool is available, it is the correct way to schedule a delayed wake-up in a Zimmer context. Do NOT use these alternatives:
          - **Bash `sleep`**: Blocks the process and wastes compute resources for the entire sleep duration. The session remains "running" and cannot be reclaimed.
          - **Claude Code `ScheduleWakeup` tool**: Does not integrate with Zimmer's session lifecycle — it won't transition the session to sleeping/waiting state or create a Zimmer trigger, so Zimmer cannot track or manage the wake-up.
          - **Claude Code `Monitor` tool**: Same problem — it operates outside Zimmer's session state management.

          This tool creates a one-time Zimmer wake-up trigger bound to the target session. Creating the trigger atomically transitions the session to sleeping (waiting) state, so Zimmer can reclaim resources and the trigger is guaranteed to resume the correct session at the specified time.

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
          - **session_id**: The session to wake up. Works from either `needs_input` or `running` state — if you call this tool from within your own currently-running session, the sleep transition is recorded and takes effect after the current turn ends.
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
            description: "Session ID (numeric) or slug (string). Accepts sessions in needs_input or running state — from a running session, the sleep takes effect after the current turn ends."
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
        required: [ "session_id", "wake_at", "prompt" ]
      })

      def call(args)
        wake_at = require_arg(args, :wake_at).to_s
        prompt = require_arg(args, :prompt).to_s
        timezone = args["timezone"].presence || "UTC"

        # Cheapest validation runs first (no DB writes). A past-dated wake_at
        # silently fires-and-drops in the scheduler and leaves the session
        # permanently asleep, so reject it before any state change.
        wake_at_utc = parse_wake_at(wake_at, timezone)
        if wake_at_utc <= Time.current + WAKE_AT_GRACE_WINDOW
          raise ToolError, "wake_at \"#{wake_at}\" (timezone: #{timezone}) resolves to #{format_utc(wake_at_utc)} UTC, " \
                           "which is in the past or within 30 seconds of the current server time (#{format_utc(Time.current)} UTC). " \
                           "No trigger was created and no session state was changed. Recompute relative to the current server time " \
                           "shown in the tool description and call again — wake_at must be more than 30 seconds in the future."
        end

        session = find_session(args["session_id"])
        unless WAKEABLE_STATUSES.include?(session.status.to_s)
          raise ToolError, "Session #{session.id} is in \"#{session.status}\" state and cannot be scheduled for wake-up. " \
                           "Only sessions in #{WAKEABLE_STATUSES.join(', ')} can be woken up."
        end

        trigger = create_wake_trigger!(session, wake_at, timezone, prompt)

        <<~TEXT.strip
          ## Wake-Up Scheduled Successfully

          - **Session ID:** #{session.id}
          - **Wake At:** #{wake_at} (#{timezone})
          - **Trigger ID:** #{trigger.id}
          - **Trigger Name:** #{trigger.name}

          **You must end your conversation turn now.** The session will be automatically transitioned to waiting (immediately if currently needs_input; after the current turn ends if currently running) and resumed at the scheduled time with the provided prompt.

          ℹ️ **Cross-turn safety net:** If the scheduled wake-up fires before you end this turn, the wake-up prompt is durably queued onto the session via `enqueued_messages` and processed at the next turn boundary by Zimmer's pre-pause handoff — it is NOT silently dropped. Still end your turn promptly; queuing is the safety net, not a substitute for ending the turn.

          **Sibling-destroy reminder:** if this trigger is paired with `wake_me_up_when_session_changes_state` triggers (the triple-wake + deadline pattern), whichever wake fires first destroys ALL the others belonging to this requester. If this deadline fires while the watched session is still progressing, the woken-up turn must re-register the state-change watchers AND a new deadline before going back to sleep — the originals are gone.
        TEXT
      end

      private

      # Convert a naive ISO-8601 wall-clock string in `timezone` to an absolute
      # instant, using the same ActiveSupport::TimeZone#parse the scheduler itself
      # uses (TriggerCondition#schedule_due?) so validation and firing agree on
      # what the string means — including across DST boundaries.
      def parse_wake_at(wake_at, timezone)
        if wake_at.match?(EXPLICIT_OFFSET_REGEX)
          invalid_wake_at!(wake_at, timezone,
            'wake_at must not include a UTC offset (e.g., "+05:00"); pass the wall-clock time and an IANA timezone name (e.g., "America/New_York")')
        end

        unless wake_at.match?(NAIVE_DATETIME_REGEX)
          invalid_wake_at!(wake_at, timezone,
            'wake_at must be an ISO-8601 datetime like "2026-04-15T14:30:00" (date-only and other formats are not accepted)')
        end

        zone = ActiveSupport::TimeZone[timezone]
        invalid_wake_at!(wake_at, timezone, "\"#{timezone}\" is not a recognized IANA timezone name") if zone.nil?

        if wake_at.end_with?("Z") && !UTC_ZONE_NAMES.include?(timezone)
          invalid_wake_at!(wake_at, timezone,
            "wake_at ends with \"Z\" (UTC) but timezone is \"#{timezone}\". Either drop the trailing \"Z\" or set timezone to \"UTC\"")
        end

        parsed = begin
          zone.parse(wake_at.delete_suffix("Z"))
        rescue ArgumentError
          nil
        end
        invalid_wake_at!(wake_at, timezone, "Invalid wake_at value: \"#{wake_at}\"") if parsed.nil?

        parsed
      end

      def invalid_wake_at!(wake_at, timezone, detail)
        raise ToolError, "Could not parse wake_at \"#{wake_at}\" with timezone \"#{timezone}\": #{detail}. " \
                         "No trigger was created and no session state was changed."
      end

      def format_utc(time)
        time.utc.iso8601
      end

      def create_wake_trigger!(session, wake_at, timezone, prompt)
        Trigger.create!(
          name: "Wake session ##{session.id} at #{wake_at}",
          agent_root_name: trigger_agent_root_name(session),
          prompt_template: prompt,
          reuse_session: true,
          last_session_id: session.id,
          trigger_conditions_attributes: [
            {
              condition_type: "schedule",
              configuration: { "scheduled_at" => wake_at, "timezone" => timezone }
            }
          ]
        )
      rescue ActiveRecord::RecordInvalid => e
        raise ToolError, "Trigger creation failed: #{e.record.errors.full_messages.join(', ')}. " \
                         "The session is still in its original state — no changes were made."
      end

      # Trigger requires agent_root_name, but a per-session wake-up trigger
      # (reuse_session + last_session_id + a one-time condition) never spawns a new
      # session — the target session is always reused — so the value is only ever
      # bookkeeping. Prefer the catalog root the session resolves to; fall back to
      # the runtime for sessions that predate agent roots.
      def trigger_agent_root_name(session)
        session.agent_root_key.presence || session.agent_runtime
      end
    end
  end
end
