# frozen_string_literal: true

# The three GitHub poller jobs (PR status, comments, merge conflicts) all scan
# `Session.with_github_prs` every cron tick (every 30s for two of them). That
# scope filters on `status NOT IN (archived, failed)` AND a JSONB key existence
# check, then `find_each` appends `ORDER BY id ASC LIMIT`.
#
# The pre-existing JSONB partial index (index_sessions_on_custom_metadata_pr_urls)
# covers thousands of rows — every session that ever had a PR URL, including the
# archived/failed majority — so the planner judged it cheaper to sequentially scan
# the whole `sessions` table and sort by id than to use that index plus heap-check
# `status`. On the production table that seq scan touched ~3000 buffers and ~8500
# rows to return ~10 live sessions, spiking to 1–2.3s under load and tripping the
# [DatabaseSlow]/[DatabaseChoke] alert (issue #4403).
#
# This partial index on `id` whose predicate mirrors `Session.with_github_prs`
# exactly contains only the handful of active-PR sessions, in id order, so the
# `ORDER BY id ASC LIMIT` batch is satisfied from the index alone.
#
# NOTE: the predicate hardcodes the integer enum values for the excluded statuses
# (archived = 3, failed = 4 — see Session#status enum). `where.not(status:)` emits
# `status NOT IN (3, 4)`, which Postgres can prove is implied by this index
# predicate. If those enum integers are ever reordered, update this predicate to
# match (a mismatch only demotes the query to a seq scan — it never returns wrong
# rows). Keep this in sync with the `Session.with_github_prs` scope.
class AddActivePrUrlIdIndexToSessions < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :sessions,
      :id,
      name: "index_sessions_on_pr_url_active_id",
      where: "status NOT IN (3, 4) AND (custom_metadata->>'github_pull_request_urls') IS NOT NULL",
      algorithm: :concurrently
  end
end
