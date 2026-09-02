# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The backfill as it will actually run in production: a post-deploy task, on the
# deploy, with no shell involved.
class ImportGateDecisionLedgersTest < ActiveSupport::TestCase
  setup do
    @entry = PostDeployTask::Registry.find("20260902091500")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
  end

  def ledger_dir(files)
    dir = Dir.mktmpdir
    files.each { |name, entries| File.write(File.join(dir, name), JSON.pretty_generate(entries)) }
    dir
  end

  def pr_entry(number:, decided_at: "2026-08-15")
    { "pr" => "https://github.com/tadasant/zimmer/pull/#{number}", "title" => "PR #{number}",
      "decided_at" => decided_at, "decision" => "auto-merge", "reason" => "r", "human_feedback" => [] }
  end

  def run_task(dir, deadline: nil)
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    outcome = with_ledger_dir(dir) { @task_class.new(run: run, deadline: deadline, logger: Rails.logger).up }
    [ run.reload, outcome ]
  end

  def with_ledger_dir(dir)
    previous = ENV[GateDecisions::LedgerSource::DIR_ENV_VAR]
    ENV[GateDecisions::LedgerSource::DIR_ENV_VAR] = dir
    yield
  ensure
    ENV[GateDecisions::LedgerSource::DIR_ENV_VAR] = previous
  end

  test "imports the ledgers and reports per-file counts a human can check" do
    dir = ledger_dir(
      "PR_MERGE_GATE_ZIMMER_LEDGER.json" => [ pr_entry(number: 1), pr_entry(number: 2) ],
      "ISSUE_WORK_GATE_ZIMMER_LEDGER.json" => [ { "issue" => "https://github.com/tadasant/zimmer/issues/9",
                                                  "decided_at" => "2026-08-14", "decision" => "hold" } ]
    )

    run, outcome = run_task(dir)

    assert_nil outcome, "a finished task returns something other than CONTINUE"
    assert_equal 3, GateDecision.count
    assert_equal 3, run.stats["decisions_imported"]
    assert_equal 3, run.stats["entries_seen"]
    assert_equal 0, run.stats["files_remaining"]
    assert_equal 2, run.stats.dig("per_file", "PR_MERGE_GATE_ZIMMER_LEDGER.json", "imported")
    assert_equal 1, run.stats.dig("per_file", "ISSUE_WORK_GATE_ZIMMER_LEDGER.json", "imported")
  end

  test "running the task twice leaves the row count unchanged" do
    dir = ledger_dir("PR_MERGE_GATE_ZIMMER_LEDGER.json" => [ pr_entry(number: 1), pr_entry(number: 2) ])

    run_task(dir)
    before = GateDecision.count

    # A fresh ledger row, as a re-armed task would get.
    PostDeployTaskRun.delete_all
    run, = run_task(dir)

    assert_equal before, GateDecision.count
    assert_equal 0, run.stats["decisions_imported"]
    assert_equal 2, run.stats["already_present"]
  end

  test "an exhausted budget asks to be resumed and the next slice finishes the job" do
    dir = ledger_dir(
      "ISSUE_WORK_GATE_ZIMMER_LEDGER.json" => [ { "issue" => "https://x/1", "decided_at" => "2026-08-14" } ],
      "PR_MERGE_GATE_ZIMMER_LEDGER.json" => [ pr_entry(number: 2) ]
    )

    run, outcome = run_task(dir, deadline: 1.hour.ago)

    assert_equal PostDeployTask::CONTINUE, outcome
    assert_equal 1, GateDecision.count
    assert_equal 1, run.cursor["files_done"].size

    run.claim!(owner: "test")
    resumed = with_ledger_dir(dir) { @task_class.new(run: run, logger: Rails.logger).up }

    assert_nil resumed
    assert_equal 2, GateDecision.count
  end

  test "outside production, an unreachable source is recorded and the task completes" do
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")

    outcome = with_ledger_dir("/nope/not/here") { @task_class.new(run: run, logger: Rails.logger).up }

    assert_nil outcome
    assert_match(/no ledger source available/, run.reload.stats["skipped_reason"])
    assert_equal 0, GateDecision.count
  end

  test "in production, an unreachable source fails loudly instead of claiming success" do
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")

    Rails.env.stub(:production?, true) do
      assert_raises(GateDecisions::LedgerSource::Unavailable) do
        with_ledger_dir("/nope/not/here") { @task_class.new(run: run, logger: Rails.logger).up }
      end
    end
  end
end
