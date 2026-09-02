# frozen_string_literal: true

# Route safe rows written by an older image before the new worker starts.
#
# Active Job stores queue_name at enqueue time. Changing the job classes does
# not move an inherited backlog, and two multi-minute filesystem jobs on
# `default` are enough to stop every ordinary callback in that lane. The
# post-deploy task with the same class list converges rows that are locked during
# this migration after their interrupted attempt releases its lock.
class MovePendingMaintenanceJobsToLane < ActiveRecord::Migration[8.1]
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
    move(from: "default", to: "maintenance")
  end

  def down
    move(from: "maintenance", to: "default")
  end

  private

  def move(from:, to:)
    result = connection.exec_update(<<~SQL)
      UPDATE good_jobs
      SET queue_name = #{connection.quote(to)}, updated_at = NOW()
      WHERE job_class IN (#{quoted_job_classes})
        AND queue_name = #{connection.quote(from)}
        AND finished_at IS NULL
        AND performed_at IS NULL
        AND locked_by_id IS NULL
    SQL

    say "Moved #{result} pending maintenance job(s) from #{from} to #{to}"
  end

  def quoted_job_classes
    JOB_CLASSES.map { |job_class| connection.quote(job_class) }.join(", ")
  end
end
