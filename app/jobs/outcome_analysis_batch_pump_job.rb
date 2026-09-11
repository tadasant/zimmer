# frozen_string_literal: true

# Drives every running "Analyze All" batch forward by one wave.
#
# Runs on a one-minute cron AND is kicked directly when a batch is created, so
# the first wave is immediate and every later one is guaranteed by the cron even
# if a worker died mid-wave. It deliberately does NOT re-enqueue itself: a
# self-scheduling pump plus a cron is two engines for one queue, and the failure
# mode is a pile of duplicate jobs nobody can see the end of.
class OutcomeAnalysisBatchPumpJob < ApplicationJob
  queue_as :default

  # The direct kick from StartBatch and the one-minute cron sweep overlap by
  # construction, and a wide wave outlives the cron period. PumpBatch is safe
  # under that on its own (it claims a wave under a row lock), but there is no
  # value in running two sweeps at once, so only one is ever enqueued or
  # performed at a time — matching how the other pollers in this app are wired.
  good_job_control_concurrency_with(
    total_limit: 1,
    key: -> { "outcome-analysis-batch-pump-#{arguments.first || 'all'}" }
  )

  # @param batch_id [Integer, nil] one batch, or nil for every batch with work left
  def perform(batch_id = nil)
    batches = batch_id ? OutcomeAnalysisBatch.where(id: batch_id).active : with_work_left

    batches.find_each do |batch|
      OutcomeAnalyses::PumpBatch.call(batch)
    rescue StandardError => e
      # A batch that cannot be pumped is one batch's problem. The next tick tries
      # again, and the others in this sweep still get their wave.
      Rails.logger.error("[OutcomeAnalysisBatchPumpJob] Batch #{batch.id} failed to pump: #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
    end
  end

  private

  # Every running batch, plus every stopped one that still has analyses in
  # flight. Stop leaves those to finish, and PumpBatch's reconcile is the only
  # thing that notices when they do; a sweep over running batches alone would
  # leave them RUNNING on the stopped batch forever. PumpBatch spawns nothing for
  # a batch that is not running, so reconciling one is all this does.
  def with_work_left
    stopped_with_items_in_flight = OutcomeAnalysisBatch
      .where(status: OutcomeAnalysisBatch::CANCELED)
      .where(id: OutcomeAnalysisBatchItem.running.select(:outcome_analysis_batch_id))
    OutcomeAnalysisBatch.active.or(stopped_with_items_in_flight)
  end
end
