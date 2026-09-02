# frozen_string_literal: true

# Converges inherited heavy work onto the bounded maintenance scheduler.
class MoveBlockingMaintenanceJobsToLane < PostDeployTask
  JOB_CLASSES = %w[
    BundleInstallJob
    CacheClearJob
    ClaudeCodeUpdateJob
    DeferredCloneCleanupJob
    DeploymentRecoveryJob
    DockerCleanupJob
    EmptyTrashJob
    McpPackageReinstallJob
    OrphanCloneFilesystemCleanupJob
    StaleCloneCleanupJob
    TokenUsageBackfillJob
    TranscriptArchiveJob
  ].freeze

  def up
    targets = GoodJob::Job
      .where(job_class: JOB_CLASSES, queue_name: "default", finished_at: nil)
    moved = targets.where(locked_by_id: nil).update_all(queue_name: "maintenance", updated_at: Time.current)

    checkpoint!(moved_jobs: stats.fetch("moved_jobs", 0) + moved)
    logger.info("[MoveBlockingMaintenanceJobsToLane] moved #{moved} unfinished jobs to maintenance")

    targets.exists? ? CONTINUE : nil
  end
end
