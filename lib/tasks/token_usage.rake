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
