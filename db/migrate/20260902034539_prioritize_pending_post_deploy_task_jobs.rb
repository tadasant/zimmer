# frozen_string_literal: true

# Keep the post-deploy task runner ahead of ordinary default-queue work across
# releases, including when its singleton row was enqueued by an older image.
#
# Active Job copies a job's priority into GoodJob only when the row is enqueued.
# Changing PostDeployTaskJob's class-level priority therefore does not affect an
# unfinished singleton row already in good_jobs, and that row prevents cron from
# enqueueing a replacement. Under a large default backlog, the very runner that
# must migrate the backlog can otherwise wait behind it indefinitely.
class PrioritizePendingPostDeployTaskJobs < ActiveRecord::Migration[8.1]
  RUNNER_PRIORITY = -100

  def up
    result = connection.exec_update(<<~SQL)
      UPDATE good_jobs
      SET priority = #{RUNNER_PRIORITY}, updated_at = NOW()
      WHERE job_class = 'PostDeployTaskJob'
        AND finished_at IS NULL
        AND performed_at IS NULL
        AND locked_by_id IS NULL
        AND (priority IS NULL OR priority > #{RUNNER_PRIORITY})
    SQL

    say "Prioritized #{result} pending post-deploy task runner(s)"
  end

  def down
    result = connection.exec_update(<<~SQL)
      UPDATE good_jobs
      SET priority = 0, updated_at = NOW()
      WHERE job_class = 'PostDeployTaskJob'
        AND finished_at IS NULL
        AND performed_at IS NULL
        AND locked_by_id IS NULL
        AND priority = #{RUNNER_PRIORITY}
    SQL

    say "Restored #{result} pending post-deploy task runner(s) to default priority"
  end
end
