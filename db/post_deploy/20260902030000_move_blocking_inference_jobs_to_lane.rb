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
    # nothing. Once it finishes or releases the lock for a retry, a later slice
    # either ignores the finished row or moves the now-safe unfinished row.
    targets = GoodJob::Job
      .where(finished_at: nil)
      .where(
        "job_class IN (:always) OR (job_class = :push AND " \
          "COALESCE(serialized_params->'arguments'->1->>'value', " \
          "serialized_params->'arguments'->>1) = 'needs_input')",
        always: ALWAYS_INFERENCE_JOB_CLASSES,
        push: "SendPushNotificationJob"
      )
      .where.not(queue_name: "inference")
    movable = targets.where(locked_by_id: nil)

    moved = movable.update_all(queue_name: "inference", updated_at: Time.current)
    checkpoint!(moved_jobs: stats.fetch("moved_jobs", 0) + moved)
    logger.info("[MoveBlockingInferenceJobsToLane] moved #{moved} unfinished jobs to inference")

    # A claimed row may outlive this slice. Do not permanently mark the one-time
    # task complete while any target is still on an old queue: the cron runner
    # will revisit it until each row either finishes or becomes safe to move.
    targets.exists? ? CONTINUE : nil
  end
end
