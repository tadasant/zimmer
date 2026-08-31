# frozen_string_literal: true

require "test_helper"

# The mechanism's first real user: the repair that used to be
# `rake data:fix_clone_path_metadata`, which could only be run from a shell on
# the production box and therefore never was.
class FixClonePathMetadataTest < ActiveSupport::TestCase
  setup do
    @entry = PostDeployTask::Registry.find("20260830100500")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
  end

  def session(metadata)
    Session.create!(prompt: "clone path #{SecureRandom.hex(4)}", agent_runtime: "claude_code",
                    status: :waiting, git_root: "https://github.com/test/repo.git", branch: "main",
                    execution_provider: "local_filesystem", metadata: metadata)
  end

  def run_task
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    outcome = @task_class.new(run: run, logger: Rails.logger).up
    [ run.reload, outcome ]
  end

  test "unpacks the nested hash and leaves everything else alone" do
    broken = session("clone_path" => { "clone_path" => "/clones/abc", "working_directory" => "/clones/abc/sub" },
                     "process_pid" => 42)
    healthy = session("clone_path" => "/clones/def", "working_directory" => "/clones/def")
    untouched = session("process_pid" => 7)

    run, outcome = run_task

    assert_nil outcome, "a task that finishes returns something other than CONTINUE"
    assert_equal "/clones/abc", broken.reload.metadata["clone_path"]
    assert_equal "/clones/abc/sub", broken.metadata["working_directory"]
    assert_equal 42, broken.metadata["process_pid"], "unrelated keys survive"

    assert_equal "/clones/def", healthy.reload.metadata["clone_path"]
    # Not compared whole: Session's own after_create writes into `metadata` too.
    assert_equal 7, untouched.reload.metadata["process_pid"]
    assert_not untouched.metadata.key?("clone_path")

    assert_equal 1, run.stats["repaired"]
  end

  test "does not overwrite a working_directory that is already correct" do
    broken = session("clone_path" => { "clone_path" => "/clones/abc", "working_directory" => "/stale" },
                     "working_directory" => "/clones/abc/current")

    run_task

    assert_equal "/clones/abc", broken.reload.metadata["clone_path"]
    assert_equal "/clones/abc/current", broken.metadata["working_directory"]
  end

  test "drops the key when the nested hash carries no path" do
    broken = session("clone_path" => { "working_directory" => "/clones/abc" })

    run_task

    assert_not broken.reload.metadata.key?("clone_path")
    assert_equal "/clones/abc", broken.metadata["working_directory"]
  end

  test "is idempotent — a second run finds nothing to do" do
    session("clone_path" => { "clone_path" => "/clones/abc" })

    first, = run_task
    assert_equal 1, first.stats["repaired"]

    first.update!(status: "pending", cursor: {})
    first.claim!(owner: "test")
    @task_class.new(run: first, logger: Rails.logger).up

    assert_equal 1, first.reload.stats["repaired"], "the repaired row no longer matches the predicate"
  end

  test "repairs a session that would no longer pass its own validations" do
    # Why the task uses update_column rather than update!. A session old enough
    # to carry the broken shape may name an `agent_runtime` that is no longer in
    # RuntimeRegistry, and `validates :agent_runtime, inclusion:` reads the LIVE
    # registry — so `update!` would raise on exactly the rows most likely to need
    # repairing.
    broken = session("clone_path" => { "clone_path" => "/clones/abc" })
    broken.update_column(:agent_runtime, "a_runtime_that_was_retired_years_ago")

    assert_not broken.reload.valid?, "the fixture must be a session update! would refuse"

    run, = run_task

    assert_equal "/clones/abc", broken.reload.metadata["clone_path"]
    assert_equal 1, run.stats["repaired"]
  end

  test "hands the worker back when its budget is spent, and finishes on the next pass" do
    2.times { session("clone_path" => { "clone_path" => "/clones/#{SecureRandom.hex(2)}" }) }

    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")

    # A deadline already in the past: the batch commits, then the task yields
    # rather than looping for more work. The cursor it saved is what the next
    # pass resumes from — PostDeployTask::RunnerTest walks a multi-slice sweep
    # end to end.
    assert_equal PostDeployTask::CONTINUE, @task_class.new(run: run, deadline: 1.second.ago).up
    assert_equal 2, run.reload.stats["repaired"]
    assert_not_nil run.cursor["sweep_last_id"]

    assert_nil @task_class.new(run: run).up
  end
end
