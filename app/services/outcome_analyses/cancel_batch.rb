# frozen_string_literal: true

module OutcomeAnalyses
  # Stop a running batch.
  #
  # Cancel stops the QUEUE, not the analyses already in flight. Sessions that are
  # mid-analysis are left to finish and still save their results — killing them
  # would throw away work already paid for, and the thing a runaway batch needs
  # stopped is the spawning, which this does immediately.
  class CancelBatch
    # @return [Integer] how many queued items were actually canceled — counted
    #   inside the lock, because a pump wave can claim some of them between a
    #   caller's count and this call, and a message that overstates what it
    #   stopped is worse than no number.
    def self.call(batch)
      # The same row lock PumpBatch claims under, so Stop cannot land between a
      # wave deciding which items are its own and those items being marked
      # RUNNING — which would otherwise cancel an item the wave then resurrects.
      batch.with_lock do
        canceled = batch.items.queued.update_all(
          state: OutcomeAnalysisBatchItem::CANCELED,
          finished_at: Time.current,
          updated_at: Time.current
        )
        batch.update!(status: OutcomeAnalysisBatch::CANCELED, finished_at: Time.current)
        canceled
      end
    end
  end
end
