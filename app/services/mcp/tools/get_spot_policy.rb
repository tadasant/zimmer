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
        Read Zimmer's spot/priority scheduling policy, the live Claude Code usage rate, and the
        concurrency the spot gate is currently admitting.

        Every session runs as `priority` (always starts) or `spot`. Spot sessions fill the fleet up to
        the number of concurrent sessions the Claude Code quota can carry before a window lands on its
        target — the targets are a level to reach, not a line to stay clear of. Two brakes bound that:
        spot work stops outright once a window HAS reached its target and waits for utilization to come
        back down, and no more than `spot_max_concurrent_sessions` run at once. Every running session
        counts toward that cap, priority included, but only spot sessions are held by it. A held spot
        session is deferred, never cancelled: it stays `waiting` and starts on its own.

        A session's class is whichever of these speaks first: a class named for that session at spawn,
        the `scheduling_class` on the trigger that fired it, or the default for its **genesis** — where
        its line of work came from.

        Returns:
        - the gate setting (on/off, both window targets, and the max sessions at once)
        - the current decision: running or held, the reason, and the concurrent capacity
        - the usage rate: fraction of a quota window consumed per active session per hour
        - each window's utilization now and how many concurrent sessions it can carry
        - every genesis kind, its current class, and how many live sessions derive from it
        - every trigger that carries a class of its own

        **Use cases:**
        - Find out why a spot session has not started
        - Check for headroom before spawning a batch of automated sessions
        - Read the usage rate per active session
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
        # the same question differently: what a spot session starting right now
        # would actually get.
        decision = SpotGateService.current_decision
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
          "- **Active Claude Code sessions:** #{decision.active_sessions}"
        ]

        if decision.capacity
          lines.concat([
            "- **Concurrent spot capacity:** #{decision.capacity} " \
            "(never more than the #{decision.fleet_cap} sessions allowed at once)",
            "- **Forecast is for a fleet of:** #{decision.forecast_sessions} " \
            "(what is running, plus the session being decided about)",
            "- **Sized against:** #{decision.account_email} " \
            "(roomiest of #{decision.accounts_considered} usable Claude Code #{'account'.pluralize(decision.accounts_considered)})"
          ])
        end

        lines.concat(rate_lines(decision.rate))
        lines.concat(forecast_lines("5-hour", decision.forecast_5h))
        lines.concat(forecast_lines("Weekly", decision.forecast_7d))
        lines.concat(genesis_lines(classes, counts))
        lines.concat(trigger_lines)

        lines.join("\n")
      end

      private

      def rate_lines(rate)
        return [ "", "### Usage rate", "", "No rate available." ] if rate.nil?

        [
          "",
          "### Usage rate per active session",
          "",
          "- **5-hour window:** #{format_pct(rate.rate_5h_pct)} per session-hour",
          "- **Weekly window:** #{format_pct(rate.rate_7d_pct)} per session-hour",
          "- **Usable sample pairs:** #{rate.sample_count} (lookback #{(rate.lookback / 3600).round}h)",
          "- **Observed session-hours:** #{rate.session_hours.round(2)}",
          "- **Sufficient to forecast from:** #{rate.sufficient? ? "yes" : "no"}"
        ]
      end

      def forecast_lines(label, forecast)
        return [ "", "### #{label} window", "", "Not available." ] if forecast.nil?

        [
          "",
          "### #{label} window",
          "",
          "- **Current:** #{format_pct(forecast.current_pct)}",
          "- **Target:** #{format_pct(forecast.threshold_pct)}",
          "- **Concurrent sessions it can carry:** #{forecast.capacity || "no measurable burn"}",
          "- **Projected at that fleet size:** #{format_pct(forecast.projected_pct)} " \
          "in #{(forecast.horizon_hours * 60).round} minutes",
          "- **Over target:** #{forecast.breached? ? "yes" : "no"}"
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
