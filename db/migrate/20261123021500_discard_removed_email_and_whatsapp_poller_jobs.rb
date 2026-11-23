# frozen_string_literal: true

# Discard the queued rows of the two trigger poller jobs this deploy deletes.
#
# `EmailTriggerPollerJob` and `WhatsappTriggerPollerJob` are gone with the condition types they
# served. Rows the OLD container's cron already wrote may still be in `good_job_jobs`, and the new
# container cannot constantize the class to run one: the bare `NameError` is logged at ERROR, which
# pages. A migration rather than a post-deploy task because it has to run BEFORE the new worker
# claims a row. Same shape, and the same residual window, as DiscardRemovedGithubPollerJobs: a row
# the old container enqueues after this runs and before it stops costs one ERROR, on this deploy.
#
# Only unfinished rows of these two classes. A finished row is history the dashboard still renders.
class DiscardRemovedEmailAndWhatsappPollerJobs < ActiveRecord::Migration[8.1]
  REMOVED_JOB_CLASSES = %w[EmailTriggerPollerJob WhatsappTriggerPollerJob].freeze

  def up
    discarded = discard_unfinished("good_job_jobs")
    # The per-attempt history of the same jobs; there is no foreign key between the two tables.
    discard_unfinished("good_job_executions")

    say "discarded #{discarded} unfinished rows for the removed email and WhatsApp poller jobs"
  end

  # The classes these rows named do not exist, so there is nothing to restore them to.
  def down
    say "nothing to restore: the job classes these rows named do not exist"
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
