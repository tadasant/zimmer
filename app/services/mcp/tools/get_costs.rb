# frozen_string_literal: true

module Mcp
  module Tools
    # The read side of the token-spend ledger.
    #
    # Sits in the `health` group next to get_spot_policy for the same reason that
    # one does: this is the deployment's posture, not one session's business. An
    # agent asking "is this workload worth what it costs" needs the fleet view,
    # and a self_session connection has no reason to read the whole fleet's bill.
    class GetCosts < Tool
      tool_name "get_costs"

      description <<~DESC
        Read Zimmer's token-spend ledger: what inference cost, broken down by agent root, model,
        session, and kind of token.

        This is Zimmer's OWN accounting, not Anthropic's. Every API call an agent session made is
        stored with its token volumes; dollars are computed on read at current list prices, so the
        same rows re-price themselves when rates change. `get_spot_policy` answers "how much
        headroom is left in the quota window" from Anthropic's rate-limit headers — a different
        question from a different source. Neither substitutes for the other.

        Two populations are tracked:
        - **session usage** — inference an agent session did. The bulk of spend.
        - **ad hoc usage** — inference Zimmer's own code made outside any session (auto-generated
          session titles, push-notification summaries, the CLI status probe).

        Returns for the requested window:
        - totals: cost, tokens, API calls, and the session/ad-hoc split
        - cost breakdown by token kind (fresh input, output, cache read, cache write at each TTL) —
          usually the most informative view, because cache writes bill at up to 2x base input and
          routinely dominate a bill that looks like it should be about output
        - spend per day, so a spike can be placed in time
        - spend by agent root, by model, by main-thread vs subagent, by ad hoc source
        - the most expensive individual sessions
        - any model seen in the window that has no price configured
        - how complete the ledger is: whether the one-time historical sweep has finished, and the
          oldest call actually stored. Until that sweep completes the figures only cover spend
          since ingestion was deployed. The sweep runs itself; `action_health` with
          `backfill_token_usage` asks for a fresh one.

        **Use cases:**
        - Find which agent root or session a spend spike came from
        - Check what a change to an agent root's model or prompt actually cost
        - Establish the cost side of a cost-vs-performance comparison
        - Notice app-internal inference that should not be running at all

        **A caveat worth passing on:** list price is not a bill. These accounts are
        subscription-billed, so treat the dollar figures as a comparable unit across models rather
        than money owed.
      DESC

      MAX_DAYS = 365
      DEFAULT_DAYS = 7
      TOP_N = 10

      input_schema({
        type: "object",
        properties: {
          days: {
            type: "integer",
            description: "Window size in days, counting back from now. Default 7, max 365.",
            minimum: 1,
            maximum: MAX_DAYS
          },
          agent_root: {
            type: "string",
            description: "Restrict every figure to one agent root (e.g. \"zimmer-router\", \"issue-work-gate\")."
          },
          session_id: {
            type: "integer",
            description: "Restrict every figure to one session's spend."
          }
        },
        required: []
      })

      def call(args)
        days = (args["days"] || DEFAULT_DAYS).to_i.clamp(1, MAX_DAYS)
        analytics = CostAnalytics.new(from: days.days.ago)

        if args["session_id"].present?
          session_report(args["session_id"].to_i, analytics, days)
        elsif args["agent_root"].present?
          agent_root_report(args["agent_root"].to_s, analytics, days)
        else
          fleet_report(analytics, days)
        end
      end

      private

      def fleet_report(analytics, days)
        totals = analytics.totals
        return empty_notice(days) if totals[:api_calls].zero?

        lines = [
          "## Token spend — last #{days} #{"day".pluralize(days)}",
          "",
          "- **Total (list price):** #{money(totals[:cost_usd])}",
          "- **Session usage:** #{money(totals[:session_cost_usd])} · " \
          "**ad hoc:** #{money(totals[:adhoc_cost_usd])}",
          "- **Tokens:** #{number(totals[:total_tokens])} across #{number(totals[:api_calls])} API calls",
          "",
          "### Where the money goes",
          "",
          "| Component | Cost | Share |",
          "|---|---:|---:|"
        ]

        analytics.cost_breakdown.each do |row|
          lines << "| #{row[:component]} | #{money(row[:cost_usd])} | #{pct(row[:share])} |"
        end

        lines.concat(table("By agent root", "Agent root", analytics.by_agent_root, :agent_root, totals[:cost_usd]))
        lines.concat(table("By model", "Model", analytics.by_model, :model, totals[:cost_usd]))
        lines.concat(table("Main thread vs subagents", "Thread", analytics.by_thread_kind, :kind, totals[:cost_usd]))

        adhoc = analytics.by_adhoc_source
        lines.concat(table("Ad hoc calls from Zimmer's own code", "Source", adhoc, :source, totals[:cost_usd])) if adhoc.any?

        lines.concat(coverage_lines)
        lines.concat(by_day_lines(analytics))
        lines.concat(top_sessions_lines(analytics))
        lines.concat(unpriced_lines(analytics))
        lines << ""
        lines << "_List price, applied on read. Subscription-billed accounts — a comparable unit, not a bill._"
        lines.join("\n")
      end

      def agent_root_report(root, analytics, days)
        scope = analytics.session_scope.for_agent_root(root)
        totals = scope.totals
        return "No spend recorded for agent root `#{root}` in the last #{days} #{"day".pluralize(days)}." if totals[:api_calls].zero?

        fleet = analytics.totals[:cost_usd]
        [
          "## `#{root}` — last #{days} #{"day".pluralize(days)}",
          "",
          "- **Cost:** #{money(totals[:cost_usd])}#{fleet.positive? ? " (#{pct(totals[:cost_usd] / fleet)} of fleet)" : ""}",
          "- **Tokens:** #{number(totals[:total_tokens])} across #{number(totals[:api_calls])} API calls",
          "- **Cache write:** #{number(totals[:cache_creation_tokens])} · " \
          "**cache read:** #{number(totals[:cache_read_tokens])} · " \
          "**output:** #{number(totals[:output_tokens])}",
          "",
          "### By model",
          "",
          "| Model | Cost | Calls |",
          "|---|---:|---:|",
          *scope.group(:model).order(SessionTokenUsage.cost_sum_sql.desc)
            .pluck(:model, SessionTokenUsage.cost_sum_sql, Arel.sql("COUNT(*)"))
            .map { |model, cost, calls| "| `#{model}` | #{money(cost.to_f)} | #{number(calls)} |" }
        ].join("\n")
      end

      def session_report(session_id, analytics, days)
        scope = analytics.session_scope.where(session_id: session_id)
        totals = scope.totals
        return "No spend recorded for session ##{session_id} in the last #{days} #{"day".pluralize(days)}." if totals[:api_calls].zero?

        session = Session.find_by(id: session_id)
        main = scope.main_thread.totals
        sub = scope.subagents.totals

        [
          "## Session ##{session_id}#{session&.title ? " — #{session.title}" : ""}",
          "",
          "- **Cost (last #{days} #{"day".pluralize(days)}):** #{money(totals[:cost_usd])}",
          "- **Tokens:** #{number(totals[:total_tokens])} across #{number(totals[:api_calls])} API calls",
          "- **Main thread:** #{money(main[:cost_usd])} (#{number(main[:api_calls])} calls) · " \
          "**subagents:** #{money(sub[:cost_usd])} (#{number(sub[:api_calls])} calls)",
          "",
          "| Component | Tokens |",
          "|---|---:|",
          "| fresh input | #{number(totals[:input_tokens])} |",
          "| output | #{number(totals[:output_tokens])} |",
          "| cache read | #{number(totals[:cache_read_tokens])} |",
          "| cache write | #{number(totals[:cache_creation_tokens])} " \
          "(#{number(totals[:cache_creation_1h_tokens])} at the 1h TTL) |"
        ].join("\n")
      end

      def table(title, column, rows, key, total)
        return [] if rows.blank?

        lines = [ "", "### #{title}", "", "| #{column} | Cost | Share | Calls |", "|---|---:|---:|---:|" ]
        rows.first(TOP_N).each do |row|
          share = total.positive? ? pct(row[:cost_usd] / total) : "—"
          lines << "| #{row[key]} | #{money(row[:cost_usd])} | #{share} | #{number(row[:api_calls])} |"
        end
        lines
      end

      # The page and the REST API both carry a daily series; without it here an
      # agent can see a total but not that it doubled on Tuesday, which is the
      # question a spend spike actually raises.
      def by_day_lines(analytics)
        rows = analytics.by_day
        return [] if rows.blank?

        [
          "", "### Daily", "",
          "| Day | Cost | Calls |", "|---|---:|---:|",
          *rows.map { |r| "| #{r[:day]} | #{money(r[:cost_usd])} | #{number(r[:api_calls])} |" }
        ]
      end

      def top_sessions_lines(analytics)
        rows = analytics.top_sessions(limit: TOP_N)
        return [] if rows.blank?

        [
          "", "### Most expensive sessions", "",
          "| Session | Cost | Calls |", "|---|---:|---:|",
          *rows.map do |r|
            label = r[:title].presence ? "##{r[:session_id]} #{r[:title]}" : "##{r[:session_id]}"
            "| #{label} | #{money(r[:cost_usd])} | #{number(r[:api_calls])} |"
          end
        ]
      end

      # Every figure above is bounded by what has been ingested. Saying so is the
      # difference between "we spent $X" and "we have recorded $X of what we
      # spent", and only one of those is true before the historical sweep lands.
      def coverage_lines
        coverage = TokenUsageBackfill.coverage
        since = coverage[:covers_since] ? coverage[:covers_since].strftime("%b %-d, %Y") : "nothing yet"

        if coverage[:complete]
          [ "", "_Ledger covers #{since} onward; the historical backfill finished #{coverage[:finished_at]&.strftime("%b %-d, %Y")}._" ]
        else
          progress = coverage[:progress_pct] ? " (#{coverage[:progress_pct]}% swept)" : ""
          [
            "",
            "### ⚠️ Partial history",
            "",
            "The one-time backfill of historical transcripts is **#{coverage[:status]}**#{progress}, so these " \
            "figures cover only #{since} onward. It runs itself on a cron — no action needed unless it is stuck " \
            "(`last_error`: #{coverage[:last_error].presence || "none"})."
          ]
        end
      end

      def unpriced_lines(analytics)
        unpriced = analytics.unpriced_models
        return [] if unpriced.empty?

        [
          "", "### ⚠️ Unpriced models", "",
          "These appeared in the window and contribute **zero** to every figure above, " \
          "because `TokenPricing` has no rate for them: #{unpriced.map { |m| "`#{m}`" }.join(", ")}."
        ]
      end

      def empty_notice(days)
        "No token usage recorded in the last #{days} #{"day".pluralize(days)}. " \
        "Usage is swept out of transcripts by `TokenUsageIngestionJob` every ten minutes, and history " \
        "that predates it by `TokenUsageBackfillJob`, which runs itself. Current coverage: " \
        "#{TokenUsageBackfill.coverage[:status]}."
      end

      def money(value)
        "$#{ActiveSupport::NumberHelper.number_to_delimited(format("%.2f", value.to_f))}"
      end
      def number(value) = ActiveSupport::NumberHelper.number_to_delimited(value.to_i)
      def pct(fraction) = "#{(fraction.to_f * 100).round(1)}%"
    end
  end
end
