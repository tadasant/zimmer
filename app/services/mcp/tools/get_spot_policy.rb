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

        Every session runs as `priority` (always starts) or `spot`. Zimmer models each Claude quota
        window in DOLLARS: a calibrated estimate of what a full window is worth in Opus spend, a
        `priority reserve` carved out of it (the operator sets a percentage; the money is derived), and
        the non-reserved remainder that spot work is expected to consume in full before the window rolls
        over.

        Spot work is released on a smooth just-in-time curve rather than at a percentage cliff. A spot
        session runs while THREE things hold: the money it is projected to spend keeps total spend inside
        the non-reserved budget, the fleet's burn rate stays under what the window can sustain from here
        (`remaining spot budget / time left in the window` — the rate that lands on 100% exactly at
        rollover), and a session slot is free. Because the sustainable rate is recomputed from what is
        LEFT over the time LEFT, a quiet window releases work faster and a busy one throttles, so there
        is work happening at every hour instead of a burst and then an idle stretch. When nothing at all
        is running the pace test is waived — a session is not infinitely divisible, and a deployment
        whose single-session burn exceeds its sustainable rate should still do work in a duty cycle
        rather than none. The reserve is never waived.

        That covers every spot TURN, not just first starts — a session woken by a trigger, a follow-up, a
        poller or a restart is deferred the same way, so while a window is ahead of its curve the only
        way a spot-designated session runs is to be promoted to priority first. A held or paused session
        goes dormant in `waiting` and comes back on its own — a paused one once the fleet is back under
        the curve with a few points of the window to spare, a held one at the re-check its
        `spot_hold_retry_at` names.

        THREE different ceilings hold spot work, and `ceiling` in the output names which one is doing it,
        because they clear in three different ways:

        - `fleet_cap` — every session slot is taken. Clears when a running session finishes.
        - `spot_budget` — a window's non-reserved budget is spent. The ONLY ceiling that also pauses spot
          sessions already running, and the only one a clock fixes: the money comes back at rollover.
        - `pacing_curve` — the budget still has room, but the fleet is spending it faster than the window
          can carry. New turns wait at the door; work already running is never interrupted for this. It
          clears when the fleet's burn falls, which is running sessions ending — waiting does not do it,
          because the sustainable rate is the budget left over the time left and keeps falling while the
          fleet outruns it.

        `spot_budget` and `pacing_curve` share the reason string `at_utilization_limit` on the wire; it
        is persisted on sessions and cannot be split without breaking their banners, so read `ceiling`
        rather than the reason when you need to tell them apart.

        Windows are read ON AVERAGE across every account, including ones in needs_reauth. When a window
        has no usable dollar estimate yet, the same curve is applied to percentages instead and the
        output says so — an estimate is never presented as a measurement.
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
        - the gate setting (on/off, both priority reserves as a percentage AND as dollars, and the max
          sessions at once)
        - the current decision: running or held, the reason, which ceiling is holding, and how many
          sessions are running
        - when the hold lifts, as far as the model can honestly say — for two of the three ceilings that
          is a condition rather than a time, and it is stated as one instead of being dressed up as an ETA
        - what the running fleet is burning in $/min, and what one more session is projected to add
        - the two dormant spot populations, both in `waiting` and NOT running, so both are unrelated to
          the concurrency limit and routinely exceed it: the ones the budget ceiling PAUSED mid-run (the
          ceiling sweep brings those back), and the ones the gate HELD before a turn (their own re-check
          brings those back). A held session past its own re-check time is reported separately as overdue —
          its ladder has stopped, and `SpotHoldSweepJob` is what puts it back on
        - each window in full: estimated capacity, dollars remaining, dollars reserved, spot budget left,
          how long until it rolls over, the sustainable burn rate that empties it exactly then, and where
          the pacing curve says the window should be right now
        - every genesis kind, its current class, and how many live sessions derive from it
        - every trigger that carries a class of its own

        **Use cases:**
        - Find out why a spot session has not started, or why its next turn has not run
        - Check for room before spawning a batch of automated sessions — in dollars, not percentages
        - See how much capacity is left this window and how much of it priority work has reserved
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
        paused_count = SpotSessionPause.paused_count
        # The second dormant population: sessions the gate refused BEFORE a
        # turn. Reporting only `paused_count` under a heading that reads like
        # every dormant spot session answers "asleep in the spot queue: 0" on a
        # deployment holding session 7507 (tadasant/zimmer#648).
        held_count = SpotSessionHold.held_count
        overdue_hold_count = SpotSessionHold.overdue_count
        explanation = SpotHoldExplanation.new(
          decision,
          paused_count: paused_count,
          held_count: held_count,
          overdue_hold_count: overdue_hold_count
        )
        classes = SessionGenesis.effective_classes(setting.genesis_class_overrides)
        counts = Session.genesis_counts

        lines = [
          "## Spot / priority policy",
          "",
          "- **Gating enabled:** #{setting.spot_gating_enabled ? "yes" : "no"}",
          "- **5-hour priority reserve:** #{reserve_phrase(setting.spot_reserve_five_hour_pct, decision.five_hour)}",
          "- **Weekly priority reserve:** #{reserve_phrase(setting.spot_reserve_weekly_pct, decision.weekly)}",
          "- **Max sessions at once:** #{setting.spot_max_concurrent_sessions} " \
          "(every running session counts, priority included; only spot sessions wait for a slot)",
          "",
          "### Current decision",
          "",
          "- **Spot sessions:** #{decision.allowed? ? "running" : "HELD"}",
          "- **Reason:** `#{decision.reason}`",
          "- **Ceiling holding spot work:** #{decision.ceiling ? "`#{decision.ceiling}`" : "none"}",
          "- **Detail:** #{decision.detail}",
          # The same two lines the /quotas card renders, from the same object, so
          # an agent reading this tool and a human reading the page are told the
          # same thing about which ceiling is holding and what lifts it.
          *explanation.lines.map { |line| "- **#{line.label}:** #{line.sentence}" },
          "- **Running Claude Code sessions:** #{decision.active_sessions}",
          "- **Fleet burn rate:** #{rate(decision.fleet_burn_usd_per_minute)} " \
          "(every running session, priority included — they spend against the same windows)",
          "- **One more session would add:** #{rate(decision.candidate_burn_usd_per_minute)} " \
          "(from the last #{HarnessModelBurnRate::SAMPLE_SESSIONS} sessions of its harness+model combination, " \
          "or the fleet average when that combination has never been sampled)",
          # The decision above is about a session TAKING A TURN — its first or its
          # next. This is the standing population the `spot_budget` ceiling has
          # already stopped: sessions dormant in `waiting`, not running ones, so
          # this figure has nothing to do with the concurrency limit and is
          # regularly larger than it. Same number the /quotas card shows.
          "- **Spot sessions paused mid-run by the ceiling:** #{paused_count}. #{explanation.sessions_asleep}",
          # Same two figures the /quotas card renders, from the same object, so a
          # human reading the page and an agent reading this tool are told the
          # same thing about who is asleep and whose ladder has stopped.
          "- **Spot sessions held before a turn:** #{held_count}" \
          "#{overdue_hold_count.positive? ? ", #{overdue_hold_count} of them overdue for a re-check" : ''}. " \
          "#{explanation.sessions_held}"
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

      # One window, in the units the model actually has for it. Dollars when the
      # calibration has produced a usable estimate; percentages of the window
      # when it has not, said out loud rather than dressed up as money.
      def window_lines(label, reading)
        return [ "", "### #{label} window", "", "No reading available." ] if reading.nil?

        window = reading.window
        head = [
          "",
          "### #{label} window",
          "",
          "- **Utilization now:** #{format_pct(reading.current_pct)}",
          "- **Priority reserve:** #{window.reserve_pct}% of the window",
          "- **Rolls over in:** #{duration(window.seconds_remaining)}" \
          "#{window.elapsed_fraction ? " (#{format_pct(window.elapsed_fraction * 100)} through it)" : ""}"
        ]

        body = if window.dollars?
          [
            "- **Estimated capacity:** #{money(window.capacity_usd)} of Opus spend",
            "- **Remaining:** #{money(window.remaining_usd)}",
            "- **Reserved for priority:** #{money(window.reserve_usd)}",
            "- **Spot budget left:** #{money(window.remaining_spot_usd)} of #{money(window.spot_budget_usd)}",
            "- **Sustainable burn from here:** #{rate(finite(window.sustainable_units_per_minute))} " \
            "(what empties the spot budget exactly as the window rolls over)",
            "- **Projected with one more session:** #{rate(reading.burn_units_per_minute)}",
            "- **Estimate derived from:** #{money(window.estimate&.sample_cost_usd)} of spend at " \
            "#{format_pct(window.estimate&.sample_utilization.to_f * 100)} pooled utilization" \
            "#{window.estimate&.computed_at ? ", #{time_ago_in_words(window.estimate.computed_at)} ago" : ""}"
          ]
        else
          [
            "- **Estimated capacity:** not calibrated yet — this window is paced on percentages",
            "- **Spot budget:** #{format_pct(reading.spot_budget_pct)} of the window",
            "- **Pacing curve says:** #{reading.pace_pct ? format_pct(reading.pace_pct) : "unknown — no rollover time"}"
          ]
        end

        head + body + [
          "- **Has room for a spot session:** #{reading.at_limit? ? "no — #{reading.why_held}" : "yes"}"
        ]
      end

      # The reserve as the operator set it AND as the model derives it. Both, in
      # one line, because the percentage is the control and the dollars are what
      # the gate decides on — showing only one of them hides half the policy.
      def reserve_phrase(pct, reading)
        derived = reading&.window&.reserve_usd
        return "#{pct}% (#{money(derived)} of the estimated window)" if derived

        "#{pct}% of the window (no dollar estimate for this window yet)"
      end

      def money(value)
        return "unknown" if value.nil?
        return "unknown" if value.respond_to?(:infinite?) && value.infinite?

        # `format` before delimiting, so $1,234.50 keeps its trailing zero —
        # `number_to_delimited(1234.5)` renders "1,234.5", which reads as a
        # truncated figure rather than as money.
        "$#{ActiveSupport::NumberHelper.number_to_delimited(format("%.2f", value))}"
      end

      def rate(value)
        return "unknown" if value.nil?

        "#{money(value)}/min"
      end

      # An infinite sustainable rate is what the last seconds of a window look
      # like; it is true and useless to print, so it reads as unknown.
      def finite(value) = value.nil? || value.infinite? ? nil : value

      def duration(seconds)
        return "unknown" if seconds.nil?

        ActiveSupport::Duration.build(seconds).inspect
      end

      def time_ago_in_words(time)
        ActionController::Base.helpers.time_ago_in_words(time)
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
