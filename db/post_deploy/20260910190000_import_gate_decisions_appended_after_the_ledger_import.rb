# frozen_string_literal: true

# Imports the 50 gate decisions that reached the JSON ledger archive after
# ImportGateDecisionLedgers had already read it (tadasant/tadasant-internal#2432).
#
# WHY THEY ARE MISSING. ImportGateDecisionLedgers read the archive once, between
# 2026-09-02T15:02Z and 15:26Z. The gates went on appending to the JSON files for
# eight more hours, until the cutover to `record_gate_decision`
# (tadasant/tadasant-internal#2348, merged 23:19Z), and for about an hour after it
# as the documented fallback while that tool was unreachable. Nothing read the
# archive again, so none of those 52 appends, across 13 files, was imported.
# The first task's per-file counts on /health match
# the archive at d5b4fa3273 (the last ledger commit before it started) file for
# file, and every file since has only grown at its tail.
#
# WHY A PINNED LIST AND NOT A RE-RUN. `gate_decisions` is append-only, so a wrong
# insert is permanent. Two of the 52 were also recorded live, over MCP, under a
# different key: the tadasant-internal#2399 rating (id 1577) and its re-rate (id
# 1578, recorded as decided 2026-09-03 and labelled `correction`). A re-run of the
# importer would add both again. So this imports exactly the other 50: each was
# checked against the table with `search_gate_decisions` before this file was
# written, and each is named here by the key the importer gives it and the verdict
# it carries. The two it leaves out are
#
#   pr_merge|tadasant_internal|https://github.com/tadasant/tadasant-internal/pull/2399|2026-09-02#1  (id 1577)
#   pr_merge|tadasant_internal|https://github.com/tadasant/tadasant-internal/pull/2399|2026-09-02#2  (id 1578)
#
# The keys are LedgerImporter's own, ordinal and all, so a whole-file import over
# the archive would find these rows already present rather than add them again.
#
# A GUARD FOR ANYTHING RECORDED SINCE. A pinned entry is skipped if the table
# holds a row a gate recorded itself (MCP or API, not import) for the same gate
# and artifact, decided within a day of the entry. That is the shape #2399's
# re-rate took. None of the 50 matched it when they were checked; the guard is
# for a row recorded after that check and before this runs. It can only skip an
# insert, never add one, and a missed insert is the recoverable mistake: a later
# task can add a row, and nothing can take one away.
#
# A PINNED ENTRY IT CANNOT FIND IS A FAILURE. If one is absent from the archive,
# carries a different verdict, or is refused by the model, nothing is written for
# it. Every other file still finishes first, and then the task raises, so the run
# parks `failed` on /health, naming the unresolved entries, rather than reporting
# `succeeded` over a backfill it did not do. The files holding those entries are
# taken off the cursor before it raises, so a retry, or a re-arm from /health
# after the archive or this list is fixed, re-reads exactly those files.
#
# IDEMPOTENT. Rows are keyed on `source_key`, so a second pass finds each one
# present and writes nothing. `human_feedback` goes through the importer's own
# path onto the `imported` channel, and none of the 50 carries any.
class ImportGateDecisionsAppendedAfterTheLedgerImport < PostDeployTask
  # ledger file => { importer source key => the verdict that entry carries }
  PINNED = {
    "ISSUE_WORK_GATE_ARTIFACTS_LEDGER.json" => {
      "issue_work|artifacts|https://github.com/tadasant/tadasant-internal/issues/2341|2026-09-02#1" => "hold",
      "issue_work|artifacts|https://github.com/tadasant/tadasant-internal/issues/2326|2026-09-02#1" => "hold",
      "issue_work|artifacts|https://github.com/tadasant/tadasant-internal/issues/2343|2026-09-02#1" => "hold",
      "issue_work|artifacts|https://github.com/tadasant/tadasant-internal/issues/2371|2026-09-02#1" => "hold",
      "issue_work|artifacts|https://github.com/tadasant/tadasant-internal/issues/2408|2026-09-02#1" => "hold",
      "issue_work|artifacts|https://github.com/tadasant/tadasant-internal/issues/2416|2026-09-02#1" => "hold",
      "issue_work|artifacts|https://github.com/tadasant/tadasant-internal/issues/2417|2026-09-02#1" => "hold"
    },
    "ISSUE_WORK_GATE_OBS_LEDGER.json" => {
      "issue_work|obs|https://github.com/tadasant/tadasant-internal/issues/2353|2026-09-02#1" => "hold",
      "issue_work|obs|https://github.com/tadasant/tadasant-internal/issues/2397|2026-09-02#1" => "hold"
    },
    "ISSUE_WORK_GATE_STRAD_PRODUCTION_LEDGER.json" => {
      "issue_work|strad_production|https://github.com/tadasant/tadasant-internal/issues/2338|2026-09-02#1" => "hold",
      "issue_work|strad_production|https://github.com/tadasant/tadasant-internal/issues/2379|2026-09-02#1" => "hold"
    },
    "ISSUE_WORK_GATE_TADASANT_INTERNAL_LEDGER.json" => {
      "issue_work|tadasant_internal|https://github.com/tadasant/tadasant-internal/issues/2345|2026-09-02#1" => "auto-proceed",
      "issue_work|tadasant_internal|https://github.com/tadasant/tadasant-internal/issues/2342|2026-09-02#1" => "hold",
      "issue_work|tadasant_internal|https://github.com/tadasant/tadasant-internal/issues/2388|2026-09-02#1" => "hold",
      "issue_work|tadasant_internal|https://github.com/tadasant/tadasant-internal/issues/2400|2026-09-02#1" => "hold",
      "issue_work|tadasant_internal|https://github.com/tadasant/tadasant-internal/issues/2403|2026-09-02#1" => "hold",
      "issue_work|tadasant_internal|https://github.com/tadasant/tadasant-internal/issues/2390|2026-09-02#1" => "hold"
    },
    "ISSUE_WORK_GATE_ZIMMER_LEDGER.json" => {
      "issue_work|zimmer|https://github.com/tadasant/zimmer/issues/801|2026-09-02#1" => "auto-proceed",
      "issue_work|zimmer|https://github.com/tadasant/zimmer/issues/803|2026-09-02#1" => "auto-proceed",
      "issue_work|zimmer|https://github.com/tadasant/zimmer/issues/805|2026-09-02#1" => "hold",
      "issue_work|zimmer|https://github.com/tadasant/zimmer/issues/809|2026-09-02#1" => "auto-proceed",
      "issue_work|zimmer|https://github.com/tadasant/zimmer/issues/808|2026-09-02#1" => "auto-proceed",
      "issue_work|zimmer|https://github.com/tadasant/zimmer/issues/811|2026-09-02#1" => "hold",
      "issue_work|zimmer|https://github.com/tadasant/zimmer/issues/816|2026-09-02#1" => "auto-proceed",
      "issue_work|zimmer|https://github.com/tadasant/zimmer/issues/817|2026-09-02#1" => "auto-proceed"
    },
    "ISSUE_WORK_GATE_ZIMMER_PRODUCTION_LEDGER.json" => {
      "issue_work|zimmer_production|https://github.com/tadasant/tadasant-internal/issues/2373|2026-09-02#1" => "hold",
      "issue_work|zimmer_production|https://github.com/tadasant/tadasant-internal/issues/2374|2026-09-02#1" => "hold"
    },
    "PR_MERGE_GATE_ARTIFACTS_LEDGER.json" => {
      "pr_merge|artifacts|https://github.com/tadasant/tadasant-internal/pull/2328|2026-09-02#1" => "auto-merge",
      "pr_merge|artifacts|https://github.com/tadasant/tadasant-internal/pull/2335|2026-09-02#1" => "auto-merge",
      "pr_merge|artifacts|https://github.com/tadasant/tadasant-internal/pull/2336|2026-09-02#1" => "hold",
      "pr_merge|artifacts|https://github.com/tadasant/tadasant-internal/pull/2348|2026-09-02#1" => "hold"
    },
    "PR_MERGE_GATE_CI_RUNNER_LEDGER.json" => {
      "pr_merge|ci_runner|https://github.com/tadasant/tadasant-internal/pull/2406|2026-09-02#1" => "auto-merge"
    },
    "PR_MERGE_GATE_OBS_LEDGER.json" => {
      "pr_merge|obs|https://github.com/tadasant/tadasant-internal/pull/2387|2026-09-02#1" => "auto-merge",
      "pr_merge|obs|https://github.com/tadasant/tadasant-internal/pull/2402|2026-09-02#1" => "auto-merge"
    },
    "PR_MERGE_GATE_STRAD_PRODUCTION_LEDGER.json" => {
      "pr_merge|strad_production|https://github.com/tadasant/tadasant-internal/pull/2322|2026-09-02#1" => "auto-merge-verdict-recorded-retrospectively",
      "pr_merge|strad_production|https://github.com/tadasant/tadasant-internal/pull/2324|2026-09-02#2" => "hold",
      "pr_merge|strad_production|https://github.com/tadasant/tadasant-internal/pull/2376|2026-09-02#1" => "hold",
      "pr_merge|strad_production|https://github.com/tadasant/tadasant-internal/pull/2376|2026-09-02#2" => "hold"
    },
    "PR_MERGE_GATE_TADASANT_INTERNAL_LEDGER.json" => {
      "pr_merge|tadasant_internal|https://github.com/tadasant/tadasant-internal/pull/2346|2026-09-02#1" => "auto-merge"
    },
    "PR_MERGE_GATE_ZIMMER_LEDGER.json" => {
      "pr_merge|zimmer|https://github.com/tadasant/zimmer/pull/802|2026-09-02#1" => "auto-merge",
      "pr_merge|zimmer|https://github.com/tadasant/zimmer/pull/800|2026-09-02#1" => "auto-merge",
      "pr_merge|zimmer|https://github.com/tadasant/zimmer/pull/804|2026-09-02#1" => "hold",
      "pr_merge|zimmer|https://github.com/tadasant/zimmer/pull/806|2026-09-02#1" => "auto-merge",
      "pr_merge|zimmer|https://github.com/tadasant/zimmer/pull/807|2026-09-02#1" => "auto-merge",
      "pr_merge|zimmer|https://github.com/tadasant/zimmer/pull/810|2026-09-02#1" => "auto-merge",
      "pr_merge|zimmer|https://github.com/tadasant/zimmer/pull/812|2026-09-02#1" => "auto-merge",
      "pr_merge|zimmer|https://github.com/tadasant/zimmer/pull/810|2026-09-02#2" => "auto-merge",
      "pr_merge|zimmer|https://github.com/tadasant/zimmer/pull/813|2026-09-02#1" => "auto-merge",
      "pr_merge|zimmer|https://github.com/tadasant/zimmer/pull/818|2026-09-02#1" => "auto-merge"
    },
    "PR_MERGE_GATE_ZIMMER_PRODUCTION_LEDGER.json" => {
      "pr_merge|zimmer_production|https://github.com/tadasant/tadasant-internal/pull/2411|2026-09-02#1" => "auto-merge"
    }
  }.freeze

  # Outcomes that leave the decision in the table. Anything else is unresolved.
  RESOLVED = %w[imported already_present recorded_live].freeze

  class Unresolved < StandardError; end

  def up
    done = Array(cursor["files_done"])
    pending = PINNED.keys - done

    if pending.any?
      source = GateDecisions::LedgerSource.resolve
      importer = GateDecisions::LedgerImporter.new(source: source, logger: logger)
      listed = source.files.index_by(&:name)

      pending.each_with_index do |name, index|
        file = listed[name]
        outcomes, feedback = file ? import_pinned(importer, file, PINNED[name]) : [ PINNED[name].transform_values { "not_in_archive" }, 0 ]
        done += [ name ]
        record(done, outcomes, feedback)

        return CONTINUE if out_of_time? && index < pending.size - 1
      end
    end

    unresolved = pinned_outcomes.reject { |_key, outcome| RESOLVED.include?(status_of(outcome)) }
    return nil if unresolved.empty?

    # Hand every file holding an unresolved pin back to the next attempt, so a
    # retry or a re-arm re-reads those files and nothing else. Re-reading is
    # safe: a row already written is found by its key.
    retry_files = PINNED.select { |_name, pinned| pinned.keys.intersect?(unresolved.keys) }.keys
    checkpoint!(cursor: cursor.merge("files_done" => done - retry_files), files_done: (done - retry_files).size)

    raise Unresolved, "#{unresolved.size} pinned gate decision(s) were not imported: " +
                      unresolved.map { |key, outcome| "#{key} (#{outcome})" }.join("; ")
  rescue GateDecisions::LedgerSource::Unavailable => e
    # The same split as ImportGateDecisionLedgers: in production the archive
    # exists and not reading it is a failure to show on /health; everywhere else
    # there is no credential for tadasant/tadasant-internal and nothing to import.
    raise if Rails.env.production?

    logger.info("[ImportGateDecisionsAppendedAfterTheLedgerImport] no ledger source available in #{Rails.env}: #{e.message}")
    checkpoint!(skipped_reason: "no ledger source available in #{Rails.env}: #{e.message}")
    nil
  end

  private

  # @return [Array(Hash{String => String}, Integer)] an outcome per pinned key,
  #   and how many feedback notes were transcribed
  def import_pinned(importer, file, pinned)
    by_key = importer.keyed_entries(file).index_by(&:key)
    feedback = 0

    outcomes = pinned.to_h do |key, verdict|
      entry = by_key[key]
      live = entry && !GateDecision.exists?(source_key: key) && recorded_live(file, entry.parsed)

      outcome =
        if entry.nil?
          "not_in_archive"
        elsif entry.parsed.decision != verdict
          "verdict_mismatch (the archive says #{entry.parsed.decision.inspect})"
        elsif live
          "recorded_live as ##{live.id}"
        else
          result = GateDecision.transaction { importer.import_entry(file, entry) }
          feedback += result.feedback_imported
          result.status.to_s
        end

      logger.info("[ImportGateDecisionsAppendedAfterTheLedgerImport] #{file.name}: #{key}: #{outcome}")
      [ key, outcome ]
    end

    [ outcomes, feedback ]
  end

  # A row a gate recorded itself for the same artifact, within a day either side
  # of the entry's date. The window is the #2399 shape: appended to the archive as
  # 2026-09-02, recorded over MCP as 2026-09-03. Surface is deliberately not
  # matched: live rows have been recorded under the wrong one, and this guard can
  # only ever withhold an insert, so it errs wide.
  def recorded_live(file, parsed)
    return nil if parsed.artifact_url.blank? || parsed.decided_at.nil?

    GateDecision
      .where(gate: file.gate, artifact_url: parsed.artifact_url)
      .where.not(recorded_via: GateDecision::IMPORT)
      .where(decided_at: (parsed.decided_at - 1)..(parsed.decided_at + 1))
      .order(:id)
      .first
  end

  # The latest outcome for every pinned key. A key with none — its file has not
  # been read — counts as unresolved rather than silently passing.
  def pinned_outcomes
    recorded = stats.fetch("entries", {})
    PINNED.values.flat_map(&:keys).index_with { |key| recorded.fetch(key, "not_attempted") }
  end

  # One write per file read: the cursor that stops it being re-read, the outcome
  # of every pinned entry in it, and totals a reader can check against the 50
  # without counting. A re-read reports a row this task wrote earlier as
  # `imported` still, so the totals describe the backfill rather than the
  # latest pass.
  def record(done, outcomes, feedback)
    entries = stats.fetch("entries", {}).merge(outcomes) do |_key, before, now|
      before == "imported" && now == "already_present" ? before : now
    end.slice(*PINNED.values.flat_map(&:keys))
    tally = entries.values.map { |outcome| status_of(outcome) }.tally

    checkpoint!(
      cursor: cursor.merge("files_done" => done),
      entries: entries,
      files_done: done.size,
      pinned: PINNED.values.sum(&:size),
      imported: tally.fetch("imported", 0),
      already_present: tally.fetch("already_present", 0),
      recorded_live: tally.fetch("recorded_live", 0),
      unresolved: entries.size - RESOLVED.sum { |status| tally.fetch(status, 0) },
      feedback_imported: stats.fetch("feedback_imported", 0) + feedback
    )
  end

  def status_of(outcome) = outcome.to_s.split(" ").first
end
