# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The backfill, against ledger files shaped like the real ones — including the
# two shapes that would quietly lose data if the key were naive: two ratings of
# the same PR on the same day (a re-rate), and an entry with no artifact at all.
class GateDecisions::LedgerImporterTest < ActiveSupport::TestCase
  def pr_entry(number:, decided_at: "2026-08-15", decision: "auto-merge", **extra)
    {
      "pr" => "https://github.com/tadasant/zimmer/pull/#{number}",
      "title" => "PR #{number}",
      "decided_at" => decided_at,
      "issue" => "https://github.com/tadasant/zimmer/issues/#{number} -- prose about the issue",
      "producing_session" => "https://zimmer.tadasant.com/sessions/#{number}. Some prose.",
      "problem" => "p", "solution" => "s", "ratings" => { "a" => 1 },
      "decision" => decision, "reason" => "r", "human_feedback" => []
    }.merge(extra.deep_stringify_keys)
  end

  def issue_entry(number:, decided_at: "2026-08-15", **extra)
    {
      "issue" => "https://github.com/tadasant/zimmer/issues/#{number}",
      "title" => "Issue #{number}", "decided_at" => decided_at, "author" => "tadasant",
      "surface" => "zimmer", "posture" => "action-by-default", "kind" => "bug",
      "facets" => [], "ratings" => {}, "decision" => "hold", "reason" => "r",
      "spawned_session" => "https://zimmer.tadasant.com/sessions/#{number}",
      "human_feedback" => []
    }.merge(extra.deep_stringify_keys)
  end

  def with_ledgers(files)
    Dir.mktmpdir do |dir|
      files.each { |name, entries| File.write(File.join(dir, name), JSON.pretty_generate(entries)) }
      yield GateDecisions::LedgerSource::Directory.new(dir), dir
    end
  end

  def import(source, **options)
    GateDecisions::LedgerImporter.new(source: source, logger: Rails.logger).call(**options)
  end

  test "reads the gate and surface off the filename and imports every entry" do
    with_ledgers(
      "PR_MERGE_GATE_ZIMMER_LEDGER.json" => [ pr_entry(number: 1), pr_entry(number: 2) ],
      "ISSUE_WORK_GATE_STRAD_PRODUCTION_LEDGER.json" => [ issue_entry(number: 3) ]
    ) do |source|
      result = import(source)

      assert_equal 3, result.imported
      assert_equal 3, GateDecision.count
      assert_equal 2, GateDecision.for_gate("pr_merge").for_surface("zimmer").count
      assert_equal 1, GateDecision.for_gate("issue_work").for_surface("strad_production").count
      assert result.complete?
    end
  end

  test "running it twice imports nothing the second time" do
    with_ledgers("PR_MERGE_GATE_ZIMMER_LEDGER.json" => [ pr_entry(number: 1), pr_entry(number: 2) ]) do |source|
      import(source)
      before = GateDecision.count

      second = import(source)

      assert_equal 0, second.imported
      assert_equal 2, second.skipped
      assert_equal before, GateDecision.count
    end
  end

  test "a re-rate of the same artifact on the same day survives as its own row" do
    # The real corpus holds 59 of these — the same PR rated twice in a day
    # because the base branch moved. Keying on (gate, surface, artifact, date)
    # alone would collapse them and silently lose the history a gate calibrates on.
    entries = [
      pr_entry(number: 749, decision: "hold", reason: "first reading"),
      pr_entry(number: 749, decision: "auto-merge", reason: "re-rate after rebase")
    ]

    with_ledgers("PR_MERGE_GATE_ZIMMER_LEDGER.json" => entries) do |source|
      assert_equal 2, import(source).imported
      assert_equal 2, GateDecision.for_artifact("https://github.com/tadasant/zimmer/pull/749").count

      assert_equal 0, import(source).imported, "and a second pass still adds nothing"
      assert_equal 2, GateDecision.count
    end
  end

  test "later appends import without re-importing what was already there" do
    with_ledgers("PR_MERGE_GATE_ZIMMER_LEDGER.json" => [ pr_entry(number: 1) ]) do |source, dir|
      import(source)

      File.write(File.join(dir, "PR_MERGE_GATE_ZIMMER_LEDGER.json"),
                 JSON.pretty_generate([ pr_entry(number: 1), pr_entry(number: 2) ]))
      second = import(source)

      assert_equal 1, second.imported
      assert_equal 1, second.skipped
      assert_equal 2, GateDecision.count
    end
  end

  test "an entry with no artifact and no date is imported rather than dropped" do
    salvaged = { "pr" => nil, "decided_at" => nil, "title" => "SALVAGED FRAGMENT", "decision" => nil }

    with_ledgers("PR_MERGE_GATE_ARTIFACTS_LEDGER.json" => [ salvaged ]) do |source|
      assert_equal 1, import(source).imported

      decision = GateDecision.sole
      assert_nil decision.artifact_url
      assert_nil decision.decided_at
      assert_equal "SALVAGED FRAGMENT", decision.title
      assert_equal 0, import(source).imported, "and it is still keyed stably on a second pass"
    end
  end

  test "human_feedback becomes rows on the imported channel, and only once" do
    entry = pr_entry(number: 5, human_feedback: [
      { "received_at" => "2026-08-01", "verdict" => "should-have-merged", "note" => "Tadas said so." }
    ])

    with_ledgers("PR_MERGE_GATE_ZIMMER_LEDGER.json" => [ entry ]) do |source|
      result = import(source)

      assert_equal 1, result.feedback_imported
      feedback = GateDecisionFeedback.sole
      assert_equal "should-have-merged", feedback.verdict
      assert_equal Date.new(2026, 8, 1), feedback.received_at
      assert_equal GateDecisionFeedback::IMPORTED, feedback.channel
      assert_nil feedback.author, "the source did not record who, so neither do we"

      assert_equal 0, import(source).feedback_imported
      assert_equal 1, GateDecisionFeedback.count
    end
  end

  test "feedback added to an already-imported entry is picked up on a later pass" do
    with_ledgers("PR_MERGE_GATE_ZIMMER_LEDGER.json" => [ pr_entry(number: 5) ]) do |source, dir|
      import(source)
      assert_equal 0, GateDecisionFeedback.count

      File.write(File.join(dir, "PR_MERGE_GATE_ZIMMER_LEDGER.json"), JSON.pretty_generate([
        pr_entry(number: 5, human_feedback: [ { "received_at" => "2026-08-02", "verdict" => "mischaracterized" } ])
      ]))
      second = import(source)

      assert_equal 0, second.imported
      assert_equal 1, second.feedback_imported
      assert_equal GateDecisionFeedback::IMPORTED, GateDecisionFeedback.sole.channel
    end
  end

  test "every imported row is stamped as an import and names no writing session" do
    with_ledgers("PR_MERGE_GATE_ZIMMER_LEDGER.json" => [ pr_entry(number: 1) ]) do |source|
      import(source)

      decision = GateDecision.sole
      assert_equal GateDecision::IMPORT, decision.recorded_via
      assert_nil decision.writing_session_id
    end
  end

  test "the budget is honoured between files and the rest is reported as remaining" do
    files = {
      "ISSUE_WORK_GATE_ZIMMER_LEDGER.json" => [ issue_entry(number: 1) ],
      "PR_MERGE_GATE_ZIMMER_LEDGER.json" => [ pr_entry(number: 2) ]
    }

    with_ledgers(**files) do |source|
      first = import(source, stop_when: -> { true })

      assert_equal 1, first.files.size
      assert_equal 1, first.imported
      assert_equal 1, first.remaining.size
      assert_not first.complete?

      second = import(source, done: first.files.map(&:name), stop_when: -> { true })

      assert_equal 1, second.imported
      assert second.complete?
      assert_equal 2, GateDecision.count
    end
  end

  test "a file that is not a ledger is ignored" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "PR_MERGE_GATE_LEDGER.md"), "# prose")
      File.write(File.join(dir, "WORK_BACKLOG.json"), JSON.generate([ { "issue" => "https://x/1" } ]))
      File.write(File.join(dir, "PR_MERGE_GATE_ZIMMER_LEDGER.json"), JSON.generate([ pr_entry(number: 1) ]))

      result = import(GateDecisions::LedgerSource::Directory.new(dir))

      assert_equal [ "PR_MERGE_GATE_ZIMMER_LEDGER.json" ], result.files.map(&:name)
      assert_equal 1, GateDecision.count
    end
  end

  # One bad entry must not cost the other 1,468. Without isolation the raise
  # unwinds the batch, the file, the slice and the whole post-deploy task, which
  # then retries on a backoff and fails identically forever.
  test "an entry the model refuses is counted and skipped, not fatal" do
    with_ledgers("PR_MERGE_GATE_ZIMMER_LEDGER.json" => [
      pr_entry(number: 1),
      pr_entry(number: 2, reason: "x" * (GateDecision::MAX_PAYLOAD_BYTES + 1)),
      pr_entry(number: 3)
    ]) do |source|
      result = import(source)

      assert_equal 2, result.imported
      assert_equal 1, result.rejected
      assert_equal 3, result.entries
      assert_equal 2, GateDecision.count
    end
  end

  test "each file is reported the moment it finishes, so a caller can checkpoint per file" do
    with_ledgers(
      "ISSUE_WORK_GATE_ZIMMER_LEDGER.json" => [ issue_entry(number: 1) ],
      "PR_MERGE_GATE_ZIMMER_LEDGER.json" => [ pr_entry(number: 2) ]
    ) do |source|
      seen = []
      import(source, on_file: ->(file) { seen << [ file.name, GateDecision.count ] })

      assert_equal [ [ "ISSUE_WORK_GATE_ZIMMER_LEDGER.json", 1 ],
                     [ "PR_MERGE_GATE_ZIMMER_LEDGER.json", 2 ] ], seen
    end
  end

  test "a missing directory says so rather than importing nothing quietly" do
    error = assert_raises(GateDecisions::LedgerSource::Unavailable) do
      import(GateDecisions::LedgerSource::Directory.new("/nope/not/here"))
    end

    assert_match(/not a directory/, error.message)
  end
end
