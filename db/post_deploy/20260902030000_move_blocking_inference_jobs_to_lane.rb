# frozen_string_literal: true

# Moves the unfinished rows written before blocking inference had its own queue.
#
# New enqueues get their queue from the job classes. Without this one-time move,
# the retry-storm cohort already in GoodJob would remain on `default` after the
# deploy and could starve the maintenance work the new lane is meant to protect.
class MoveBlockingInferenceJobsToLane < PostDeployTask
  ALWAYS_INFERENCE_JOB_CLASSES = %w[
    SessionTitleJob
    SessionStatusSummaryJob
  ].freeze

  def up
    # Never move a row a scheduler has claimed or begun performing. Its advisory
    # lock belongs to that scheduler and changing the queue underneath it buys
    # nothing. A retried replacement is a fresh unperformed row and does match.
    movable = GoodJob::Job
      .where(finished_at: nil, performed_at: nil, locked_by_id: nil)
      .where(
        "job_class IN (:always) OR (job_class = :push AND " \
          "COALESCE(serialized_params->'arguments'->1->>'value', " \
          "serialized_params->'arguments'->>1) = 'needs_input')",
        always: ALWAYS_INFERENCE_JOB_CLASSES,
        push: "SendPushNotificationJob"
      )
      .where.not(queue_name: "inference")

    moved = movable.update_all(queue_name: "inference", updated_at: Time.current)
    checkpoint!(moved_jobs: stats.fetch("moved_jobs", 0) + moved)
    logger.info("[MoveBlockingInferenceJobsToLane] moved #{moved} unfinished jobs to inference")
    nil
  end
end
