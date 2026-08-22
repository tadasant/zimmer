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
        - spend by **context-management feature** — the injected goal block, the session hierarchy,
          MCP responses, skill bodies, thinking, tool output — with the share it could not account
          for stated as its own line
        - spend split by **experimental setting** — every session is tagged with what each
          experimental toggle was when it started and when it last ran, and the two cohorts are
          compared
        - the most expensive individual sessions
        - any model seen in the window that has no price configured
        - how complete the ledger is: whether the one-time historical sweep has finished, and the
          oldest call actually stored. Until that sweep completes the figures only cover spend
          since ingestion was deployed. The sweep runs itself; `action_health` with
          `backfill_token_usage` asks for a fresh one.

        **The feature figures are ESTIMATES, and must be quoted as such.** The API reports one usage
        total per request with no per-feature decomposition, so the split is derived from transcript
        content: characters measured per feature, converted at a fixed ratio, and scaled so the parts
        can never exceed a request's real totals. Whatever is left over is reported as unattributed
        rather than spread across the features — most of it is the harness system prompt and the tool
        schemas, which never appear in a transcript. Do not present an estimated feature cost as a
        measurement, and do not recommend cutting a feature on a thin margin.

        **The experiment cohorts are OBSERVATIONAL, and must be quoted as such.** The settings are
        global, so a cohort is "every session that ran while it was on" — nothing is randomized. For
        a setting labelled from the date it landed, the cohorts are literally "before this date" and
        "after this date", which perfectly confounds the setting with everything else that changed
        around then. Cost per API call is reported as the headline because it divides out session
        length; per-session cost is reported too and is mostly task mix. Sessions whose start and
        end values disagree are excluded from both cohorts rather than averaged in. Do not report a
        cohort difference as an effect of the setting, and do not report one at all when the tool
        says the sides are too small to compare.

        **Use cases:**
        - Find which agent root or session a spend spike came from
        - Check what a change to an agent root's model or prompt actually cost
        - Decide whether a context-management feature earns what it costs, or should move to a
          cheaper model
        - Establish the cost side of a cost-vs-performance comparison
        - Notice app-internal inference that should not be running at all

        **A caveat worth passing on:** list price is not a bill. These accounts are
        subscription-billed, so treat the dollar figures as a comparable unit across models rather
        than money owed.
      DESC

      MAX_DAYS = CostWindow::MAX_DAYS
      DEFAULT_DAYS = CostWindow::DEFAULT_DAYS
      TOP_N = 10

      input_schema({
        type: "object",
        properties: {
          days: {
            type: "integer",
            description: "Window size in days, counting back from now. Default 7, max 365. " \
                         "Ignored when `from` or `to` is given.",
            minimum: 1,
            maximum: MAX_DAYS
          },
          from: {
            type: "string",
            description: "Start of an explicit calendar window, as YYYY-MM-DD. Inclusive, from the " \
                         "start of that day in the deployment's time zone. Pairs with `to`; either " \
                         "may be given alone. Spans longer than 365 days are clamped to the most " \
                         "recent 365."
          },
          to: {
            type: "string",
            description: "End of an explicit calendar window, as YYYY-MM-DD. Inclusive, through the " \
                         "END of that day. Defaults to today when only `from` is given."
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
        # The same object the Costs page resolves its window with, so a preset and
        # a calendar range mean exactly the same thing on both surfaces.
        window = CostWindow.from_params(days: args["days"], from: args["from"], to: args["to"])
        analytics = window.analytics

        if args["session_id"].present?
          session_report(args["session_id"].to_i, analytics, window)
        elsif args["agent_root"].present?
          agent_root_report(args["agent_root"].to_s, analytics, window)
        else
          fleet_report(analytics, window)
        end
      end

      private

      def fleet_report(analytics, window)
        totals = analytics.totals
        return empty_notice(window) if totals[:api_calls].zero?

        lines = [
          "## Token spend — #{window.label}",
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
        lines.concat(feature_lines(analytics.by_feature))
        lines.concat(experiment_lines(analytics.by_experiment))
        lines.concat(by_day_lines(analytics))
        lines.concat(top_sessions_lines(analytics))
        lines.concat(unpriced_lines(analytics))
        lines << ""
        lines << "_List price, applied on read. Subscription-billed accounts — a comparable unit, not a bill._"
        lines.join("\n")
      end

      def agent_root_report(root, analytics, window)
        scope = analytics.session_scope.for_agent_root(root)
        totals = scope.totals
        return "No spend recorded for agent root `#{root}` over #{window.label}." if totals[:api_calls].zero?

        fleet = analytics.totals[:cost_usd]
        [
          "## `#{root}` — #{window.label}",
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
            .map { |model, cost, calls| "| `#{model}` | #{money(cost.to_f)} | #{number(calls)} |" },
          # The drilldown this root-scoped report exists for: which of the bytes
          # this root carries were context management rather than the work.
          *feature_lines(analytics.feature_breakdown(agent_root: root))
        ].join("\n")
      end

      def session_report(session_id, analytics, window)
        scope = analytics.session_scope.where(session_id: session_id)
        totals = scope.totals
        return "No spend recorded for session ##{session_id} over #{window.label}." if totals[:api_calls].zero?

        session = Session.find_by(id: session_id)
        main = scope.main_thread.totals
        sub = scope.subagents.totals

        [
          "## Session ##{session_id}#{session&.title ? " — #{session.title}" : ""}",
          "",
          "- **Cost (#{window.label}):** #{money(totals[:cost_usd])}",
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
          "(#{number(totals[:cache_creation_1h_tokens])} at the 1h TTL) |",
          *feature_lines(analytics.feature_breakdown(session_id: session_id))
        ].join("\n")
      end

      # The experimental-setting cohorts, with the reasons not to trust them
      # attached. An agent quoting a delta downstream will quote whatever framing
      # rides with it, so the framing is in the table, not below it.
      def experiment_lines(reports)
        reports = Array(reports).reject { |r| r[:tagged_sessions].to_i.zero? }
        return [] if reports.empty?

        lines = [ "", "### Experimental settings (observational, not randomized)", "" ]

        reports.each do |report|
          off = report[:cohorts]["off"]
          on = report[:cohorts]["on"]
          comparison = report[:comparison]

          lines << "**#{report[:title]}** — currently " \
                   "#{report[:current_value].nil? ? "unknown" : (report[:current_value] ? "ON" : "OFF")}"
          lines << ""
          lines << "| Cohort | Sessions | Calls | Cost | Per call | Per session |"
          lines << "|---|---:|---:|---:|---:|---:|"
          %w[off on].each do |cohort|
            side = report[:cohorts][cohort]
            lines << "| #{cohort} | #{number(side[:sessions])} | #{number(side[:api_calls])} | " \
                     "#{money(side[:cost_usd])} | #{per_call(side[:cost_per_call])} | " \
                     "#{side[:cost_per_session] ? money(side[:cost_per_session]) : "—"} |"
          end
          lines << ""

          if comparison[:comparable]
            direction = comparison[:cost_per_call_change].negative? ? "lower" : "higher"
            lines << "Cost per API call is #{pct(comparison[:cost_per_call_change].abs)} #{direction} with " \
                     "the setting on. This is an association, not a measured effect."
          elsif comparison[:reason] == :no_baseline
            lines << "No baseline to compare against: the off cohort priced at $0.00, so every model it " \
                     "ran is missing a rate. Do not quote a difference from these figures."
          else
            lines << "Too few sessions to compare: a side needs at least #{comparison[:min_sessions]} " \
                     "sessions and #{comparison[:min_calls]} API calls in this window. " \
                     "Do not quote a difference from these figures."
          end

          mixed = report[:cohorts]["mixed"]
          if mixed[:sessions].positive?
            lines << "#{number(mixed[:sessions])} session(s) had the setting toggled mid-run and are in neither cohort."
          end

          if report[:landed_at]
            lines << "Cohorts are temporal: the setting landed #{report[:landed_at].utc.iso8601}, so " \
                     "\"off\" is every session before that and \"on\" is every session after. " \
                     "#{number(report[:tagged_by_source]["backfilled"].to_i)} of " \
                     "#{number(report[:tagged_sessions])} labels were inferred from dates rather than observed."
          end
          lines << ""
        end

        lines
      end

      # The context-feature split, with its residual. Reported as an estimate every
      # time it appears, because an agent quoting this figure downstream will quote
      # the label with it.
      def feature_lines(breakdown)
        rows = breakdown[:rows]
        return [] if rows.blank?

        total = breakdown[:total_cost_usd]
        lines = [
          "", "### Context features (estimated)", "",
          "| Feature | Owner | Cost | Share | Tokens |", "|---|---|---:|---:|---:|"
        ]

        rows.first(TOP_N).each do |row|
          definition = ContextFeatureRegistry.find(row[:feature])
          share = total.positive? ? pct(row[:cost_usd] / total) : "—"
          lines << "| #{definition&.label || row[:feature]} | #{definition&.owner || "?"} | " \
                   "#{money(row[:cost_usd])} | #{share} | #{number(row[:tokens])} |"
        end

        residual_share = total.positive? ? pct(breakdown[:residual_cost_usd] / total) : "—"
        lines << "| _unattributed_ | — | #{money(breakdown[:residual_cost_usd])} | #{residual_share} | " \
                 "#{number(breakdown[:residual_tokens])} |"
        lines << ""
        lines << "_Estimated from transcript content, not measured — see this tool's description. " \
                 "#{pct(breakdown[:coverage])} of tokens were attributed; the rest is the harness " \
                 "system prompt, the tool schemas of the session's MCP servers, and per-request " \
                 "server-tool charges, none of which a transcript records._"
        lines
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
        progress = coverage[:progress_pct] ? " (#{coverage[:progress_pct]}% swept)" : ""

        if coverage[:status] == "complete"
          [ "", "_Ledger covers #{since} onward; the historical backfill finished #{coverage[:finished_at]&.strftime("%b %-d, %Y")}._" ]
        elsif coverage[:complete]
          # History is in and something is re-scanning it. The figures are whole;
          # saying "partial" here would be false.
          [ "", "_Ledger covers #{since} onward. A re-scan of the corpus is #{coverage[:status]}#{progress}._" ]
        else
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

      def empty_notice(window)
        "No token usage recorded over #{window.label}. " \
        "Usage is swept out of transcripts by `TokenUsageIngestionJob` every ten minutes, and history " \
        "that predates it by `TokenUsageBackfillJob`, which runs itself. Current coverage: " \
        "#{TokenUsageBackfill.coverage[:status]}."
      end

      def money(value)
        "$#{ActiveSupport::NumberHelper.number_to_delimited(format("%.2f", value.to_f))}"
      end
      def number(value) = ActiveSupport::NumberHelper.number_to_delimited(value.to_i)
      def pct(fraction) = "#{(fraction.to_f * 100).round(1)}%"

      # Per-call cost is cents-and-below on every real window, so `money`'s two
      # decimal places would round the whole column to $0.00.
      def per_call(value) = value.nil? ? "—" : "$#{format("%.4f", value.to_f)}"
    end
  end
end
