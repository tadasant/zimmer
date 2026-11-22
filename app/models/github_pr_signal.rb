# frozen_string_literal: true

# "Something about this pull request may have changed", as GitHub's webhook said it.
#
# Github::PrWebhookIngest writes these from verified deliveries, and Github::PrPollPass and
# Github::OrphanedPrConflictSweep read them to decide which evaluators are due. A signal
# carries no content from the delivery: it is a time, a subject and a kind, and the evaluator
# it wakes reads the PR from GitHub exactly as a poll would. So a forged or replayed delivery
# can cost an extra read of a PR and nothing else — it cannot tell a session that a PR merged,
# that CI passed or that a human commented.
#
# One row per (subject, kind), holding the NEWEST time it was signalled: a burst of
# `check_run` deliveries for one CI run is one row whose time moves forward, not one row each.
# A reader asks "is the signal newer than my last evaluation", so nothing ever consumes or
# deletes a row; InboundEventRetentionJob prunes the ones nobody has signalled for a day.
#
# Subjects are lower-cased, because GitHub matches owner and repository names without regard
# to case and the two sides — a session's recorded url and a delivery's `full_name` — need not
# agree on casing:
#
#   https://github.com/<owner>/<repo>/pull/<n>   a pull request (PR_KINDS)
#   <owner>/<repo>                               a repository (REPO_KINDS)
class GithubPrSignal < ApplicationRecord
  # A pull request's lifecycle, labels, body or CI may have changed: run PrStatusEvaluator
  # (and GoalFactsEvaluator, which reads the same snapshot).
  STATUS = "status"
  # A comment may have been posted on it: run CommentEvaluator.
  COMMENTS = "comments"
  # Its head or base moved, so its mergeability is worth re-reading: run
  # MergeConflictEvaluator.
  MERGE_CONFLICT = "merge_conflict"
  PR_KINDS = [ STATUS, COMMENTS, MERGE_CONFLICT ].freeze

  # The repository's default branch moved, so any PR in it may now conflict.
  BASE_PUSH = "base_push"
  # A commit status landed somewhere in the repository. A `status` delivery names a commit,
  # not a pull request, so every tracked PR in the repository re-reads its CI.
  CI = "ci"
  # The repository's webhook delivered something — anything. The liveness reading that makes a
  # repository webhook-covered; see Github::PrWebhookIngest.covered_repos.
  DELIVERY = "delivery"
  REPO_KINDS = [ BASE_PUSH, CI, DELIVERY ].freeze

  KINDS = (PR_KINDS + REPO_KINDS).freeze

  RETENTION = 1.day

  validates :subject, presence: true
  validates :kind, inclusion: { in: KINDS }

  scope :expired, ->(now = Time.current) { where(signaled_at: ...(now - RETENTION)) }

  # @return [String] the subject a pull request's signals are filed under
  def self.pr_subject(owner, repo, number)
    "https://github.com/#{owner}/#{repo}/pull/#{number}".downcase
  end

  # @return [String] the subject a repository's signals are filed under
  def self.repo_subject(owner, repo)
    "#{owner}/#{repo}".downcase
  end

  # Record one or more signals at +at+, keeping the newer time where a row already exists.
  #
  # @param signals [Array<Array(String, String)>] [subject, kind] pairs
  # @return [void]
  def self.signal!(signals, at: Time.current)
    rows = signals.uniq.map { |subject, kind| { subject: subject.to_s.downcase, kind: kind, signaled_at: at } }
    return if rows.empty?

    upsert_all(
      rows,
      unique_by: %i[subject kind],
      on_duplicate: Arel.sql("signaled_at = GREATEST(github_pr_signals.signaled_at, EXCLUDED.signaled_at)")
    )
  end

  # The signals filed under +subjects+, as { [subject, kind] => signaled_at }.
  def self.latest_for(subjects)
    where(subject: subjects.map(&:downcase).uniq).pluck(:subject, :kind, :signaled_at)
      .to_h { |subject, kind, at| [ [ subject, kind ], at ] }
  end
end
