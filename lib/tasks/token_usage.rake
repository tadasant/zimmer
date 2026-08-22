# frozen_string_literal: true

namespace :token_usage do
  desc "Run the historical backfill to completion in the foreground (idempotent; safe to re-run)"
  task backfill: :environment do
    # The backfill normally needs nobody: TokenUsageBackfillJob starts a run on
    # the first tick after a deploy and works it a slice at a time. This task is
    # the same object driven without a budget, for a developer who wants the
    # whole sweep now and wants to watch it. It resumes an in-flight run rather
    # than starting a second one.
    run = TokenUsageBackfill.request!(trigger: "manual")

    puts "Backfilling from #{run.transcript_root} (run ##{run.id}, #{run.status})"

    last_done = run.directories_done
    until run.complete?
      TokenUsageBackfillService.new(run: run, budget: 30.seconds).call
      run.reload

      if run.last_error.present?
        warn "  error: #{run.last_error}"
        break
      end

      printf(
        "  %d/%d directories — %d files, %d session rows, %d ad hoc rows\n",
        run.directories_done, run.directories_total,
        run.files_scanned, run.session_rows, run.adhoc_rows
      )
      break if run.directories_done == last_done && !run.complete?
      last_done = run.directories_done
    end

    puts
    puts run.complete? ? "Done in #{(run.finished_at - run.started_at).round}s" : "Stopped before completion"
    puts "  files scanned    : #{run.files_scanned}"
    puts "  session rows new : #{run.session_rows}"
    puts "  ad hoc rows new  : #{run.adhoc_rows}"
    puts "  session table    : #{SessionTokenUsage.count} rows"
    puts "  ad hoc table     : #{AdhocTokenUsage.count} rows"
    puts "  feature table    : #{TokenUsageFeature.count} rows"
  end

  desc "Reconcile context-feature attribution against real request totals"
  task attribution_report: :environment do
    days = Integer(ENV.fetch("DAYS", "7"))
    window = CostWindow.from_params(days: days)
    breakdown = window.analytics.by_feature

    puts "Context-feature attribution — #{window.label}"
    puts
    puts "  requests priced   : #{SessionTokenUsage.in_window(window.from, window.to).count}"
    puts "  attributed tokens : #{breakdown[:attributed_tokens]} of #{breakdown[:total_tokens]}"
    puts "  coverage          : #{(breakdown[:coverage] * 100).round(1)}%"
    puts "  residual tokens   : #{breakdown[:residual_tokens]}"
    puts "  residual cost     : $#{"%.2f" % breakdown[:residual_cost_usd]} of $#{"%.2f" % breakdown[:total_cost_usd]}"
    puts
    puts format("  %-22s %14s %14s %8s", "feature", "tokens", "cost", "share")
    breakdown[:rows].each do |row|
      share = breakdown[:total_cost_usd].positive? ? row[:cost_usd] / breakdown[:total_cost_usd] * 100 : 0
      puts format("  %-22s %14d %14s %7.1f%%", row[:feature], row[:tokens], "$#{"%.2f" % row[:cost_usd]}", share)
    end

    # The residual is expected to be large and is not a defect: the harness system
    # prompt and every attached MCP server's tool schemas are in the priced prompt
    # and in no transcript. Saying so here keeps a low coverage number from being
    # read as a broken detector.
    puts
    puts "  The residual is the fixed prompt prefix — harness system prompt and MCP tool"
    puts "  schemas — plus per-request server-tool charges. None of it appears in a"
    puts "  transcript, so none of it is attributed rather than guessed at."
  end

  desc "Measure characters-per-token on this deployment's own traffic"
  task calibrate_chars_per_token: :environment do
    # Between two consecutive requests in one conversation the fixed prompt prefix
    # cancels, so the change in billed input tokens over the change in transcript
    # characters reads the ratio directly. This is where
    # ContextFeatureAttributor::CHARS_PER_TOKEN comes from; re-run it if the
    # workload changes shape.
    root = ENV.fetch("TRANSCRIPT_ROOT", File.join(Dir.home, ".claude", "projects"))
    limit = Integer(ENV.fetch("FILES", "40"))
    files = Dir.glob(File.join(root, "*", "*.jsonl")).sort_by { |f| -File.mtime(f).to_i }.first(limit)

    ratios = []
    files.each do |path|
      cumulative = 0
      previous = nil
      seen = Set.new

      File.foreach(path) do |line|
        entry = begin
          JSON.parse(line)
        rescue JSON::ParserError
          next
        end
        next unless entry["type"] == "user" || entry["type"] == "assistant"

        message = entry["message"]
        cumulative += message ? JSON.generate(message).length : 0
        next unless entry["type"] == "assistant" && (request_id = entry["requestId"])
        next unless seen.add?(request_id)

        usage = message.is_a?(Hash) ? message["usage"] : nil
        next unless usage.is_a?(Hash)

        actual = usage["cache_read_input_tokens"].to_i + usage["cache_creation_input_tokens"].to_i +
                 usage["input_tokens"].to_i
        next if actual.zero?

        if previous && actual > previous[1] && cumulative > previous[0]
          delta_chars = cumulative - previous[0]
          delta_tokens = actual - previous[1]
          ratios << (delta_chars.to_f / delta_tokens) if delta_tokens > 500 && delta_chars > 2_000
        end
        previous = [ cumulative, actual ]
      end
    end

    if ratios.empty?
      puts "No consecutive-request pairs found in #{files.size} files."
      next
    end

    sorted = ratios.sort
    puts "#{ratios.size} consecutive-request pairs across #{files.size} transcripts"
    [ 0.1, 0.25, 0.5, 0.75, 0.9 ].each do |q|
      puts format("  p%-3d  %.2f chars/token", (q * 100).to_i, sorted[(q * (sorted.size - 1)).round])
    end
    puts format("  mean  %.2f", ratios.sum / ratios.size)
    puts format("  configured: %.2f (ContextFeatureAttributor::CHARS_PER_TOKEN)", ContextFeatureAttributor::CHARS_PER_TOKEN)
  end

  desc "Show what is currently stored, and how far back the ledger goes"
  task summary: :environment do
    coverage = TokenUsageBackfill.coverage
    puts "backfill: #{coverage[:status]}#{coverage[:progress_pct] ? " (#{coverage[:progress_pct]}%)" : ""}"
    puts "  ledger covers: #{coverage[:covers_since] || "nothing yet"} .. #{coverage[:covers_until] || "—"}"
    puts "  last error   : #{coverage[:last_error]}" if coverage[:last_error].present?
    puts

    [ SessionTokenUsage, AdhocTokenUsage ].each do |klass|
      totals = klass.totals
      puts "#{klass.table_name}:"
      puts "  api calls   : #{totals[:api_calls]}"
      puts "  tokens      : #{totals[:total_tokens]}"
      puts "  cost (list) : $#{"%.2f" % totals[:cost_usd]}"
      earliest = klass.minimum(:called_at)
      latest = klass.maximum(:called_at)
      puts "  window      : #{earliest} .. #{latest}"
      puts
    end
  end
end
