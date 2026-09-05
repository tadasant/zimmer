# frozen_string_literal: true

# The one cron entry behind Zimmer's GitHub pull request polling.
#
# It replaces GitHubPullRequestPollerJob, GithubCommentPollerJob and
# GitHubMergeConflictPollerJob, which each swept the same sessions and re-derived the
# same facts about the same PRs. Everything it does lives in Github::PrPollPass; this
# class is the schedule, the queue and the singleton lock.
#
# Runs every 30 seconds via GoodJob cron configuration.
class GithubPrPollPassJob < ApplicationJob
  queue_as :pollers

  # Singleton pattern: only allow one instance to run/queue at a time
  # This prevents queue backup when polling takes longer than the cron interval
  good_job_control_concurrency_with(
    key: -> { "github_pr_poll_pass" },
    total_limit: 1
  )

  def perform
    Github::PrPollPass.new.run
  end
end
