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

        Every session runs as `priority` (always starts) or `spot`. A spot session starts while some
        Claude Code account is still under both window targets AND a session slot is free. Nothing is
        forecast: when a window reaches its target, spot work pauses until utilization comes back down.
        Every running session counts toward the concurrency limit, priority included, but only spot
        sessions are held by it — priority work is meant to crowd spot work out. A held spot session is
        deferred, never cancelled: it stays `waiting` and starts on its own once a slot frees or the
        window falls.

        A session's class is whichever of these speaks first: a class named for that session at spawn,
        the `scheduling_class` on the trigger that fired it, or the default for its **genesis** — where
        its line of work came from.

        Returns:
        - the gate setting (on/off, both window targets, and the max sessions at once)
        - the current decision: running or held, the reason, and how many sessions are running
        - each window's utilization as last read, against its target
        - every genesis kind, its current class, and how many live sessions derive from it
        - every trigger that carries a class of its own

        **Use cases:**
        - Find out why a spot session has not started
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
          "- **Running Claude Code sessions:** #{decision.active_sessions}"
        ]

        if decision.account_email
          lines << "- **Windows read from:** #{decision.account_email} " \
                   "(most room of #{decision.accounts_considered} usable Claude Code " \
                   "#{'account'.pluralize(decision.accounts_considered)})"
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
          "- **At the target:** #{reading.at_limit? ? "yes — spot work is paused until it falls" : "no"}"
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
