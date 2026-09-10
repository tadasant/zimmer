# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The catch-up for tadasant/tadasant-internal#2432, against a ledger directory
# built the way the real archive is: every file holds a prefix the first import
# already read, and a tail appended after it. The tail is generated from the
# task's own pinned keys, so the fixture cannot drift from what the task expects
# to find — and it carries the two entries the task must NOT import, the
# tadasant-internal#2399 rating and re-rate that the gate also recorded over MCP.
class ImportGateDecisionsAppendedAfterTheLedgerImportTest < ActiveSupport::TestCase
  TI = "https://github.com/tadasant/tadasant-internal"
  PULL_2399 = "#{TI}/pull/2399"
  ISSUE_2416 = "#{TI}/issues/2416"
  ISSUE_2417 = "#{TI}/issues/2417"
  ISSUE_805 = "https://github.com/tadasant/zimmer/issues/805"
  PULL_2324 = "#{TI}/pull/2324"
  KEY_2416 = "issue_work|artifacts|#{ISSUE_2416}|2026-09-02#1"
  KEY_2417 = "issue_work|artifacts|#{ISSUE_2417}|2026-09-02#1"
  TI_PR_LEDGER = "PR_MERGE_GATE_TADASANT_INTERNAL_LEDGER.json"
  ARTIFACTS_ISSUE_LEDGER = "ISSUE_WORK_GATE_ARTIFACTS_LEDGER.json"

  setup do
    @entry = PostDeployTask::Registry.find("20260910190000")
    assert @entry, "the task file must ship in db/post_deploy"
    @task_class = @entry.task_class
    @pinned = @task_class::PINNED
    @dir = Dir.mktmpdir
  end

  teardown { FileUtils.remove_entry(@dir) }

  def entry_for(file, url, decided_at, decision, **extra)
    ledger = GateDecisions::LedgerFile.parse(file)
    artifact = ledger.gate == GateDecision::PR_MERGE ? "pr" : "issue"
    base = { artifact => url, "title" => "rating of #{url}", "decided_at" => decided_at,
             "decision" => decision, "reason" => "r", "human_feedback" => [] }
    base["surface"] = ledger.surface if artifact == "issue"
    base.merge(extra.deep_stringify_keys)
  end

  # { file => { prefix: [...], tail: [...] } }, shaped like the archive: an old
  # decision the first import read, any earlier same-day rating a pinned re-rate
  # is ordinal #2 of (tadasant-internal#2324's first rating is the real case),
  # then the pinned tail in order.
  def archive
    files = @pinned.keys.index_with do |file|
      artifact = GateDecisions::LedgerFile.parse(file).gate == GateDecision::PR_MERGE ? "pull" : "issues"
      { prefix: [ entry_for(file, "https://github.com/tadasant/zimmer/#{artifact}/1", "2026-08-20", "hold") ], tail: [] }
    end

    @pinned.each do |file, pinned|
      seen = Hash.new(0)

      pinned.each do |key, verdict|
        natural, ordinal = key.split("#")
        _gate, _surface, url, decided_at = natural.split("|")

        while seen[natural] < ordinal.to_i - 1
          files[file][:prefix] << entry_for(file, url, decided_at, "auto-merge")
          seen[natural] += 1
        end

        # ti#2416's real entry carries no human_feedback key at all; the rest carry [].
        entry = entry_for(file, url, decided_at, verdict)
        entry.delete("human_feedback") if url == ISSUE_2416
        files[file][:tail] << entry
        seen[natural] += 1
      end
    end

    # The two entries appended to the archive AND recorded live over MCP.
    files[TI_PR_LEDGER][:tail] << entry_for(TI_PR_LEDGER, PULL_2399, "2026-09-02", "auto-merge", reason: "rating")
    files[TI_PR_LEDGER][:tail] << entry_for(TI_PR_LEDGER, PULL_2399, "2026-09-02", "auto-merge", reason: "RE-RATE")
    files
  end

  def write_ledgers(files)
    files.each { |name, entries| File.write(File.join(@dir, name), JSON.pretty_generate(entries)) }
  end

  # Production as the task will find it: the prefixes imported by the first
  # task, and the #2399 pair and a much later zimmer#805 rating recorded live.
  def seed_production(files = archive)
    write_ledgers(files.transform_values { |parts| parts[:prefix] })
    GateDecisions::LedgerImporter.new(source: GateDecisions::LedgerSource::Directory.new(@dir)).call

    record_live(TI_PR_LEDGER, PULL_2399, "2026-09-02", "auto-merge")
    record_live(TI_PR_LEDGER, PULL_2399, "2026-09-03", "correction")
    record_live("ISSUE_WORK_GATE_ZIMMER_LEDGER.json", ISSUE_805, "2026-09-06", "auto-proceed")

    write_ledgers(files.transform_values { |parts| parts[:prefix] + parts[:tail] })
    files
  end

  def record_live(file, url, decided_at, decision)
    ledger = GateDecisions::LedgerFile.parse(file)
    GateDecisions::Record.call(gate: ledger.gate, surface: ledger.surface,
                               entry: entry_for(file, url, decided_at, decision),
                               recorded_via: GateDecision::MCP).decision
  end

  def run_task(deadline: nil)
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    outcome = with_ledger_dir(@dir) { @task_class.new(run: run, deadline: deadline, logger: Rails.logger).up }
    [ run.reload, outcome ]
  end

  def with_ledger_dir(dir)
    previous = ENV[GateDecisions::LedgerSource::DIR_ENV_VAR]
    ENV[GateDecisions::LedgerSource::DIR_ENV_VAR] = dir
    yield
  ensure
    ENV[GateDecisions::LedgerSource::DIR_ENV_VAR] = previous
  end

  test "the pinned list is the 50 tail entries, keyed for the file each one is read from" do
    keys = @pinned.values.flat_map(&:keys)

    assert_equal 50, keys.size
    assert_equal keys.uniq, keys
    assert_includes keys, KEY_2416
    assert_includes keys, KEY_2417
    assert_empty keys.grep(%r{/pull/2399\|}), "the #2399 pair is recorded live and must never be pinned"

    @pinned.each do |file, pinned|
      ledger = GateDecisions::LedgerFile.parse(file)
      assert ledger, "#{file} is not a ledger file name"
      pinned.each_key { |key| assert key.start_with?("#{ledger.gate}|#{ledger.surface}|"), "#{key} is not from #{file}" }
    end
  end

  test "imports every pinned entry and leaves the #2399 pair to the rows recorded live" do
    seed_production
    before_2399 = GateDecision.for_artifact(PULL_2399).count

    run, outcome = run_task

    assert_nil outcome
    assert_equal 50, run.stats["imported"]
    assert_equal 0, run.stats["unresolved"]
    assert_equal 0, run.stats["recorded_live"]
    assert_equal 13, run.stats["files_done"]
    assert_equal "imported", run.stats.dig("entries", KEY_2416)

    [ [ ISSUE_2416, KEY_2416 ], [ ISSUE_2417, KEY_2417 ] ].each do |url, key|
      decision = GateDecision.for_artifact(url).sole
      assert_equal key, decision.source_key
      assert_equal GateDecision::IMPORT, decision.recorded_via
      assert_equal [ "issue_work", "artifacts", "hold", Date.new(2026, 9, 2) ],
                   [ decision.gate, decision.surface, decision.decision, decision.decided_at ]
      assert_nil decision.writing_session_id
    end

    assert_equal 2, before_2399
    assert_equal before_2399, GateDecision.for_artifact(PULL_2399).count, "the #2399 pair must not be imported again"
    assert_equal [ "auto-merge", "hold" ], GateDecision.for_artifact(PULL_2324).order(:id).pluck(:decision),
                 "the re-rate is ordinal #2 beside the rating the first import already holds"
    assert_equal [ Date.new(2026, 9, 2), Date.new(2026, 9, 6) ],
                 GateDecision.for_artifact(ISSUE_805).order(:decided_at).pluck(:decided_at),
                 "a live rating four days later is a different decision, not this one"
    assert_equal 0, GateDecisionFeedback.count, "none of the 50 carries a human_feedback note"
  end

  test "a second run writes nothing" do
    seed_production
    run_task
    before = GateDecision.count

    PostDeployTaskRun.delete_all
    run, outcome = run_task

    assert_nil outcome
    assert_equal before, GateDecision.count
    assert_equal 0, run.stats["imported"]
    assert_equal 50, run.stats["already_present"]
    assert_equal "already_present", run.stats.dig("entries", KEY_2416)
  end

  test "it keys rows exactly as the whole-file importer does, which would have duplicated #2399" do
    seed_production
    run_task

    # Every entry the task imported is already present to a whole-file pass. The
    # only thing that pass would add is the #2399 pair — the duplicate this task
    # exists to avoid.
    result = GateDecisions::LedgerImporter.new(source: GateDecisions::LedgerSource::Directory.new(@dir)).call

    assert_equal 2, result.imported
    assert_equal 4, GateDecision.for_artifact(PULL_2399).count
  end

  test "a pinned entry a gate has since recorded live is left alone" do
    seed_production
    live = record_live(ARTIFACTS_ISSUE_LEDGER, ISSUE_2416, "2026-09-03", "hold")

    run, outcome = run_task

    assert_nil outcome
    assert_equal [ live.id ], GateDecision.for_artifact(ISSUE_2416).pluck(:id)
    assert_equal "recorded_live as ##{live.id}", run.stats.dig("entries", KEY_2416)
    assert_equal 1, run.stats["recorded_live"]
    assert_equal 49, run.stats["imported"]
  end

  test "the live-record guard does not trust the surface a live row was recorded under" do
    seed_production
    # A live row carrying the wrong surface is a real shape: id 1652 is a
    # tadasant-internal issue recorded under `zimmer`.
    live = GateDecisions::Record.call(gate: GateDecision::ISSUE_WORK, surface: "zimmer",
                                      entry: entry_for(ARTIFACTS_ISSUE_LEDGER, ISSUE_2416, "2026-09-02", "hold"),
                                      recorded_via: GateDecision::MCP).decision

    run, = run_task

    assert_equal "recorded_live as ##{live.id}", run.stats.dig("entries", KEY_2416)
    assert_equal [ live.id ], GateDecision.for_artifact(ISSUE_2416).pluck(:id)
  end

  test "a pinned entry missing from the archive fails the run, and a retry re-reads only its file" do
    full = archive
    files = full.deep_dup
    files[ARTIFACTS_ISSUE_LEDGER][:tail].reject! { |entry| entry["issue"] == ISSUE_2417 }
    seed_production(files)

    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    error = assert_raises(@task_class::Unresolved) do
      with_ledger_dir(@dir) { @task_class.new(run: run, logger: Rails.logger).up }
    end

    assert_match KEY_2417, error.message
    assert_equal "not_in_archive", run.reload.stats.dig("entries", KEY_2417)
    assert_equal 49, run.stats["imported"]
    assert_equal 1, run.stats["unresolved"]
    assert GateDecision.for_artifact(ISSUE_2416).exists?
    assert_not GateDecision.for_artifact(ISSUE_2417).exists?
    assert_equal @pinned.keys - [ ARTIFACTS_ISSUE_LEDGER ], run.cursor["files_done"],
                 "the file holding the unresolved pin is handed back to the next attempt"

    # The archive regains the entry; the retry reads that one file and finishes.
    write_ledgers(full.transform_values { |parts| parts[:prefix] + parts[:tail] })
    before = GateDecision.count
    outcome = with_ledger_dir(@dir) { @task_class.new(run: run, logger: Rails.logger).up }

    assert_nil outcome
    assert_equal before + 1, GateDecision.count
    assert GateDecision.for_artifact(ISSUE_2417).exists?
    run.reload
    assert_equal [ 50, 0, 0 ], run.stats.values_at("imported", "already_present", "unresolved"),
                 "rows written by the failed attempt still count as imported"
    assert_equal 13, run.cursor["files_done"].size
  end

  test "a pinned entry the model refuses fails the run without costing the others" do
    files = archive
    files[ARTIFACTS_ISSUE_LEDGER][:tail].find { |entry| entry["issue"] == ISSUE_2416 }["reason"] =
      "x" * (GateDecision::MAX_PAYLOAD_BYTES + 1)
    seed_production(files)

    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    assert_raises(@task_class::Unresolved) do
      with_ledger_dir(@dir) { @task_class.new(run: run, logger: Rails.logger).up }
    end

    assert_equal "rejected", run.reload.stats.dig("entries", KEY_2416)
    assert_equal [ 49, 1 ], run.stats.values_at("imported", "unresolved")
    assert_not GateDecision.for_artifact(ISSUE_2416).exists?
  end

  test "a pinned entry whose verdict differs is not imported" do
    files = archive
    files[ARTIFACTS_ISSUE_LEDGER][:tail].find { |entry| entry["issue"] == ISSUE_2416 }["decision"] = "auto-proceed"
    seed_production(files)

    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")
    assert_raises(@task_class::Unresolved) do
      with_ledger_dir(@dir) { @task_class.new(run: run, logger: Rails.logger).up }
    end

    assert_match(/verdict_mismatch/, run.reload.stats.dig("entries", KEY_2416))
    assert_equal [ 49, 1 ], run.stats.values_at("imported", "unresolved")
    assert_not GateDecision.for_artifact(ISSUE_2416).exists?
  end

  test "an exhausted budget checkpoints per file and the next slice finishes" do
    seed_production

    run, outcome = run_task(deadline: 1.hour.ago)

    assert_equal PostDeployTask::CONTINUE, outcome
    assert_equal 1, run.cursor["files_done"].size

    slices = 1
    until outcome.nil?
      flunk "still asking to be resumed after #{slices} slices" if slices >= @pinned.size
      outcome = with_ledger_dir(@dir) { @task_class.new(run: run, deadline: 1.hour.ago, logger: Rails.logger).up }
      run.reload
      slices += 1
    end

    assert_equal 13, slices, "one file per slice when the budget is spent"
    assert_equal 50, run.stats["imported"]
    assert_equal 13, run.cursor["files_done"].size
  end

  test "outside production, an unreachable source is recorded and the task completes" do
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")

    outcome = with_ledger_dir("/nope/not/here") { @task_class.new(run: run, logger: Rails.logger).up }

    assert_nil outcome
    assert_match(/no ledger source available/, run.reload.stats["skipped_reason"])
    assert_equal 0, GateDecision.count
  end

  test "in production, an unreachable source fails loudly" do
    run = PostDeployTaskRun.ledger_for(@entry)
    run.claim!(owner: "test")

    Rails.env.stub(:production?, true) do
      assert_raises(GateDecisions::LedgerSource::Unavailable) do
        with_ledger_dir("/nope/not/here") { @task_class.new(run: run, logger: Rails.logger).up }
      end
    end
  end
end
