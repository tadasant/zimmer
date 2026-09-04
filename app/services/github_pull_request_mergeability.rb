# frozen_string_literal: true

# Whether a GitHub PR can be merged into its base branch *right now*.
#
# GitHubMergeConflictPollerJob answers the same question on its own cron tick,
# and keeps its own copy of the read: it wraps the call in a null-retry loop,
# feeds the two-poll debounce, and its private methods are what its tests stub.
# This module is the other caller — the one that has to ask again at the moment
# a conflict notice is taken off a session's queue, which can be several minutes
# after the poll that wrote it (see EnqueuedMessage#stale?). It reads the same
# `mergeable` field so the two cannot disagree about what "conflicting" means.
#
# Every answer that is not a definite reading is `:unknown`, and every caller is
# expected to fail *open* on it. A guard that suppressed a notice on a read it
# could not complete would leave a session asleep on a PR that will never merge,
# with nothing in the log saying why — strictly worse than the false alarm the
# guard exists to stop.
module GithubPullRequestMergeability
  # Same shape the poller matches PR URLs with, tightened to the characters
  # GitHub actually allows in an owner or repo name so a `..` cannot ride into
  # the API path below.
  PR_URL_PATTERN = %r{github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)}

  # Wall-clock bound on the `gh` child, process group killed on deadline.
  # Generous relative to a normal API round trip and short relative to the turn
  # boundary this sits in front of: the point is that a wedged `gh` cannot hold
  # up a session's delivery indefinitely, not that a slow one is treated as a
  # failure.
  READ_TIMEOUT_SECONDS = 20

  module_function

  # @param pr_url [String] full PR URL, e.g. "https://github.com/owner/repo/pull/1"
  # @return [Symbol] :mergeable, :conflicting, or :unknown
  def read(pr_url)
    match = PR_URL_PATTERN.match(pr_url.to_s)
    unless match
      Rails.logger.warn "[GithubPullRequestMergeability] Not a PR URL: #{pr_url.inspect}"
      return :unknown
    end

    owner, repo, pr_number = match.captures
    if owner.include?("..") || repo.include?("..")
      Rails.logger.warn "[GithubPullRequestMergeability] Refusing traversal-shaped repo path in #{pr_url.inspect}"
      return :unknown
    end

    interpret(fetch_mergeable_field(owner, repo, pr_number), "#{owner}/#{repo}##{pr_number}")
  end

  # Raw `mergeable` value as a string ("true" / "false" / "null"), or nil when
  # the call could not be completed.
  #
  # Goes through BoundedSubprocess rather than a bare Open3 so this read — the
  # one that runs on a session's delivery path rather than a poller's own tick —
  # cannot wedge. See tadasant/zimmer#458 for the pollers' own bare calls.
  def fetch_mergeable_field(owner, repo, pr_number)
    command = [
      "gh", "api",
      "repos/#{owner}/#{repo}/pulls/#{pr_number}",
      "--jq", ".mergeable"
    ]

    stdout, stderr, status = BoundedSubprocess.run(command, timeout: READ_TIMEOUT_SECONDS)

    # A nil status (this `gh` child reaped by ZombieReaperJob before the waiter
    # got to it) is a failed call, not a successful one — see SubprocessStatus.
    unless SubprocessStatus.success?(status)
      Rails.logger.warn "[GithubPullRequestMergeability] gh api failed for #{owner}/#{repo}##{pr_number}: " \
        "#{SubprocessStatus.describe_failure(status, stderr)}"
      return nil
    end

    stdout.strip
  rescue BoundedSubprocess::TimeoutError => e
    Rails.logger.warn "[GithubPullRequestMergeability] #{e.message}"
    nil
  rescue => e
    Rails.logger.warn "[GithubPullRequestMergeability] gh api raised for #{owner}/#{repo}##{pr_number}: " \
      "#{e.class}: #{e.message}"
    nil
  end

  # `null` is GitHub still computing mergeability, which is common in the
  # seconds after a push. The poller retries through it because it is about to
  # write a debounce marker either way; here there is nothing to gain by
  # waiting — an indefinite answer is `:unknown` and the caller delivers.
  def interpret(raw, subject)
    case raw
    when "true" then :mergeable
    when "false" then :conflicting
    when "null", nil then :unknown
    else
      Rails.logger.warn "[GithubPullRequestMergeability] Unexpected mergeable value #{raw.inspect} for #{subject}"
      :unknown
    end
  end
end
