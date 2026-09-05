# frozen_string_literal: true

# Discard the queued rows of the three GitHub poller jobs this deploy deletes.
#
# `GitHubPullRequestPollerJob`, `GithubCommentPollerJob` and
# `GitHubMergeConflictPollerJob` are gone, fused into `GithubPrPollPassJob` (#711).
# Their cron entries went with them, so nothing enqueues them again — but rows the
# OLD container's cron already wrote are still in `good_job_jobs`, and the new
# container cannot constantize the class to run one. `ActiveJob::Base.execute`
# raises a bare `NameError`, which reaches `GoodJob.on_thread_error` and is logged
# at ERROR — and per the note on `ApplicationJob`, any Zimmer ERROR trips a critical
# Grafana rule. That is the shape that paged `#alerts` when
# `sessions.blocked_by_session_id` was dropped in one phase (#482).
#
# A migration rather than a post-deploy task on purpose: this has to run BEFORE the
# new worker starts claiming rows, and a post-deploy task runs minutes after it. It
# is pure SQL and needs no application code, which is what makes that possible.
#
# The three are `total_limit: 1` singletons, so there are at most three rows, and in
# practice usually zero — cron enqueues and the same process picks the row up within
# a second. The residual window this does NOT close is a row the old container
# enqueues after this runs and before it stops; that costs one discarded-job ERROR,
# once, on this deploy only.
#
# Deliberately narrow: only rows that never finished, and only these three classes.
# A finished row is history the dashboard still renders.
class DiscardRemovedGithubPollerJobs < ActiveRecord::Migration[8.1]
  REMOVED_JOB_CLASSES = %w[
    GitHubPullRequestPollerJob
    GithubCommentPollerJob
    GitHubMergeConflictPollerJob
  ].freeze

  def up
    discarded = discard_unfinished("good_job_jobs")
    # The per-attempt history of the same jobs. There is no foreign key between the
    # two tables, so a job row deleted above would otherwise leave these behind.
    discard_unfinished("good_job_executions")

    say "discarded #{discarded} unfinished rows for the removed GitHub poller jobs"
  end

  # Irreversible in the only sense that matters: these rows named a class that no
  # longer exists, so there is nothing a down migration could restore them to.
  def down
    say "nothing to restore: the job classes these rows named no longer exist"
  end

  private

  def discard_unfinished(table)
    return 0 unless table_exists?(table)

    connection.delete(<<~SQL.squish)
      DELETE FROM #{connection.quote_table_name(table)}
      WHERE finished_at IS NULL
        AND job_class IN (#{REMOVED_JOB_CLASSES.map { |k| connection.quote(k) }.join(', ')})
    SQL
  end
end
