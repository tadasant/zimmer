# frozen_string_literal: true

require "test_helper"
require "json"

# The one-time sweep that puts every PRE-EXISTING Pi session in the ledger.
# PiTokenUsageIngestionService ships with the same deploy, but the cron only ever
# hands it a two-hour lookback, so without this task every Pi session run before
# the deploy would read as zero spend forever.
class IngestPiSessionTokenUsageTest < ActiveSupport::TestCase
  setup do
    @entry = PostDeployTask::Registry.find("20260906190000")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
    SessionTokenUsage.delete_all
  end

  def pi_session(entry_id:, tokens: 100, updated_at: nil)
    uuid = SecureRandom.uuid
    transcript = [
      { "type" => "session", "version" => 3, "id" => uuid, "timestamp" => "2026-09-01T10:00:00.000Z" },
      { "type" => "message", "id" => entry_id, "timestamp" => "2026-09-01T10:00:01.000Z",
        "message" => {
          "role" => "assistant", "content" => [], "api" => "openai-completions",
          "provider" => "openrouter", "model" => "anthropic/claude-haiku-4.5",
          "usage" => { "input" => 1, "output" => tokens, "cacheRead" => 0, "cacheWrite" => 0 },
          "stopReason" => "stop"
        } }
    ].map { |e| JSON.generate(e) }.join("\n") + "\n"

    session = Session.create!(
      prompt: "pi #{SecureRandom.hex(4)}",
      agent_runtime: "pi",
      status: :archived,
      git_root: "https://github.com/tadasant/zimmer.git",
      branch: "main",
      session_id: uuid,
      transcript: transcript,
      metadata: { "agent_root_key" => "zimmer" }
    )
    session.update_column(:updated_at, updated_at) if updated_at
    [ session, uuid ]
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

  test "ingests a Pi session the cron's lookback would never reach" do
    _session, uuid = pi_session(entry_id: "aaaaaaaa", updated_at: 30.days.ago)

    run, _ = run_task

    assert_equal [ "pi:#{uuid}:aaaaaaaa" ], SessionTokenUsage.pluck(:request_id)
    assert_equal 1, run.stats["sessions_scanned"]
    assert_equal 1, run.stats["rows_written"]
  end

  # Not the cursor doing the work: the run is reset, so the second pass re-reads
  # the same transcript from the top and the unique `request_id` is what makes it
  # a no-op. That is the property a half-applied task depends on.
  test "a second pass re-reads the same transcript and writes nothing" do
    pi_session(entry_id: "bbbbbbbb", updated_at: 30.days.ago)

    run_task
    assert_equal 1, SessionTokenUsage.count

    run, _ = run_task
    assert_equal 1, SessionTokenUsage.count
    assert_equal 1, run.stats["sessions_scanned"]
    assert_equal 0, run.stats["rows_written"]
  end

  test "hands the worker thread back and resumes from its cursor" do
    3.times { |i| pi_session(entry_id: "cccccc0#{i}", updated_at: 30.days.ago) }

    run = fresh_run
    # A deadline already past stops the sweep after its first batch, which is what
    # a long corpus does to a 90-second slice.
    _, outcome = run_task(run: run, deadline: 1.second.ago)
    assert_equal PostDeployTask::CONTINUE, outcome
    assert run.reload.cursor["sweep_last_id"].present?
    cursor_after_first = run.cursor["sweep_last_id"]

    # The next tick continues from there rather than starting over.
    _, outcome = run_task(run: run)
    assert_nil outcome
    assert_operator run.reload.cursor["sweep_last_id"], :>=, cursor_after_first
    assert_equal 3, SessionTokenUsage.count
  end

  test "does not touch the other runtimes" do
    Session.create!(prompt: "claude", agent_runtime: "claude_code", status: :archived,
                    git_root: "https://github.com/tadasant/zimmer.git", branch: "main",
                    session_id: SecureRandom.uuid, transcript: "{}\n")

    run, _ = run_task

    assert_equal 0, SessionTokenUsage.count
    assert_equal 0, run.stats.fetch("sessions_scanned", 0)
  end
end
