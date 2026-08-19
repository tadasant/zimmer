# frozen_string_literal: true


require "tmpdir"
namespace :token_usage do
  desc "Backfill token usage from every transcript on disk (idempotent; safe to re-run)"
  task backfill: :environment do
    root = ENV.fetch("TRANSCRIPT_ROOT", File.join(Dir.home, ".claude", "projects"))
    since = ENV["MODIFIED_SINCE"].presence&.then { |v| Time.zone.parse(v) }

    # The corpus is tens of gigabytes across tens of thousands of files, so the
    # run is chunked by directory rather than handed to one process as a single
    # glob. Each chunk commits before the next starts, which is what makes an
    # interrupted backfill resumable: ingestion is idempotent on `request_id`,
    # so re-running simply skips everything already stored.
    dirs = Dir.children(root).select { |d| File.directory?(File.join(root, d)) }.sort
    chunk_size = Integer(ENV.fetch("CHUNK_SIZE", "200"))

    puts "Backfilling from #{root}"
    puts "#{dirs.size} transcript directories, #{chunk_size} per chunk#{since ? ", modified since #{since}" : ""}"

    totals = Hash.new(0)
    started = Time.current

    dirs.each_slice(chunk_size).with_index(1) do |slice, chunk_number|
      # A scratch root of symlinks lets the service keep its one glob shape
      # (root/*/*.jsonl) while the task controls how much it sees at a time.
      Dir.mktmpdir("token_usage_backfill_") do |scratch|
        slice.each { |d| File.symlink(File.join(root, d), File.join(scratch, d)) }

        result = TokenUsageIngestionService.new(root: scratch, modified_since: since).call

        totals[:files] += result.files_scanned
        totals[:session_rows] += result.session_rows
        totals[:adhoc_rows] += result.adhoc_rows
      end

      printf(
        "  chunk %d/%d — %d files, %d session rows, %d ad hoc rows (%.0fs elapsed)\n",
        chunk_number, (dirs.size / chunk_size.to_f).ceil,
        totals[:files], totals[:session_rows], totals[:adhoc_rows],
        Time.current - started
      )
    end

    puts
    puts "Done in #{(Time.current - started).round}s"
    puts "  files scanned    : #{totals[:files]}"
    puts "  session rows new : #{totals[:session_rows]}"
    puts "  ad hoc rows new  : #{totals[:adhoc_rows]}"
    puts "  session table    : #{SessionTokenUsage.count} rows"
    puts "  ad hoc table     : #{AdhocTokenUsage.count} rows"
  end

  desc "Show what is currently stored (sanity check after a backfill)"
  task summary: :environment do
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
