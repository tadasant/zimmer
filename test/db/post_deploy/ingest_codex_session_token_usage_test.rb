# frozen_string_literal: true

require "test_helper"
require "json"

# The one-time sweep that puts every PRE-EXISTING Codex rollout in the ledger.
# CodexTokenUsageIngestionService ships with the same deploy, but the cron only
# ever hands it a two-hour lookback, so without this task every Codex session run
# before the deploy would read as zero spend forever — 51 of them on this
# deployment when the ingestor landed (zimmer#1077).
class IngestCodexSessionTokenUsageTest < ActiveSupport::TestCase
  setup do
    @entry = PostDeployTask::Registry.find("20260907090000")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
    SessionTokenUsage.delete_all

    # The task reads CodexHome, which is what production does; CODEX_HOME is the
    # documented override and the same one the transcript source honours. A
    # per-test home, because a shared one would let these tests write into each
    # other's corpus.
    @root = Dir.mktmpdir("codex-home")
    @previous_codex_home = ENV["CODEX_HOME"]
    ENV["CODEX_HOME"] = @root
    @sessions_path = CodexHome.sessions_path
    FileUtils.mkdir_p(@sessions_path)
  end

  teardown do
    ENV["CODEX_HOME"] = @previous_codex_home
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  # A minimal rollout with one billable turn, written where Codex writes them.
  def rollout(day: 14, stamp: nil, tokens: 100)
    uuid = SecureRandom.uuid
    stamp ||= "2026-08-#{format('%02d', day)}T11-44-44"
    events = [
      { "timestamp" => "2026-08-#{format('%02d', day)}T11:44:44.566Z", "type" => "session_meta",
        "payload" => { "session_id" => uuid, "id" => uuid,
                       "cwd" => "/home/rails/.zimmer/clones/zimmer-main-1786707822-b9f9960e" } },
      { "timestamp" => "2026-08-#{format('%02d', day)}T11:44:47.597Z", "type" => "turn_context",
        "payload" => { "model" => "gpt-5.6-terra", "cwd" => "/home/rails/.zimmer/clones/x" } },
      { "timestamp" => "2026-08-#{format('%02d', day)}T11:44:54.291Z", "type" => "event_msg",
        "payload" => { "type" => "token_count",
                       "info" => { "total_token_usage" => { "input_tokens" => tokens, "output_tokens" => 1 },
                                   "last_token_usage" => { "input_tokens" => tokens, "cached_input_tokens" => 0,
                                                           "cache_write_input_tokens" => 0, "output_tokens" => 1,
                                                           "reasoning_output_tokens" => 0 } } } }
    ]

    dir = File.join(@sessions_path, "2026/08/#{format('%02d', day)}")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "rollout-#{stamp}-#{uuid}.jsonl")
    File.write(path, events.map { |e| JSON.generate(e) }.join("\n") + "\n")
    # Old enough that the cron's two-hour lookback would never reach it, which is
    # exactly the population this task exists for.
    File.utime(30.days.ago.to_time, 30.days.ago.to_time, path)
    [ path, uuid ]
  end

  # A run row of its own, so a test can model "the task ran again from scratch"
  # rather than only "the same run was ticked twice".
  def fresh_run
    run = PostDeployTaskRun.ledger_for(@entry)
    run.update!(cursor: {}, stats: {})
    run
  end

  def run_task(run: fresh_run, deadline: nil)
    outcome = @task_class.new(run: run, deadline: deadline, logger: Rails.logger).up
    [ run.reload, outcome ]
  end

  test "ingests a rollout the cron's lookback would never reach" do
    _path, uuid = rollout

    run, outcome = run_task

    assert_nil outcome
    assert_equal [ "codex:#{uuid}:2026-08-14T11:44:54.291Z" ], SessionTokenUsage.pluck(:request_id)
    assert_equal 1, run.stats["rollouts_scanned"]
    assert_equal 1, run.stats["rows_written"]
    assert_equal @sessions_path, run.stats["root"], "a coverage claim has to name the corpus it covered"
  end

  # Not the cursor doing the work: the run is reset, so the second pass re-reads
  # the same rollout from the top and the synthesised `request_id` is what makes
  # it a no-op. That is the property a half-applied task depends on.
  test "a second pass re-reads the same rollout and writes nothing" do
    rollout

    run_task
    assert_equal 1, SessionTokenUsage.count

    run, _ = run_task
    assert_equal 1, SessionTokenUsage.count
    assert_equal 1, run.stats["rollouts_scanned"]
    assert_equal 0, run.stats["rows_written"]
  end

  test "hands the worker thread back and resumes from its cursor" do
    3.times { |i| rollout(day: 14 + i) }

    run = fresh_run
    # A deadline already past stops the sweep after its first batch, which is what
    # a long corpus does to a 90-second slice.
    stub_batch_size(1) do
      _, outcome = run_task(run: run, deadline: 1.second.ago)
      assert_equal PostDeployTask::CONTINUE, outcome
      assert run.reload.cursor["sweep_last_path"].present?
      assert_equal 1, SessionTokenUsage.count

      cursor_after_first = run.cursor["sweep_last_path"]

      # The next tick continues from there rather than starting over.
      _, outcome = run_task(run: run, deadline: 1.second.ago)
      assert_equal PostDeployTask::CONTINUE, outcome
      assert_operator run.reload.cursor["sweep_last_path"], :>, cursor_after_first
      assert_equal 2, SessionTokenUsage.count
    end

    _, outcome = run_task(run: run)
    assert_nil outcome
    assert_equal 3, SessionTokenUsage.count
  end

  test "an empty sessions tree completes rather than raising" do
    run, outcome = run_task

    assert_nil outcome
    assert_equal 0, SessionTokenUsage.count
    assert_equal 0, run.stats.fetch("rollouts_scanned", 0)
  end

  test "does not touch the other runtimes' rows" do
    SessionTokenUsage.create!(
      request_id: "req_claude", model: "claude-opus-5", agent_runtime: "claude_code",
      called_at: 1.day.ago, input_tokens: 5, output_tokens: 5
    )

    run_task

    assert_equal 1, SessionTokenUsage.count
    assert_equal [ "claude_code" ], SessionTokenUsage.distinct.pluck(:agent_runtime)
  end

  private

  def stub_batch_size(size)
    original = @task_class::BATCH_SIZE
    @task_class.send(:remove_const, :BATCH_SIZE)
    @task_class.const_set(:BATCH_SIZE, size)
    yield
  ensure
    @task_class.send(:remove_const, :BATCH_SIZE)
    @task_class.const_set(:BATCH_SIZE, original)
  end
end
