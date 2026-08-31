# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# End-to-end for the mechanism: a task goes from pending to run, the run is
# recorded, a second pass does not re-run it, and a failure behaves as designed.
class PostDeployTask::RunnerTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # Scopes the runner at a throwaway directory of task files, so these tests
  # exercise the real Registry rather than a stub of it.
  ScopedRegistry = Struct.new(:root) do
    def all = PostDeployTask::Registry.all(root: root)
  end

  def with_runner(files, budget: nil)
    Dir.mktmpdir do |dir|
      files.each { |name, body| File.write(File.join(dir, name), body) }
      yield PostDeployTask::Runner.new(budget: budget, registry: ScopedRegistry.new(dir)), dir
    end
  end

  # A task whose side effect is observable from the test: it appends to a class
  # ivar, which survives the `load` because the constant is reopened, not
  # redefined.
  def counting_task(class_name, version, body)
    { "#{version}_#{class_name.underscore}.rb" => "class #{class_name} < PostDeployTask\n#{body}\nend" }
  end

  test "a pending task runs, is recorded, and does not run again" do
    files = counting_task("RunnerOnceTask", "20260201000000", <<~BODY)
      def up
        Session.create!(prompt: "ran once", agent_runtime: "claude_code", status: :waiting,
                        git_root: "https://github.com/test/repo.git", branch: "main",
                        execution_provider: "local_filesystem")
        checkpoint!(created: 1)
      end
    BODY

    with_runner(files) do |runner|
      first = runner.call

      assert_equal [ :succeeded ], first.map(&:outcome)
      assert_equal 1, Session.where(prompt: "ran once").count

      run = PostDeployTaskRun.find_by!(version: "20260201000000")
      assert_equal "succeeded", run.status
      assert_equal "RunnerOnceTask", run.name
      assert_equal 1, run.attempts
      assert_equal({ "created" => 1 }, run.stats)
      assert_not_nil run.finished_at

      second = runner.call

      assert_empty second, "a succeeded task must not be worked again"
      assert_equal 1, Session.where(prompt: "ran once").count
      assert_equal 1, run.reload.attempts
    end
  end

  test "a task that raises is recorded, backed off, and does not stop the next task" do
    files = counting_task("RunnerBoomTask", "20260202000000", "def up = raise(ArgumentError, 'boom')")
      .merge(counting_task("RunnerAfterBoomTask", "20260202000001", "def up = checkpoint!(ok: true)"))

    with_runner(files) do |runner|
      results = runner.call

      assert_equal %i[failed succeeded], results.map(&:outcome),
                   "a failing task must not block the one behind it"

      failed = PostDeployTaskRun.find_by!(version: "20260202000000")
      assert_equal "failed", failed.status
      assert_equal 1, failed.failures
      assert_match(/ArgumentError: boom/, failed.last_error)
      assert_not_nil failed.next_attempt_at

      assert_equal "succeeded", PostDeployTaskRun.find_by!(version: "20260202000001").status

      # Still backed off, so the next pass leaves it alone entirely.
      assert_empty runner.call

      travel_to(failed.next_attempt_at + 1.second) do
        assert_equal %i[failed], runner.call.map(&:outcome)
      end

      assert_equal 2, failed.reload.failures
    end
  end

  test "a task too slow for one slice resumes from its cursor on the next pass" do
    5.times do |i|
      Session.create!(prompt: "sweep target #{i}", agent_runtime: "claude_code", status: :waiting,
                      git_root: "https://github.com/test/repo.git", branch: "main",
                      execution_provider: "local_filesystem")
    end

    files = counting_task("RunnerSlicedTask", "20260203000000", <<~BODY)
      def up
        sweep(Session.where("prompt LIKE 'sweep target%'"), batch_size: 2) do |batch|
          checkpoint!(seen: stats.fetch("seen", 0) + batch.size)
        end
      end

      # Out of time after the first batch of every slice.
      def out_of_time? = stats.fetch("seen", 0).positive? && stats["seen"] % 2 == 0
    BODY

    with_runner(files) do |runner|
      assert_equal [ :continued ], runner.call.map(&:outcome)

      run = PostDeployTaskRun.find_by!(version: "20260203000000")
      assert_equal "pending", run.status
      assert_equal 2, run.stats["seen"]
      assert_equal 0, run.failures, "yielding for a slice is progress, not a failure"
      assert_not_nil run.cursor["sweep_last_id"]

      assert_equal [ :continued ], runner.call.map(&:outcome)
      assert_equal 4, run.reload.stats["seen"]

      assert_equal [ :succeeded ], runner.call.map(&:outcome)
      assert_equal 5, run.reload.stats["seen"], "every row is seen exactly once across the slices"
      assert_equal "succeeded", run.status
    end
  end

  test "a second container does not re-run a task the first one completed" do
    files = counting_task("RunnerRaceTask", "20260204000000", <<~BODY)
      def up
        Session.create!(prompt: "raced", agent_runtime: "claude_code", status: :waiting,
                        git_root: "https://github.com/test/repo.git", branch: "main",
                        execution_provider: "local_filesystem")
      end
    BODY

    Dir.mktmpdir do |dir|
      files.each { |name, body| File.write(File.join(dir, name), body) }
      registry = ScopedRegistry.new(dir)

      # Both containers see the same pending row. The exclusivity of the claim
      # itself is asserted in PostDeployTaskRunTest; what matters here is that
      # the loser's whole pass is a no-op rather than a second application.
      run = PostDeployTaskRun.ledger_for(registry.all.sole)
      first = PostDeployTask::Runner.new(registry: registry, owner: "container-a")
      second = PostDeployTask::Runner.new(registry: registry, owner: "container-b")

      assert_equal [ :succeeded ], first.call.map(&:outcome)
      assert_empty second.call

      assert_equal 1, Session.where(prompt: "raced").count
      assert_equal 1, run.reload.attempts
    end
  end

  test "a claim held by a live worker is reported as contended, not stolen" do
    files = counting_task("RunnerContendedTask", "20260205000000", "def up = checkpoint!(ok: true)")

    with_runner(files) do |runner, dir|
      run = PostDeployTaskRun.ledger_for(PostDeployTask::Registry.all(root: dir).sole)
      run.claim!(owner: "the-other-container")

      assert_empty runner.call, "a live claim is skipped before a claim is even attempted"
      assert_equal "running", run.reload.status
      assert_equal "the-other-container", run.locked_by
    end
  end

  test "a worker that died holding a task lets the next pass pick it up" do
    files = counting_task("RunnerReapedTask", "20260206000000", "def up = checkpoint!(ok: true)")

    with_runner(files) do |runner, dir|
      run = PostDeployTaskRun.ledger_for(PostDeployTask::Registry.all(root: dir).sole)
      run.claim!(owner: "dead-worker")
      run.update_columns(locked_at: (PostDeployTaskRun::LEASE + 1.minute).ago)

      # The reap turns the abandoned claim into a failure with a one-minute
      # backoff; the pass after that backoff runs it for real.
      assert_empty runner.call
      assert_equal "failed", run.reload.status

      travel_to(run.next_attempt_at + 1.second) do
        assert_equal [ :succeeded ], runner.call.map(&:outcome)
      end

      assert_equal({ "ok" => true }, run.reload.stats)
    end
  end

  test "a task that only raises NotImplementedError is still recorded as a failure" do
    # The literal state of a task generated and not yet filled in.
    # NotImplementedError is a ScriptError, NOT a StandardError, so a rescue that
    # only named StandardError would let it out of the pass — leaving the row
    # claimed until its lease expired and abandoning every task behind it.
    files = counting_task("RunnerScaffoldTask", "20260209000000", "def up = raise(NotImplementedError, 'write the step here')")
      .merge(counting_task("RunnerAfterScaffoldTask", "20260209000001", "def up = checkpoint!(ok: true)"))

    with_runner(files) do |runner|
      results = nil
      assert_nothing_raised { results = runner.call }

      assert_equal %i[failed succeeded], results.map(&:outcome)

      run = PostDeployTaskRun.find_by!(version: "20260209000000")
      assert_equal "failed", run.status
      assert_match(/NotImplementedError: write the step here/, run.last_error)
    end
  end

  test "a task directory that does not resolve makes the pass a no-op rather than raising" do
    # A duplicate version is an authoring bug registry_test fails CI on. If one
    # reached production, raising out of the job every two minutes would be an
    # ERROR line per tick, which this deployment escalates to a page.
    broken = Struct.new(:error) do
      def all = raise(PostDeployTask::Registry::InvalidTask, "duplicate post-deploy task version: 20260101000000")
    end

    runner = PostDeployTask::Runner.new(registry: broken.new(nil))

    assert_nothing_raised { assert_empty runner.call }
  end

  test "the pass stops when its budget is spent rather than running every task" do
    files = counting_task("RunnerBudgetFirstTask", "20260207000000", "def up = checkpoint!(ok: true)")
      .merge(counting_task("RunnerBudgetSecondTask", "20260207000001", "def up = checkpoint!(ok: true)"))

    with_runner(files, budget: 0.seconds) do |runner|
      assert_empty runner.call, "a spent budget stops the pass before any task is claimed"
      assert_equal 0, PostDeployTaskRun.where(status: "running").count
    end
  end

  test "request! re-arms blocked tasks and enqueues a pass" do
    run = PostDeployTaskRun.create!(version: "20260208000000", name: "Stuck", status: "failed",
                                    failures: PostDeployTaskRun::RETRY_DELAYS.size + 1)
    done = PostDeployTaskRun.create!(version: "20260208000001", name: "Done", status: "succeeded")

    result = nil
    assert_enqueued_with(job: PostDeployTaskJob) { result = PostDeployTask::Runner.request! }

    assert_equal 1, result[:rearmed]
    assert_equal "pending", run.reload.status
    assert_equal 0, run.failures
    assert_equal "succeeded", done.reload.status
  end

  test "the job runs a pass inside its slice budget" do
    assert_equal 90.seconds, PostDeployTaskJob::SLICE_BUDGET
    assert_equal "default", PostDeployTaskJob.new.queue_name
    assert_equal 1, PostDeployTaskJob.good_job_concurrency_config[:total_limit]

    # The real registry — the tasks that actually ship — so this asserts the job
    # is wired to something that resolves, not to a fixture.
    assert_nothing_raised { PostDeployTaskJob.new.perform(budget: 5.seconds) }
  end
end
