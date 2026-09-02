# frozen_string_literal: true

require "test_helper"

# The import as it will actually run in production: a post-deploy task, on the
# deploy, with no shell involved.
class ImportWorkBacklogTest < ActiveSupport::TestCase
  FIXTURE = Rails.root.join("test/fixtures/files/work_backlog_sample.json").to_s

  setup do
    @entry = PostDeployTask::Registry.find("20260902150000")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
  end

  def run_task(path)
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    outcome = with_source(path) { @task_class.new(run: run, logger: Rails.logger).up }
    [ run.reload, outcome ]
  end

  def with_source(path)
    previous = ENV[WorkBacklog::Source::PATH_ENV_VAR]
    ENV[WorkBacklog::Source::PATH_ENV_VAR] = path
    yield
  ensure
    previous.nil? ? ENV.delete(WorkBacklog::Source::PATH_ENV_VAR) : ENV[WorkBacklog::Source::PATH_ENV_VAR] = previous
  end

  test "imports the file and reports counts a human can check on the health page" do
    expected = JSON.parse(File.read(FIXTURE)).size

    run, outcome = run_task(FIXTURE)

    assert_nil outcome, "a finished task returns something other than CONTINUE"
    assert_equal expected, WorkBacklogItem.count
    assert_equal expected, run.stats["items_seen"]
    assert_equal expected, run.stats["imported"]
    assert_equal 0, run.stats["already_present"]
    assert_equal 0, run.stats["rejected"]
    assert_equal expected, run.stats["queued_after"]
    assert_equal "file #{FIXTURE}", run.stats["source"]
  end

  test "running the task twice leaves the row count unchanged" do
    run_task(FIXTURE)
    before = WorkBacklogItem.count

    PostDeployTaskRun.delete_all # a fresh ledger row, as a re-armed task would get
    run, = run_task(FIXTURE)

    assert_equal before, WorkBacklogItem.count
    assert_equal 0, run.stats["imported"]
    assert_equal before, run.stats["already_present"]
  end

  test "outside production, an unreachable source is recorded and the task completes" do
    run, outcome = run_task("/nope/not/here.json")

    assert_nil outcome
    assert_match(/no backlog source available/, run.stats["skipped_reason"])
    assert_equal 0, WorkBacklogItem.count
  end

  test "in production, an unreachable source fails loudly instead of claiming success" do
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")

    Rails.env.stub(:production?, true) do
      assert_raises(WorkBacklog::Source::Unavailable) do
        with_source("/nope/not/here.json") { @task_class.new(run: run, logger: Rails.logger).up }
      end
    end
  end
end
