# The index behind `HealthMonitorService#job_error_records`, which reads the most
# recent background-job failures for `/health`'s Recent Errors panel.
#
# Without it that read is a sequential scan of `good_jobs` plus a top-N sort:
# GoodJob preserves finished rows for fourteen days by default and Zimmer's cron
# enqueues into the fast lanes every thirty seconds, so the table holds order-10^5
# rows, and `/health` re-reads it every thirty seconds while a tab is open.
#
# Partial on `error IS NOT NULL` because that is a small minority of the table —
# the index stays tiny — and it is the only population this query, and the
# `failed_count` beside it, ever look at.
class AddErrorRecencyIndexToGoodJobs < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :good_jobs, :updated_at,
              where: "error IS NOT NULL",
              name: "index_good_jobs_on_updated_at_when_errored",
              algorithm: :concurrently,
              if_not_exists: true
  end
end
