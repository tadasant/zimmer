# frozen_string_literal: true

# Backfills the historical gate decision ledgers into `gate_decisions`.
#
# THE POINT OF THIS FILE: 1,469 entries across 19 JSON files in a different
# repository have to become rows before anything can read them from the database.
# That is a one-time step, it needs application code, and it must not need a
# shell on the production box — which is what a post-deploy task is for. It runs
# itself within a couple of minutes of the deploy, and whether it ran (and what
# it covered) is a row in `post_deploy_task_runs`, rendered on /health, in
# GET /api/v1/health, by `get_system_health` and at
# /supervisor/post_deploy_task_runs.
#
# IDEMPOTENT. The importer only inserts, keyed on the entry's identity, so a
# second pass finds every row already present and writes nothing. It never edits
# or deletes a row, and it never touches the source JSON files — the gates keep
# appending to them until a later phase cuts them over, and nothing here breaks
# if they do.
#
# SLICED BY FILE, AND CHECKPOINTED BY FILE. The largest ledger is 3.4 MB fetched
# over the network, so the budget is checked between files. The cursor is written
# as each file finishes rather than once at the end of the slice: a worker killed
# mid-slice (a deploy, an OOM, the lease expiring) would otherwise lose the record
# of every file it had already done and re-fetch all of them on the next tick.
class ImportGateDecisionLedgers < PostDeployTask
  def up
    source = GateDecisions::LedgerSource.resolve
    done = Array(cursor["files_done"])

    result = GateDecisions::LedgerImporter.new(source: source, logger: logger).call(
      done: done,
      stop_when: -> { out_of_time? },
      on_file: ->(file) { done = record_file(done, file) }
    )

    result.complete? ? nil : CONTINUE
  rescue GateDecisions::LedgerSource::Unavailable => e
    # In production this is a real failure and must be visible as one: the ledger
    # exists, we could not read it, and the backfill has not happened. It backs
    # off, then parks `failed` on the health page with the reason, re-armable
    # from a button rather than a shell. Whatever the earlier files imported is
    # already checkpointed, so the retry resumes rather than starting over.
    raise if Rails.env.production?

    # Everywhere else it is the expected outcome. Staging and development have no
    # credential for `tadasant/tadasant-internal` and no gate history worth
    # importing, and a permanently-critical health panel there would only teach
    # people to ignore the panel.
    logger.info("[ImportGateDecisionLedgers] no ledger source available in #{Rails.env}: #{e.message}")
    checkpoint!(skipped_reason: "no ledger source available in #{Rails.env}: #{e.message}")
    nil
  end

  private

  # One write per finished file: the cursor that stops it being re-read, and the
  # counters that make "did it import everything?" a question the health panel
  # answers rather than one somebody takes on trust. The per-file numbers are the
  # point — "1,469 rows" is only checkable against the source if you can see it
  # was 290 from the zimmer PR ledger and 309 from the zimmer issue one.
  def record_file(done, file)
    done += [ file.name ]

    per_file = stats.fetch("per_file", {}).merge(
      file.name => {
        "entries" => file.entries, "imported" => file.imported,
        "already_present" => file.skipped, "rejected" => file.rejected
      }
    )

    checkpoint!(
      cursor: cursor.merge("files_done" => done),
      per_file: per_file,
      files_done: done.size,
      entries_seen: total(per_file, "entries"),
      decisions_imported: total(per_file, "imported"),
      already_present: total(per_file, "already_present"),
      rejected: total(per_file, "rejected"),
      feedback_imported: stats.fetch("feedback_imported", 0) + file.feedback_imported
    )

    done
  end

  def total(per_file, key)
    per_file.values.sum { |counts| counts[key].to_i }
  end
end
