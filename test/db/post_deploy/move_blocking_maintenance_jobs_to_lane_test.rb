# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260902041936_move_pending_maintenance_jobs_to_lane")

class MoveBlockingMaintenanceJobsToLaneTest < ActiveSupport::TestCase
  setup do
    @entry = PostDeployTask::Registry.find("20260902041936")
    assert @entry
    @task_class = @entry.task_class
  end

  def job(**attrs)
    GoodJob::Job.create!({
      job_class: "DeferredCloneCleanupJob",
      queue_name: "default",
      scheduled_at: Time.current,
      serialized_params: {}
    }.merge(attrs))
  end

  def run_task
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    @outcome = @task_class.new(run: run).up
    run.reload
  end

  test "moves unfinished safe retries and revisits claimed rows" do
    pending = job
    retrying = job(performed_at: Time.current)
    claimed = job(locked_by_id: SecureRandom.uuid, locked_at: Time.current)
    finished = job(finished_at: Time.current)

    run = run_task

    assert_equal %w[maintenance maintenance], [ pending, retrying ].map { |row| row.reload.queue_name }
    assert_equal "default", claimed.reload.queue_name
    assert_equal "default", finished.reload.queue_name
    assert_equal 2, run.stats["moved_jobs"]
    assert_equal PostDeployTask::CONTINUE, @outcome

    run.finish_continue!
    claimed.update!(locked_by_id: nil, locked_at: nil)
    second = run_task

    assert_nil @outcome
    assert_equal "maintenance", claimed.reload.queue_name
    assert_equal 3, second.stats["moved_jobs"]
  end

  test "uses the same class list as the deploy-time migration" do
    assert_equal MovePendingMaintenanceJobsToLane::JOB_CLASSES.sort, @task_class::JOB_CLASSES.sort
  end
end
