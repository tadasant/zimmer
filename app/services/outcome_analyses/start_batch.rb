# frozen_string_literal: true

module OutcomeAnalyses
  # Create an "Analyze All" batch from the ledger's current filter set.
  #
  # The membership is frozen at creation time: the sessions that matched the
  # filters when the button was clicked are the sessions the batch will analyze,
  # even if new ones archive while it runs. A batch that silently grew would have
  # no honest completion point.
  class StartBatch
    class Error < StandardError; end
    class NothingToAnalyze < Error; end

    def self.call(filters:, concurrency:)
      new(filters: filters, concurrency: concurrency).call
    end

    def initialize(filters:, concurrency:)
      @filters = filters
      # Honor the number as typed — including the ill-advised ones. The floor is
      # the only clamp, because a batch with concurrency 0 would never start.
      # `Array(...).first` so an `?concurrency[]=2` query string narrows or is
      # ignored rather than raising, which is the same forgiveness LedgerFilters
      # applies to every other input on this form.
      @concurrency = [ Array(concurrency).first.to_i, OutcomeAnalysisBatch::MIN_CONCURRENCY ].max
    end

    def call
      session_ids = LedgerQuery.new(@filters).analyzable_session_ids
      raise NothingToAnalyze, "No unanalyzed archived sessions match these filters." if session_ids.empty?

      batch = OutcomeAnalysisBatch.create!(
        filters: @filters.to_h,
        concurrency: @concurrency,
        status: OutcomeAnalysisBatch::RUNNING,
        total_count: session_ids.size
      )

      # One INSERT for the whole queue: an Analyze All over a few thousand
      # sessions must not be a few thousand round trips.
      now = Time.current
      rows = session_ids.each_with_index.map do |session_id, index|
        {
          outcome_analysis_batch_id: batch.id,
          session_id: session_id,
          state: OutcomeAnalysisBatchItem::QUEUED,
          position: index,
          created_at: now,
          updated_at: now
        }
      end
      OutcomeAnalysisBatchItem.insert_all!(rows)

      # Start the first wave now rather than waiting up to a minute for the cron
      # tick, so the click has a visible effect.
      OutcomeAnalysisBatchPumpJob.perform_later(batch.id)
      batch
    end
  end
end
