# frozen_string_literal: true

# One sweep of the whole transcript corpus into the token-spend ledger.
#
# The recurring TokenUsageIngestionJob only looks at files modified in the last
# two hours, so everything older than the feature itself has to be swept once.
# That sweep used to be a rake task somebody ran on the production box. It is now
# a row: TokenUsageBackfillJob starts one automatically when no sweep has ever
# finished, works it a slice at a time, and stops doing anything once it is
# finished. A deploy is therefore all it takes to get history into the ledger,
# and every deploy after that costs one indexed lookup per tick.
#
# The row is also the honest answer to "how complete is the Costs page" — which
# is why `coverage` lives here and is rendered on the page, returned by the REST
# API, and reported by the `get_costs` MCP tool rather than being knowable only
# from a shell.
class TokenUsageBackfill < ApplicationRecord
  TRIGGERS = %w[automatic manual].freeze

  validates :transcript_root, presence: true
  validates :trigger, inclusion: { in: TRIGGERS }

  scope :finished, -> { where.not(finished_at: nil) }
  scope :unfinished, -> { where(finished_at: nil) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  class << self
    # The run the job should work, or nil when there is nothing to do. Only the
    # newest unfinished row is ever worked: an older one that never finished has
    # been superseded by a re-scan, and re-sweeping it would repeat work the
    # newer run is already doing.
    def pending
      unfinished.newest_first.first
    end

    def latest = newest_first.first

    # Has the corpus ever been swept end to end? This is the flag that keeps the
    # job idle on every deploy after the first.
    def ever_completed? = finished.exists?

    def last_completed = finished.newest_first.first

    # Start a sweep unless one is already pending. Returns the run either way, so
    # the caller can report progress without caring which case it hit.
    def request!(trigger: "automatic", transcript_root: TokenUsageIngestionService.default_root)
      pending || create!(trigger: trigger, transcript_root: transcript_root)
    end

    # What the Costs page, the REST API and the MCP tool all say about how
    # complete the ledger is. One place, so the three surfaces cannot drift into
    # claiming different things.
    #
    # `covers_since` is the oldest call actually stored, which is the only
    # defensible answer to "how far back does this page go". Before a backfill it
    # is roughly the deploy that shipped ingestion; after one it is the oldest
    # transcript on disk.
    def coverage
      run = latest
      earliest = [ SessionTokenUsage.minimum(:called_at), AdhocTokenUsage.minimum(:called_at) ].compact.min
      latest_call = [ SessionTokenUsage.maximum(:called_at), AdhocTokenUsage.maximum(:called_at) ].compact.max

      {
        status: run&.status || "never_run",
        complete: ever_completed?,
        progress_pct: run&.progress_pct,
        directories_done: run&.directories_done,
        directories_total: run&.directories_total,
        files_scanned: run&.files_scanned,
        rows_written: run&.rows_written,
        trigger: run&.trigger,
        started_at: run&.started_at,
        finished_at: last_completed&.finished_at,
        last_ran_at: run&.last_ran_at,
        last_error: run&.last_error,
        covers_since: earliest,
        covers_until: latest_call
      }
    end
  end

  # never_run is a class-level state; an existing row is one of the other three.
  def status
    return "complete" if finished_at
    return "running" if started_at
    "queued"
  end

  def complete? = finished_at.present?

  def rows_written = session_rows + adhoc_rows

  # Nil rather than 0 before the first slice: a denominator of zero is not 0%
  # progress, it is no information, and rendering it as 0% reads as "stuck".
  def progress_pct
    return 100 if complete?
    return nil unless directories_total.positive?

    ((directories_done.to_f / directories_total) * 100).clamp(0, 99).round
  end
end
