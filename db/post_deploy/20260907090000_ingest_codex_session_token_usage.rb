# frozen_string_literal: true

# Sweeps every Codex rollout that already exists into the token-spend ledger, once.
#
# CodexTokenUsageIngestionService ships with this deploy, and the cron that calls
# it passes a two-hour lookback — so without this task the ledger would start at
# the deploy and every Codex session run before it would stay at zero forever.
# There were 51 of them on this deployment when the ingestor landed
# ([#1077](https://github.com/tadasant/zimmer/issues/1077)).
#
# Its corpus is a filesystem tree rather than a relation, so `PostDeployTask#sweep`
# does not fit: this pages `CodexTokenUsageIngestionService.rollout_paths` — the
# same sorted list a cron run walks — and carries the last path it finished in the
# cursor. Sorted order makes that cursor total: a rollout written while the sweep
# is in flight lands in a LATER date partition than any path already passed, so it
# is either picked up by this run or by the cron's two-hour window, never lost
# between them.
#
# A post-deploy task rather than a rake task because there is no shell on the
# production box to run one from (AGENTS.md, "No production box access"), and it
# answers for itself in `post_deploy_task_runs` — on /health, in
# `GET /api/v1/health`, from `get_system_health`, at
# /supervisor/post_deploy_task_runs.
#
# Idempotent for the same reason every ingestion run is: rows are keyed on
# `request_id` and written with `insert_all ... unique_by`, so a rollout read
# twice writes nothing the second time. Running it after the cron has already
# swept the recent rollouts is a no-op on those and a first write on the rest.
class IngestCodexSessionTokenUsage < PostDeployTask
  # Rollouts per slice. Small, because the unit of work is streaming one whole
  # rollout — the largest on this deployment is 1.7 MB of JSONL, and a finished
  # one has to be Zstandard-decompressed first. The budget is only checked
  # between batches, so a batch has to be something that finishes.
  BATCH_SIZE = 25

  CURSOR_KEY = "sweep_last_path"

  def up
    root = CodexTokenUsageIngestionService.default_root
    paths = CodexTokenUsageIngestionService.rollout_paths(root: root)
    last = cursor[CURSOR_KEY]
    remaining = last.nil? ? paths : paths.drop_while { |path| path <= last }

    loop do
      batch = remaining.first(BATCH_SIZE)
      return nil if batch.empty?

      remaining = remaining.drop(BATCH_SIZE)

      # `modified_since: nil` — the whole corpus, not a window. That is the one
      # thing this task does that the cron cannot.
      result = CodexTokenUsageIngestionService.new(
        root: root,
        modified_since: nil,
        paths: batch,
        logger: Rails.logger
      ).call

      last = batch.last
      checkpoint!(
        cursor: cursor.merge(CURSOR_KEY => last),
        # The corpus this run claims to have covered, named rather than implied:
        # `CODEX_HOME` moves the tree, and a coverage figure that does not say
        # which tree it swept cannot be checked.
        root: root,
        rollouts_scanned: stats.fetch("rollouts_scanned", 0) + result.files_scanned,
        rows_written: stats.fetch("rows_written", 0) + result.session_rows,
        skipped_events: stats.fetch("skipped_events", 0) + result.skipped_events
      )

      return CONTINUE if out_of_time?
    end
  end
end
