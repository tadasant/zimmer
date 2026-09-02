# frozen_string_literal: true

require "test_helper"

class MoveBlockingInferenceJobsToLaneTest < ActiveSupport::TestCase
  setup do
    @entry = PostDeployTask::Registry.find("20260902030000")
    assert @entry
    @task_class = @entry.task_class
  end

  def job(job_class:, queue_name: "default", arguments: [], **attrs)
    GoodJob::Job.create!({
      job_class: job_class,
      queue_name: queue_name,
      scheduled_at: Time.current,
      serialized_params: { "arguments" => ActiveJob::Arguments.serialize(arguments) }
    }.merge(attrs))
  end

  def run_task
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    @task_class.new(run: run).up
    run.reload
  end

  test "moves unfinished unclaimed inference work and nothing else" do
    title = job(job_class: "SessionTitleJob")
    summary = job(job_class: "SessionStatusSummaryJob")
    push = job(job_class: "SendPushNotificationJob", arguments: [ 1, :needs_input ])
    deterministic_push = job(job_class: "SendPushNotificationJob", arguments: [ 1, :custom_message ])
    ordinary = job(job_class: "HeartbeatSweepJob")
    claimed = job(job_class: "SessionTitleJob", locked_by_id: SecureRandom.uuid, locked_at: Time.current)
    performed = job(job_class: "SessionStatusSummaryJob", performed_at: Time.current)
    finished = job(job_class: "SessionTitleJob", finished_at: Time.current)

    run = run_task

    assert_equal %w[inference inference inference], [ title, summary, push ].map { |row| row.reload.queue_name }
    assert_equal "default", ordinary.reload.queue_name
    assert_equal "default", deterministic_push.reload.queue_name
    assert_equal "default", claimed.reload.queue_name
    assert_equal "default", performed.reload.queue_name
    assert_equal "default", finished.reload.queue_name
    assert_equal 3, run.stats["moved_jobs"]
  end

  test "is idempotent" do
    moved = job(job_class: "SessionTitleJob")
    first = run_task
    assert_equal 1, first.stats["moved_jobs"]

    first.update!(status: "pending", cursor: {})
    first.claim!(owner: "test")
    @task_class.new(run: first).up

    assert_equal "inference", moved.reload.queue_name
    assert_equal 1, first.reload.stats["moved_jobs"]
  end
end
