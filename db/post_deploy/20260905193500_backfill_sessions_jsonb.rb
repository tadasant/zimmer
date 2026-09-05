# frozen_string_literal: true

# Copies five `sessions` columns into the jsonb shadows that
# `20260905193000_add_jsonb_shadow_columns_to_sessions` added, for every row that
# existed before the dual-write started (#847).
#
# THE POINT OF THIS FILE: the shadow columns arrive empty — `ADD COLUMN` with no
# default is a catalog-only change precisely because it writes no rows — and
# `JsonbDualWrite` only fills a row that something writes afterwards. A session
# nobody has touched since the deploy would still be NULL at PR 2's cutover,
# which is where it would turn into data loss. Historically this was the shape
# that became `rake data:something` and then never ran, because finishing it
# needed a shell on the production box that this deployment does not offer
# (AGENTS.md, "No production box access"). As a post-deploy task it ships with
# the deploy and answers for itself in `post_deploy_task_runs` — on /health, in
# `GET /api/v1/health`, from `get_system_health`, at
# /supervisor/post_deploy_task_runs. **PR 2 must not be merged until this run
# reads `succeeded` there.**
#
# Idempotent by construction: the predicate matches a row only while its shadow
# disagrees with its source, so a copied row drops out of the relation and a
# second run finds nothing.
#
# Sliced, because `sessions` is the largest table in the schema and the work is a
# per-row JSON parse. `sweep` checks its budget between batches, so the last query
# — the one proving nothing is left — is a scan of `sessions` under an unindexed
# predicate. That is seconds at this table's size, and it happens once per
# environment. An index built for a one-time repair would be a bigger thing to
# leave behind than the scan it saves.
class BackfillSessionsJsonb < PostDeployTask
  # Spelled out rather than read from `JsonbDualWrite::COLUMNS`. A task file has
  # to keep loading after the code that motivated it is gone — a fresh
  # environment runs every task in the directory from scratch, and PR 2 deletes
  # that concern — so this one names its own columns, the way a migration does.
  COLUMNS = %w[config mcp_servers mcp_server_env mcp_server_headers metadata].freeze

  # DISAGREES, not "is still NULL". The narrower predicate would fill the shadows
  # that `ADD COLUMN` left empty and nothing more, and it would miss the case a
  # rolling deploy actually produces: kamal-proxy health-gates the cutover, so old
  # containers keep serving while new ones come up, and `web` and `worker` do not
  # cut over at the same instant. A session dual-written by a new container and
  # then merged by a still-old worker — which writes `metadata` and knows nothing
  # about `metadata_jsonb` — ends the window with a shadow that is stale and NOT
  # null. `kamal rollback` produces the same thing wholesale. Those rows heal
  # themselves on their next write through new code, but a session whose last
  # write ever landed in that window does not, and PR 2's read cutover is where a
  # silently stale shadow turns into the data loss this whole change exists to
  # prevent.
  #
  # Still idempotent, and it still terminates: the UPDATE makes the predicate
  # false for every row it touches, and `NULL IS DISTINCT FROM NULL` is false, so
  # a row whose source is genuinely NULL has nothing to copy and is never
  # selected. The cost over the narrower version is one cast per row scanned
  # rather than per row copied.
  #
  # It is NOT a standing guarantee. This task runs once, so divergence introduced
  # after it succeeds is invisible to it — **PR 2 must re-check this predicate
  # against zero immediately before cutting the readers over, rather than
  # trusting this run's `succeeded`.**
  PENDING = COLUMNS
    .map { |name| "(sessions.#{name}_jsonb IS DISTINCT FROM sessions.#{name}::jsonb)" }
    .join(" OR ").freeze

  # Cast from the source rather than from anything this process read, so the copy
  # is atomic per row against a concurrent dual-write: whatever `metadata` holds
  # when this statement touches the row is what `metadata_jsonb` gets.
  ASSIGNMENTS = COLUMNS.map { |name| "#{name}_jsonb = sessions.#{name}::jsonb" }.join(", ").freeze

  def up
    checkpoint!(backfilled: stats.fetch("backfilled", 0))

    # `select(:id)` is load-bearing, not tidiness: a bare `Session` batch would
    # instantiate `transcript`, which SessionContentSearch puts at gigabytes
    # across the table. The sweep only needs the ids, and the copy happens in the
    # database.
    sweep(Session.select(:id).where(PENDING), batch_size: 500) do |batch|
      # `update_all`, so no callbacks, no validations and — the one that matters
      # — no `updated_at` bump. Touching `updated_at` on every session in the
      # table would reorder every list in the UI and mislead every reader of
      # "when did this session last change" for a write that changed nothing
      # anybody can see.
      #
      # `PENDING` is re-applied so the count is rows that actually needed work
      # rather than rows that happened to share a batch.
      copied = Session.where(id: batch.map(&:id)).where(PENDING).update_all(ASSIGNMENTS)
      checkpoint!(backfilled: stats.fetch("backfilled", 0) + copied)
    end
  end
end
