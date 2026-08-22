# frozen_string_literal: true

module Mcp
  module Tools
    # The read half of the spot/priority surface: everything the spot gate card on
    # /quotas shows, in one call.
    #
    # An agent session that finds itself held needs to be able to answer "why, and
    # for how long" without a human reading the web UI to it — and an agent about
    # to spawn a batch of automated work should be able to check whether that work
    # will actually run before creating twenty sessions that all sit in `waiting`.
    class GetSpotPolicy < Tool
      tool_name "get_spot_policy"

      description <<~DESC
        Read Zimmer's spot/priority scheduling policy and the live decision the spot gate is making.

        Every session runs as `priority` (always starts) or `spot`. A spot session runs while the
        Claude Code account pool is under both window targets ON AVERAGE — across every account, including
        ones in needs_reauth — AND a session slot is free. Nothing is forecast: when a window reaches its
        target, spot work stops until utilization comes back down. That covers every spot TURN, not just
        first starts — a session woken by a trigger, a follow-up, a poller or a restart is deferred the
        same way, so while a window is at its target the only way a spot-designated session runs is to be
        promoted to priority first. Spot sessions already running are paused mid-run as well, so the
        window stops climbing instead of filling to 100%. A held or paused session goes dormant in
        `waiting` and comes back on its own — a paused one once utilization falls a few points below the
        target, a held one at the re-check its `spot_hold_retry_at` names.
        Every running session counts toward the concurrency limit, priority included, but only spot
        sessions are held by it — priority work is meant to crowd spot work out. The concurrency limit is
        skipped only for a session that is ALREADY running when the gate runs, since it is counted in the
        fleet itself; a turn already deferred once is dormant and holds no slot, so the limit applies to
        its re-check in full. A held spot session is deferred, never cancelled: it stays `waiting`, and
        the prompt that woke it is queued with the re-check rather than dropped.

        A session's class is whichever of these speaks first: a class named for that session at spawn,
        the `scheduling_class` on the trigger that fired it, or the default for its **genesis** — where
        its line of work came from.

        Returns:
        - the gate setting (on/off, both window targets, and the max sessions at once)
        - the current decision: running or held, the reason, and how many sessions are running
        - how many running spot sessions are currently paused for the ceiling, and what brings them back
        - each window's utilization as last read across the pool, against its target
        - every genesis kind, its current class, and how many live sessions derive from it
        - every trigger that carries a class of its own

        **Use cases:**
        - Find out why a spot session has not started, or why its next turn has not run
        - Check for room before spawning a batch of automated sessions
        - See which origins are currently classified spot
      DESC

      # Enough to see the shape of the policy without turning a read into a trigger
      # dump; `search_triggers` is the tool for the full list.
      TRIGGER_LIST_LIMIT = 25

      input_schema({
        type: "object",
        properties: {},
        required: []
      })

      def call(_args)
        setting = AppSetting.current
        # The same method /quotas renders, so the page and this tool cannot answer
        # the same question differently.
        decision = SpotGateService.evaluate
        classes = SessionGenesis.effective_classes(setting.genesis_class_overrides)
        counts = Session.genesis_counts

        lines = [
          "## Spot / priority policy",
          "",
          "- **Gating enabled:** #{setting.spot_gating_enabled ? "yes" : "no"}",
          "- **5-hour window target:** #{setting.spot_gate_five_hour_threshold_pct}%",
          "- **Weekly window target:** #{setting.spot_gate_weekly_threshold_pct}%",
          "- **Max sessions at once:** #{setting.spot_max_concurrent_sessions} " \
          "(every running session counts, priority included; only spot sessions wait for a slot)",
          "",
          "### Current decision",
          "",
          "- **Spot sessions:** #{decision.allowed? ? "running" : "HELD"}",
          "- **Reason:** `#{decision.reason}`",
          "- **Detail:** #{decision.detail}",
          "- **Running Claude Code sessions:** #{decision.active_sessions}",
          # The decision above is about a session TAKING A TURN — its first or its
          # next. This is the same policy applied to the ones already mid-turn,
          # which is what keeps the target a ceiling on spend rather than a floor
          # under when new work stops. Same number the /quotas card shows.
          "- **Spot sessions paused mid-run:** #{SpotSessionPause.paused_count} " \
          "(paused while a window sits at its target; they resume automatically once utilization " \
          "falls #{SpotGateService::RESUME_MARGIN_PCT} points below it, and priority sessions are never paused)"
        ]

        if decision.pool_size
          counted = decision.accounts_read == decision.pool_size ? "all #{decision.pool_size}" : "#{decision.accounts_read} of #{decision.pool_size}"
          lines << "- **Windows averaged across:** #{counted} " \
                   "#{"account".pluralize(decision.pool_size)} in the pool " \
                   "(every status counts, needs_reauth included; an account whose 7-day window is " \
                   "spent counts as 100% in the 5-hour figure)"
        end

        lines.concat(window_lines("5-hour", decision.five_hour))
        lines.concat(window_lines("Weekly", decision.weekly))
        lines.concat(genesis_lines(classes, counts))
        lines.concat(trigger_lines)

        lines.join("\n")
      end

      private

      def window_lines(label, reading)
        return [ "", "### #{label} window", "", "No reading available." ] if reading.nil?

        [
          "",
          "### #{label} window",
          "",
          "- **Utilization now:** #{format_pct(reading.current_pct)}",
          "- **Target:** #{format_pct(reading.threshold_pct)}",
          "- **At the target:** #{reading.at_limit? ? "yes — spot work is paused until it falls, running sessions included" : "no"}"
        ]
      end

      def genesis_lines(classes, counts)
        rows = SessionGenesis::KINDS.map do |kind|
          current = classes[kind.key]
          changed = current != kind.default_class ? " (changed from #{kind.default_class})" : ""
          where = SessionGenesis.settable?(kind.key) ? "`action_spot_policy`" : "the trigger"
          "| `#{kind.key}` | #{kind.label} | **#{current}**#{changed} | #{counts[kind.key].to_i} | #{where} |"
        end

        [
          "",
          "### Genesis kinds",
          "",
          "The class each kind falls back to. `Live sessions` counts only the sessions that actually " \
          "derive it — a session given a class of its own is not moved by changing its kind.",
          "",
          "| Key | Label | Default class | Live sessions | Set it via |",
          "| --- | --- | --- | --- | --- |",
          *rows,
          "",
          "Change a settable kind with `action_spot_policy` (action `promote_genesis` / `demote_genesis`); " \
          "that reclassifies every deriving session of that genesis, including existing ones. The " \
          "trigger-backed kinds are set per trigger with `action_trigger`."
        ]
      end

      # Only the triggers that carry a class of their own. Every trigger has an
      # effective class, but listing all of them would bury the handful an
      # operator actually chose — and those are the ones that explain why two
      # sessions of the same genesis are scheduled differently.
      def trigger_lines
        chosen = Trigger.where.not(scheduling_class: nil).order(:name).limit(TRIGGER_LIST_LIMIT).to_a
        total = Trigger.where.not(scheduling_class: nil).count
        return [ "", "### Triggers with their own class", "", "None — every trigger derives its class from its condition type." ] if total.zero?

        rows = chosen.map { |t| "| #{t.id} | #{t.name} | **#{t.scheduling_class}** | #{t.status} |" }
        more = total > chosen.size ? [ "", "…and #{total - chosen.size} more. Use `search_triggers` for the full list." ] : []

        [
          "",
          "### Triggers with their own class",
          "",
          "| ID | Name | Class | Status |",
          "| --- | --- | --- | --- |",
          *rows,
          *more
        ]
      end

      def format_pct(value)
        return "unknown" if value.nil?

        "#{value.round(2)}%"
      end
    end
  end
end
