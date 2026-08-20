# frozen_string_literal: true

module OutcomeAnalyses
  # Advance one "Analyze All" batch by one wave.
  #
  # Three steps, in this order:
  #
  #   1. RECONCILE what is in flight. An item is SUCCEEDED the moment a current
  #      OutcomeAnalysis exists for its session — the batch's actual goal — which
  #      frees its concurrency slot immediately instead of holding it until the
  #      analyzer session happens to archive. An item whose analysis session
  #      reached a terminal state with no analysis saved is FAILED.
  #   2. CLAIM up to (concurrency - in flight) queued items, flipping them to
  #      RUNNING before anything is spawned.
  #   3. SPAWN a session for each claimed item.
  #
  # That ordering is what makes `concurrency: 1` mean strictly sequential: the
  # single slot cannot free and refill in the same wave without the reconcile
  # having proved the previous analysis landed.
  #
  # == Why steps 1–2 hold a row lock
  #
  # Two pumps can overlap — StartBatch kicks one directly and the cron fires
  # another a moment later, and a wide wave outlives the one-minute cron period.
  # Without serialization both read the same `running.count`, both compute the
  # same free slots, and both spawn the same queued rows: the ceiling is doubled
  # and one item gets two analysis sessions, only one of which the item can name.
  #
  # So the read-and-claim is done under `with_lock` on the batch row, which makes
  # "how many slots are free" and "these items are now mine" a single atomic
  # decision. Spawning — the slow part, a full Session create per item — happens
  # AFTER the lock is released, so a hundred-wide wave never holds a lock (or a
  # transaction) for the length of a hundred session creates.
  class PumpBatch
    # A spawned analysis session that has produced nothing and gone quiet for
    # this long is not coming back; releasing its slot is better than wedging the
    # batch behind it forever.
    STALE_AFTER = 3.hours

    # How long an item claimed by a wave may sit without a spawned session before
    # the wave is presumed dead. Comfortably longer than a wave takes to work
    # through its items, and short enough that a killed worker does not wedge the
    # batch for hours.
    SPAWN_GRACE = 5.minutes

    def self.call(batch)
      new(batch).call
    end

    def initialize(batch)
      @batch = batch
    end

    def call
      claimed = @batch.with_lock do
        @batch.reload
        # A canceled batch still reconciles: items already in flight when Stop was
        # clicked are left to finish, and something has to notice when they do or
        # they stay RUNNING forever on a stopped batch.
        reconcile_in_flight
        @batch.running? ? claim_next_wave : []
      end

      claimed.each { |item| spawn(item) }
      finish_if_drained
      @batch
    end

    private

    def reconcile_in_flight
      items = @batch.items.running.includes(:analysis_session).to_a
      return if items.empty?

      analyzed_ids = OutcomeAnalysis.current.where(session_id: items.map(&:session_id)).pluck(:session_id).to_set

      items.each do |item|
        if analyzed_ids.include?(item.session_id)
          item.update!(state: OutcomeAnalysisBatchItem::SUCCEEDED, finished_at: Time.current, error: nil)
          next
        end

        # Claimed but not yet spawned. Spawning happens outside the lock, so
        # another pump can see this item mid-wave — it must not be failed for
        # that. Only once the grace window has lapsed is the wave that claimed it
        # presumed dead (a worker killed mid-loop), and the item put back rather
        # than left holding a slot forever.
        if item.analysis_session_id.nil?
          if item.started_at.nil? || item.started_at < SPAWN_GRACE.ago
            item.update!(state: OutcomeAnalysisBatchItem::QUEUED, started_at: nil)
          end
          next
        end

        analysis_session = item.analysis_session
        if analysis_session.nil?
          fail_item(item, "The analysis session no longer exists.")
        elsif analysis_session.failed?
          fail_item(item, "The analysis session failed without saving an analysis.")
        elsif analysis_session.archived?
          fail_item(item, "The analysis session archived without saving an analysis.")
        elsif item.started_at && item.started_at < STALE_AFTER.ago
          fail_item(item, "No analysis after #{STALE_AFTER.inspect}; releasing the slot.")
        end
      end
    end

    # Flip the next wave's items to RUNNING while the batch row is locked, so the
    # ceiling is decided once. `started_at` is stamped here, which is also what
    # tells the reconcile above a claimed-but-unspawned item from a live one.
    def claim_next_wave
      slots = @batch.concurrency - @batch.items.running.count
      return [] if slots <= 0

      items = @batch.items.queued.in_order.limit(slots).to_a
      return [] if items.empty?

      OutcomeAnalysisBatchItem.where(id: items.map(&:id)).update_all(
        state: OutcomeAnalysisBatchItem::RUNNING,
        started_at: Time.current,
        updated_at: Time.current
      )
      items.each { |item| item.reload }
    end

    def spawn(item)
      session = item.session
      unless session&.archived?
        fail_item(item, "Session is no longer archived, so it is no longer analyzable.")
        return
      end

      analysis_session = SpawnAnalysisSession.call(session: session, batch: @batch)
      item.update!(analysis_session_id: analysis_session.id)
    rescue StandardError => e
      # One session that cannot be spawned must not take the batch with it —
      # record why on the item and let the wave continue.
      Rails.logger.warn("[OutcomeAnalyses] Batch #{@batch.id} could not spawn for session #{item.session_id}: #{e.class}: #{e.message}")
      fail_item(item, "#{e.class}: #{e.message}".truncate(500))
    end

    def fail_item(item, message)
      item.update!(state: OutcomeAnalysisBatchItem::FAILED, error: message, finished_at: Time.current)
    end

    # Only a running batch completes. A canceled one keeps its own status — it
    # did not run to completion, and saying so is the point of the label.
    def finish_if_drained
      return unless @batch.reload.running?
      return if @batch.items.where(state: [ OutcomeAnalysisBatchItem::QUEUED, OutcomeAnalysisBatchItem::RUNNING ]).exists?

      @batch.update!(status: OutcomeAnalysisBatch::COMPLETED, finished_at: Time.current)
    end
  end
end
