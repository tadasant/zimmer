# frozen_string_literal: true

require "tmpdir"

# Sweeps the whole transcript corpus into the token-spend ledger, a slice at a
# time, against a TokenUsageBackfill run that records where it got to.
#
# WHY SLICES
#
# The corpus is tens of thousands of files and tens of gigabytes. One process
# handed the lot would hold a worker thread for as long as it takes, which is
# fine for a hand-run rake task and not fine for something that has to run
# unattended on a cron next to everything else the worker does. So the run is
# chunked by directory, each chunk commits before the next starts, and the caller
# says how long it may spend before handing the thread back. The next tick picks
# up at the cursor.
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
  # run, reloaded, so a caller can report progress.
  def call
    return @run if @run.complete?

    unless File.directory?(root)
      # A missing root is a misconfiguration, not a finished sweep. Recording it
      # and leaving the run unfinished is what stops the Costs page claiming
      # complete coverage it does not have.
      @run.update!(last_ran_at: Time.current, last_error: "transcript root #{root} does not exist")
      return @run
    end

    @run.update!(started_at: @run.started_at || Time.current)
    deadline = @budget ? Time.current + @budget : nil

    loop do
      remaining = remaining_directories
      @run.directories_total = [ @run.directories_total, @run.directories_done + remaining.size ].max

      if remaining.empty?
        @run.update!(finished_at: Time.current, last_ran_at: Time.current, last_error: nil)
        @logger.info("[TokenUsageBackfill] run ##{@run.id} complete: #{@run.rows_written} rows from #{@run.files_scanned} files")
        break
      end

      sweep(remaining.first(@chunk_size))
      break if deadline && Time.current >= deadline
    end

    @run
  end

  private

  def root = @run.transcript_root

  # Directories still ahead of the cursor, in the sort order the cursor is
  # expressed in. A directory created after the run started may sort before the
  # cursor and be skipped — deliberately: its files are new, so the 10-minute
  # TokenUsageIngestionJob with its two-hour lookback already has them.
  def remaining_directories
    dirs = Dir.children(root).select { |d| File.directory?(File.join(root, d)) }.sort
    return dirs if @run.cursor.blank?

    dirs.select { |d| d > @run.cursor }
  end

  def sweep(chunk)
    result = ingest(chunk)

    @run.update!(
      cursor: chunk.last,
      directories_done: @run.directories_done + chunk.size,
      directories_total: @run.directories_total,
      files_scanned: @run.files_scanned + result.files_scanned,
      session_rows: @run.session_rows + result.session_rows,
      adhoc_rows: @run.adhoc_rows + result.adhoc_rows,
      last_ran_at: Time.current,
      last_error: nil
    )
  rescue StandardError => e
    # The cursor has not moved, so the next tick retries this chunk. Recording
    # the error is what makes a permanently failing sweep visible on the Costs
    # page instead of looking like one that is merely slow.
    @run.update!(last_ran_at: Time.current, last_error: "#{e.class}: #{e.message}")
    raise
  end

  # A scratch root of symlinks lets TokenUsageIngestionService keep its one glob
  # shape (root/*/*.jsonl) while this object controls how much it sees at a time.
  def ingest(chunk)
    Dir.mktmpdir("token_usage_backfill_") do |scratch|
      chunk.each { |d| File.symlink(File.join(root, d), File.join(scratch, d)) }

      TokenUsageIngestionService.new(root: scratch, modified_since: nil, logger: @logger).call
    end
  end
end
