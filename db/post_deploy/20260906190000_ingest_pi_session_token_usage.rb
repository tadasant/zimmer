# frozen_string_literal: true

# Sweeps every Pi session that already exists into the token-spend ledger, once.
#
# PiTokenUsageIngestionService ships with this deploy, and the cron that calls it
# passes a two-hour lookback — so without this task the ledger would start at the
# deploy and every Pi session run before it would stay at zero forever. Claude
# Code's equivalent gap is covered by TokenUsageBackfillJob, which walks a
# filesystem corpus with a cursor; Pi's corpus is the stored transcript of every
# `agent_runtime = 'pi'` session, small enough that a single pass is the whole job.
#
# A post-deploy task rather than a rake task because there is no shell on the
# production box to run one from (AGENTS.md, "No production box access"), and it
# answers for itself in `post_deploy_task_runs` — on /health, in
# `GET /api/v1/health`, from `get_system_health`, at
# /supervisor/post_deploy_task_runs.
#
# Idempotent for the same reason every ingestion run is: rows are keyed on
# `request_id` and written with `insert_all ... unique_by`, so a session read
# twice writes nothing the second time. Running it after the cron has already
# swept the recent sessions is a no-op on those and a first write on the rest.
class IngestPiSessionTokenUsage < PostDeployTask
  # Sessions per slice. Small, because the unit of work is parsing one whole
  # stored transcript and those run to megabytes — the budget is only checked
  # between batches, so a batch has to be something that finishes.
  BATCH_SIZE = 25

  # Spelled out rather than read from the service, the way a migration names its
  # own columns: a task file has to keep loading after the code that motivated it
  # has moved on, and a fresh environment runs every task in this directory from
  # scratch.
  PI_RUNTIME = "pi"

  def up
    # Either storage counts as "has a transcript": the chunk set for everything
    # written since #110, the legacy `sessions.transcript` column for the rows
    # `BackfillSessionTranscriptChunks` has not reached yet.
    scope = Session.select(:id)
                   .where(agent_runtime: PI_RUNTIME)
                   .where("sessions.transcript_byte_size > 0 OR sessions.transcript IS NOT NULL")

    sweep(scope, batch_size: BATCH_SIZE) do |batch|
      # `modified_since: nil` — the whole of each session, not a window. That is
      # the one thing this task does that the cron cannot.
      result = PiTokenUsageIngestionService.new(
        modified_since: nil,
        session_ids: batch.map(&:id),
        logger: Rails.logger
      ).call

      checkpoint!(
        sessions_scanned: stats.fetch("sessions_scanned", 0) + result.sessions_scanned,
        rows_written: stats.fetch("rows_written", 0) + result.session_rows,
        skipped_entries: stats.fetch("skipped_entries", 0) + result.skipped_entries
      )
    end
  end
end
