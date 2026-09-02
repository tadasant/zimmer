# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260902034539_prioritize_pending_post_deploy_task_jobs")

class PrioritizePendingPostDeployTaskJobsTest < ActiveSupport::TestCase
  setup do
    @migration = PrioritizePendingPostDeployTaskJobs.new
  end

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { @migration.public_send(direction) }
  end

  def job(job_class: "PostDeployTaskJob", priority: 0, **attrs)
    GoodJob::Job.create!({
      job_class: job_class,
      queue_name: "default",
      priority: priority,
      scheduled_at: Time.current,
      serialized_params: {}
    }.merge(attrs))
  end

  test "prioritizes inherited pending runner rows without weakening a higher priority" do
    inherited = job
    nil_priority = job(priority: nil)
    higher_priority = job(priority: -200)
    other_job = job(job_class: "SessionTitleJob")

    migrate(:up)

    assert_equal(-100, inherited.reload.priority)
    assert_equal(-100, nil_priority.reload.priority)
    assert_equal(-200, higher_priority.reload.priority)
    assert_equal 0, other_job.reload.priority
  end

  test "leaves claimed, already-performed, and finished runner rows alone" do
    claimed = job(locked_by_id: SecureRandom.uuid, locked_at: Time.current)
    performed = job(performed_at: Time.current)
    finished = job(finished_at: Time.current)

    migrate(:up)

    assert_equal [ 0, 0, 0 ], [ claimed, performed, finished ].map { |row| row.reload.priority }
  end

  test "is idempotent" do
    pending = job

    migrate(:up)
    migrate(:up)

    assert_equal(-100, pending.reload.priority)
  end

  test "down restores safe pending runner rows for the older application" do
    pending = job
    higher_priority = job(priority: -200)

    migrate(:up)
    migrate(:down)

    assert_equal 0, pending.reload.priority
    assert_equal(-200, higher_priority.reload.priority)
  end
end
