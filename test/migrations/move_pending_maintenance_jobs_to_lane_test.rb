# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260902041936_move_pending_maintenance_jobs_to_lane")

class MovePendingMaintenanceJobsToLaneTest < ActiveSupport::TestCase
  setup do
    @migration = MovePendingMaintenanceJobsToLane.new
  end

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { @migration.public_send(direction) }
  end

  def job(job_class: "DeferredCloneCleanupJob", queue_name: "default", **attrs)
    GoodJob::Job.create!({
      job_class: job_class,
      queue_name: queue_name,
      scheduled_at: Time.current,
      serialized_params: {}
    }.merge(attrs))
  end

  test "moves safe pending maintenance rows and nothing else" do
    pending = job
    other = job(job_class: "HeartbeatSweepJob")
    already_moved = job(queue_name: "maintenance")
    claimed = job(locked_by_id: SecureRandom.uuid, locked_at: Time.current)
    performed = job(performed_at: Time.current)
    finished = job(finished_at: Time.current)

    migrate(:up)

    assert_equal "maintenance", pending.reload.queue_name
    assert_equal "maintenance", already_moved.reload.queue_name
    assert_equal [ "default", "default", "default", "default" ],
      [ other, claimed, performed, finished ].map { |row| row.reload.queue_name }
  end

  test "covers every job class whose code declares the maintenance lane" do
    declared = Dir[Rails.root.join("app/jobs/*.rb")].filter_map do |path|
      next unless File.read(path).match?(/queue_as\s+:maintenance\b/)

      File.basename(path, ".rb").camelize
    end.sort

    assert_equal declared, MovePendingMaintenanceJobsToLane::JOB_CLASSES.sort
  end

  test "is idempotent and reversible for safe pending rows" do
    pending = job

    migrate(:up)
    migrate(:up)
    assert_equal "maintenance", pending.reload.queue_name

    migrate(:down)
    assert_equal "default", pending.reload.queue_name
  end
end
