# frozen_string_literal: true

require "test_helper"

# Work whose runtime depends on a clone, a package manager, or the transcript
# corpus cannot consume `default`: priority cannot preempt an already-running
# job, so two such jobs are enough to stop every ordinary callback in that lane.
class BlockingMaintenanceQueueTest < ActiveSupport::TestCase
  BLOCKING_JOBS = [
    BundleInstallJob,
    CacheClearJob,
    ClaudeCodeUpdateJob,
    DeferredCloneCleanupJob,
    DeploymentRecoveryJob,
    DockerCleanupJob,
    EmptyTrashJob,
    McpPackageReinstallJob,
    OrphanCloneFilesystemCleanupJob,
    StaleCloneCleanupJob,
    TokenUsageBackfillJob,
    TranscriptArchiveJob
  ].freeze

  test "blocking maintenance has a bounded lane separate from default" do
    BLOCKING_JOBS.each do |job_class|
      assert_equal "maintenance", job_class.new.queue_name, "#{job_class} can block a shared default worker"
    end

    queues = ConnectionBudget.good_job_queue_threads
    assert_equal 2, queues.fetch(:maintenance)
    assert_equal 2, queues.fetch(:default)
  end
end
