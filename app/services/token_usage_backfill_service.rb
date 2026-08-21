# frozen_string_literal: true

require "tmpdir"

# Sweeps the whole transcript corpus into the token-spend ledger, a slice at a
# time, against a TokenUsageBackfill run that records where it got to.
#
# WHY SLICES
#
# The corpus is tens of thousands of files and tens of gigabytes. One process
# handed the lot would hold a worker thread for as long as it takes, which is
# not acceptable for something that runs unattended on a cron next to everything
# else the worker does. So the run is chunked by directory, each chunk commits
# before the next starts, and the caller says how long it may spend before
# handing the thread back. The next tick picks up at the cursor.
#
# That is only safe because ingestion is idempotent on `request_id`: a directory
# swept twice writes nothing the second time, so an interrupted slice, an
# overlapping recurring sweep, and a re-run all cost time and nothing else.
#
# The same object serves both callers — TokenUsageBackfillJob passes a budget and
# returns to the queue, `rake token_usage:backfill` passes none and runs to
# completion — so there is one implementation of "what a backfill is".
class TokenUsageBackfillService
  # Directories per chunk. Small enough that a slice ends promptly after its
  # budget expires, large enough that the per-chunk scratch-directory setup is
  # noise against the scan itself.
  DEFAULT_CHUNK_SIZE = 25

  def initialize(run:, budget: nil, chunk_size: DEFAULT_CHUNK_SIZE, logger: Rails.logger)
    @run = run
    @budget = budget
    @chunk_size = chunk_size
    @logger = logger
  end

  # Works the run until its budget expires or the corpus is covered. Returns the
  # run, so a caller can report progress.
  def call
    return @run if @run.complete?

    return abort_run("transcript root #{root} does not exist") unless File.directory?(root)

    directories = listing
    # A root that exists but holds no transcript directories is the same class of
    # misconfiguration as one that is missing — an unmounted volume, a wrong HOME
    # — and not a finished sweep. Finishing here would set the completion marker
    # permanently on a run that read nothing, and the Costs page would report
    # full coverage it does not have. Record it and leave the run open for the
    # next tick. A run that HAS swept directories is a different case: the corpus
    # going away afterwards does not undo the work already committed.
    return abort_run("no transcript directories under #{root}") if directories.empty? && @run.directories_done.zero?

    @run.update!(started_at: @run.started_at || Time.current)
    deadline = @budget ? Time.current + @budget : nil

    loop do
      remaining = remaining_directories(directories)
      @run.directories_total = [ @run.directories_total, @run.directories_done + remaining.size ].max

      if remaining.empty?
        @run.update!(finished_at: Time.current, last_ran_at: Time.current, last_error: nil)
        @logger.info("[TokenUsageBackfill] run ##{@run.id} complete: #{@run.rows_written} rows from #{@run.files_scanned} files")
        break
      end

      break unless sweep(remaining.first(@chunk_size))
      break if deadline && Time.current >= deadline
    end

    @run
  end

  private

  def root = @run.transcript_root

  # Listed once per slice rather than once per chunk. At ten thousand clone
  # directories, re-listing and re-stat'ing the whole tree for every 25-directory
  # chunk is hundreds of full directory walks per sweep, all to learn something
  # that has not changed.
  def listing
    return [] unless File.directory?(root)

    Dir.children(root).select { |d| File.directory?(File.join(root, d)) }.sort
  rescue SystemCallError => e
    @logger.warn("[TokenUsageBackfill] #{root}: #{e.message}")
    []
  end

  # Directories still ahead of the cursor, in the sort order the cursor is
  # expressed in. A directory created after the run started may sort before the
  # cursor and be skipped — deliberately: its files are new, so the 10-minute
  # TokenUsageIngestionJob with its two-hour lookback already has them.
  def remaining_directories(directories)
    return directories if @run.cursor.blank?

    directories.select { |d| d > @run.cursor }
  end

  # True when the chunk committed, false when it failed. A failure leaves the
  # cursor where it was, so the next tick retries the same chunk.
  def sweep(chunk)
    result = ingest(chunk)

    @run.update!(
      cursor: chunk.last,
      directories_done: @run.directories_done + chunk.size,
      files_scanned: @run.files_scanned + result.files_scanned,
      session_rows: @run.session_rows + result.session_rows,
      adhoc_rows: @run.adhoc_rows + result.adhoc_rows,
      last_ran_at: Time.current,
      last_error: nil
    )
    true
  rescue StandardError => e
    # Recorded and surfaced on the Costs page rather than raised. A chunk that
    # fails for a durable reason — one unreadable directory — fails again on
    # every tick, and an unhandled job error every five minutes forever is an
    # ERROR line per tick, which this deployment escalates to a page. The stored
    # error is the signal; a permanently stalled run shows as one on the page,
    # in `ledger_coverage`, and in `get_costs`.
    @logger.warn("[TokenUsageBackfill] run ##{@run.id} chunk failed: #{e.class}: #{e.message}")
    @run.update!(last_ran_at: Time.current, last_error: "#{e.class}: #{e.message}")
    false
  end

  # A scratch root of symlinks lets TokenUsageIngestionService keep its one glob
  # shape (root/*/*.jsonl) while this object controls how much it sees at a time.
  def ingest(chunk)
    Dir.mktmpdir("token_usage_backfill_") do |scratch|
      chunk.each { |d| File.symlink(File.join(root, d), File.join(scratch, d)) }

      TokenUsageIngestionService.new(root: scratch, modified_since: nil, logger: @logger).call
    end
  end

  def abort_run(message)
    @logger.warn("[TokenUsageBackfill] run ##{@run.id}: #{message}")
    @run.update!(last_ran_at: Time.current, last_error: message)
    @run
  end
end
