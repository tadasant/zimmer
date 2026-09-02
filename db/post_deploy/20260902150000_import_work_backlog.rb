# frozen_string_literal: true

# Imports the agent fleet's work backlog — `WORK_BACKLOG.json` in
# `tadasant/tadasant-internal` — into `work_backlog_items`.
#
# THE POINT OF THIS FILE: the queue has to exist in the database before the
# Issues view can show it or the gate and groomer can be cut over to the tools
# that read it. That is a one-time step, it needs application code, and it must
# not need a shell on the production box — which is what a post-deploy task is
# for. It runs itself within a couple of minutes of the deploy, and whether it
# ran (and how many items it covered) is a row in `post_deploy_task_runs`,
# rendered on /health, in GET /api/v1/health, by `get_system_health` and at
# /supervisor/post_deploy_task_runs.
#
# IDEMPOTENT. The importer only inserts, keyed on each item's `id`, so a second
# pass finds every row already present and writes nothing. It never edits or
# deletes a row, and it never touches the source file — the gate and groomer keep
# using the file until a later phase cuts them over, and nothing here breaks if
# they append to it meanwhile (a later re-import would pick those up, but this
# task never re-runs once it has succeeded; that is a new task file).
#
# ONE SLICE. The file is ~100 KB and 117 items; there is nothing to checkpoint
# between.
class ImportWorkBacklog < PostDeployTask
  def up
    source = WorkBacklog::Source.resolve
    result = WorkBacklog::Importer.new(source: source, logger: logger).call

    checkpoint!(
      source: source.describe,
      items_seen: result.seen,
      imported: result.imported,
      already_present: result.already_present,
      rejected: result.rejected,
      # The first few, by name, so the health panel says WHICH rather than only
      # how many. The logs carry them all.
      rejections: result.to_h[:rejections].first(20),
      queued_after: WorkBacklogItem.queued.count
    )
    nil
  rescue WorkBacklog::Source::Unavailable => e
    # In production this is a real failure and must be visible as one: the file
    # exists, we could not read it, and the import has not happened. It backs
    # off, then parks `failed` on the health page with the reason, re-armable
    # from a button rather than a shell.
    raise if Rails.env.production?

    # Everywhere else it is the expected outcome. Staging and development have no
    # credential for `tadasant/tadasant-internal` and no backlog worth importing,
    # and a permanently-critical health panel there would only teach people to
    # ignore the panel.
    logger.info("[ImportWorkBacklog] no backlog source available in #{Rails.env}: #{e.message}")
    checkpoint!(skipped_reason: "no backlog source available in #{Rails.env}: #{e.message}")
    nil
  end
end
