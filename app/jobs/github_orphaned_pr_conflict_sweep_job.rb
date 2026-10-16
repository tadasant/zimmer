# frozen_string_literal: true

# The cron entry behind Github::OrphanedPrConflictSweep: conflict watching for open
# PRs whose producing session has archived or failed. Everything it does lives in
# the sweep; this class is the schedule, the queue and the singleton lock.
#
# A separate job rather than a step in GithubPrPollPassJob because a revival
# re-clones a repository, and that must not hold up the 30-second pass the merged
# notices ride on.
class GithubOrphanedPrConflictSweepJob < ApplicationJob
  queue_as :pollers

  good_job_control_concurrency_with(
    key: -> { "github_orphaned_pr_conflict_sweep" },
    total_limit: 1
  )

  def perform
    Github::OrphanedPrConflictSweep.new.run
  end
end
