# frozen_string_literal: true

require "test_helper"

# The authoring API a task subclass gets: cursor, stats, the budget check, and
# `sweep` — the packaged resume loop that is what makes this mechanism usable for
# the hour-long case as well as the ten-millisecond one.
class PostDeployTaskTest < ActiveSupport::TestCase
  setup do
    @run = PostDeployTaskRun.create!(version: "20260301000000", name: "Example")
  end

  test "up must be implemented" do
    assert_raises(NotImplementedError) { PostDeployTask.new(run: @run).up }
  end

  test "checkpoint! persists the cursor and merges counters" do
    task = PostDeployTask.new(run: @run)

    task.checkpoint!(cursor: { "page" => 2 }, seen: 10)
    task.checkpoint!(seen: 20, written: 3)

    @run.reload
    assert_equal({ "page" => 2 }, @run.cursor)
    assert_equal({ "seen" => 20, "written" => 3 }, @run.stats)
  end

  test "out_of_time? is false without a deadline and true once it passes" do
    assert_not PostDeployTask.new(run: @run).out_of_time?
    assert_not PostDeployTask.new(run: @run, deadline: 1.minute.from_now).out_of_time?
    assert PostDeployTask.new(run: @run, deadline: 1.second.ago).out_of_time?
  end

  test "sweep walks every row once, in key order, and reports done" do
    sessions = 5.times.map do |i|
      Session.create!(prompt: "sweep #{i}", agent_runtime: "claude_code", status: :waiting,
                      git_root: "https://github.com/test/repo.git", branch: "main",
                      execution_provider: "local_filesystem")
    end

    seen = []
    result = PostDeployTask.new(run: @run).sweep(Session.where(id: sessions.map(&:id)), batch_size: 2) do |batch|
      seen.concat(batch.map(&:id))
    end

    assert_nil result
    assert_equal sessions.map(&:id).sort, seen
    assert_equal sessions.map(&:id).max, @run.reload.cursor["sweep_last_id"]
  end

  test "sweep yields on the budget and resumes from the cursor without repeating a row" do
    sessions = 4.times.map do |i|
      Session.create!(prompt: "resume #{i}", agent_runtime: "claude_code", status: :waiting,
                      git_root: "https://github.com/test/repo.git", branch: "main",
                      execution_provider: "local_filesystem")
    end
    relation = Session.where(id: sessions.map(&:id))

    seen = []
    first = PostDeployTask.new(run: @run, deadline: 1.second.ago)
    assert_equal PostDeployTask::CONTINUE, first.sweep(relation, batch_size: 2) { |b| seen.concat(b.map(&:id)) }
    assert_equal 2, seen.size

    second = PostDeployTask.new(run: @run.reload, deadline: 1.second.ago)
    assert_equal PostDeployTask::CONTINUE, second.sweep(relation, batch_size: 2) { |b| seen.concat(b.map(&:id)) }
    assert_equal 4, seen.size

    third = PostDeployTask.new(run: @run.reload)
    assert_nil third.sweep(relation, batch_size: 2) { |b| seen.concat(b.map(&:id)) }

    assert_equal sessions.map(&:id).sort, seen, "no row is visited twice across the slices"
  end

  test "sweep refuses a key that is not unique, rather than silently skipping rows" do
    error = assert_raises(ArgumentError) do
      PostDeployTask.new(run: @run).sweep(Session.all, key: :created_at) { }
    end

    assert_match(/needs a NOT NULL column with a total unique index/, error.message)
  end

  test "sweep refuses a key whose unique index is partial, or whose column is nullable" do
    # `sessions.idempotency_key` is nullable with a `WHERE idempotency_key IS NOT
    # NULL` unique index — unique for the rows it covers, and silently invisible
    # to the sweep for the rest, which is the trap this guard closes.
    assert_raises(ArgumentError) do
      PostDeployTask.new(run: @run).sweep(Session.all, key: :idempotency_key) { }
    end
  end

  test "sweep accepts a non-primary key that is NOT NULL with a total unique index" do
    # The rule is uniqueness, not "must be the primary key".
    # `post_deploy_task_runs.version` is exactly such a column.
    assert_nothing_raised do
      PostDeployTask.new(run: @run).sweep(PostDeployTaskRun.none, key: :version) { }
    end
  end

  test "sweep on an empty relation is a no-op that reports done" do
    yielded = false
    result = PostDeployTask.new(run: @run).sweep(Session.where(id: -1)) { yielded = true }

    assert_nil result
    assert_not yielded
    assert_empty @run.reload.cursor
  end
end
