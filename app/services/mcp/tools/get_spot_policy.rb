# frozen_string_literal: true

module Mcp
  module Tools
    # The read half of the spot/priority surface: everything the spot gate card on
    # /settings shows, in one call.
    #
    # An agent session that finds itself held needs to be able to answer "why, and
    # for how long" without a human reading the web UI to it — and an agent about
    # to spawn a batch of automated work should be able to check whether that work
    # will actually run before creating twenty sessions that all sit in `waiting`.
    class GetSpotPolicy < Tool
      tool_name "get_spot_policy"

      description <<~DESC
        Read Zimmer's spot/priority scheduling policy, the live Claude Code usage rate, and the current
        forecast the spot gate is acting on.

        Every session carries a **genesis** — where its line of work came from — and each genesis resolves
        to a class: `priority` (always starts) or `spot` (starts only while both Claude Code quota windows
        are forecast to stay under their configured ceilings). A held spot session is deferred, never
        cancelled: it stays `waiting` and starts on its own when headroom returns.

        Returns:
        - the gate setting (on/off and both threshold percentages)
        - the current decision, with the reason spot sessions are running or held
        - the usage rate: fraction of a quota window consumed per active session per hour
        - the 5-hour and weekly forecasts, with current and projected utilization
        - every genesis kind, its current class, whether that differs from the default, and how many
          live sessions carry it

        **Use cases:**
        - Find out why a spot session has not started
        - Check for headroom before spawning a batch of automated sessions
        - Read the usage rate per active session
        - See which genesis kinds are currently classified spot
      DESC

      input_schema({
        type: "object",
        properties: {},
        required: []
      })

      def call(_args)
        setting = AppSetting.current
        decision = SpotGateService.evaluate
        classes = SessionGenesis.effective_classes(setting.genesis_class_overrides)
        counts = Session.genesis_counts

        lines = [
          "## Spot / priority policy",
          "",
          "- **Gating enabled:** #{setting.spot_gating_enabled ? "yes" : "no"}",
          "- **5-hour window limit:** #{setting.spot_gate_five_hour_threshold_pct}%",
          "- **Weekly window limit:** #{setting.spot_gate_weekly_threshold_pct}%",
          "",
          "### Current decision",
          "",
          "- **Spot sessions:** #{decision.allowed? ? "running" : "HELD"}",
          "- **Reason:** `#{decision.reason}`",
          "- **Detail:** #{decision.detail}",
          "- **Active Claude Code sessions:** #{decision.active_sessions}"
        ]

        lines.concat(rate_lines(decision.rate))
        lines.concat(forecast_lines("5-hour", decision.forecast_5h))
        lines.concat(forecast_lines("Weekly", decision.forecast_7d))
        lines.concat(genesis_lines(classes, counts))

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
        return [ "", "### #{label} forecast", "", "Not available." ] if forecast.nil?

        [
          "",
          "### #{label} forecast",
          "",
          "- **Current:** #{format_pct(forecast.current_pct)}",
          "- **Projected at reset:** #{format_pct(forecast.projected_pct)}",
          "- **Threshold:** #{format_pct(forecast.threshold_pct)}",
          "- **Hours remaining in window:** #{forecast.hours_remaining.round(2)}",
          "- **Breached:** #{forecast.breached? ? "yes" : "no"}"
        ]
      end

      def genesis_lines(classes, counts)
        rows = SessionGenesis::KINDS.map do |kind|
          current = classes[kind.key]
          changed = current != kind.default_class ? " (changed from #{kind.default_class})" : ""
          "| `#{kind.key}` | #{kind.label} | **#{current}**#{changed} | #{counts[kind.key].to_i} |"
        end

        [
          "",
          "### Genesis kinds",
          "",
          "| Key | Label | Class | Live sessions |",
          "| --- | --- | --- | --- |",
          *rows,
          "",
          "Change a class with `action_spot_policy` (action `promote_genesis` / `demote_genesis`). " \
          "Doing so reclassifies every session of that genesis, including existing ones."
        ]
      end

      def format_pct(value)
        return "unknown" if value.nil?

        "#{value.round(2)}%"
      end
    end
  end
end
