# frozen_string_literal: true

require "test_helper"
require "support/work_backlog_helpers"

class MarkOpenByDesignBacklogRowsTest < ActiveSupport::TestCase
  include WorkBacklogHelpers

  setup do
    @entry = PostDeployTask::Registry.find("20261112121000")
    assert @entry, "the task file must ship in db/post_deploy"
  end

  test "marks the newest row of each key once, and leaves everything else alone" do
    old_slice = backlog_item(key: "zimmer#321", status: WorkBacklogItem::STARTED, started_at: 20.days.ago)
    slice = backlog_item(key: "zimmer#321", status: WorkBacklogItem::STARTED, started_at: 8.days.ago)
    flake = backlog_item(key: "zimmer#1463", status: WorkBacklogItem::STARTED, started_at: 7.days.ago)
    other = backlog_item(key: "zimmer#999")
    elsewhere = backlog_item(key: "zimmer#1463", issue_url: "https://github.com/someone-else/zimmer/issues/1463")

    run = run_task

    assert_equal "multi_slice", slice.reload.continuation
    assert_equal "awaiting_recurrence", flake.reload.continuation
    assert_nil old_slice.reload.continuation, "a superseded row is not marked"
    assert_nil other.reload.continuation
    assert_nil elsewhere.reload.continuation, "another deployment's zimmer#1463 is not this one"
    assert_equal [ slice.id, flake.id ], run.stats["marked"]

    assert_empty run_task.stats["marked"], "a second run writes nothing"
  end

  test "marks nothing on a deployment without those keys" do
    backlog_item(key: "zimmer#1")

    assert_empty run_task.stats["marked"]
  end

  private

  def run_task
    run = PostDeployTaskRun.create!(version: "#{@entry.version}-#{SecureRandom.hex(4)}", name: @entry.task_name,
                                    status: "pending")
    assert run.claim!(owner: "test"), "the ledger row must be claimable"
    @entry.task_class.new(run: run, logger: Rails.logger).up
    run.reload
  end
end
