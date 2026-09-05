# frozen_string_literal: true

require "json"

# Whether a GitHub PR can be merged into its base branch *right now*.
#
# GitHubMergeConflictPollerJob answers a narrower version of the same question
# on its own cron tick, and keeps its own copy of the read: it wraps the call in
# a null-retry loop, feeds the two-poll debounce, and its private methods are
# what its tests stub. This module is the other caller — the one that has to ask
# again at the moment a conflict notice is taken off a session's queue, which can
# be several minutes after the poll that wrote it (see EnqueuedMessage#stale?).
# It reads the same `mergeable` field so the two cannot disagree about what
# "conflicting" means, plus `state`, because a PR that closed or merged while the
# notice sat in the queue is a *known* reason the notice is moot rather than an
# unknown.
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
  # @return [Symbol] one of:
  #   :mergeable  — GitHub says this PR merges cleanly
  #   :conflicting — GitHub says it does not
  #   :not_open   — merged or closed, so mergeability no longer means anything
  #   :unknown    — no reading could be taken; callers must fail open
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

    interpret(fetch_pull_request(owner, repo, pr_number), "#{owner}/#{repo}##{pr_number}")
  end

  # The PR's `state` and `mergeable` as a hash with string keys, or nil when the
  # call could not be completed.
  #
  # Goes through GithubCli, like every other `gh` invocation in Zimmer, so this
  # read — the one that runs on a session's delivery path rather than a poller's
  # own tick — cannot wedge.
  def fetch_pull_request(owner, repo, pr_number)
    command = [
      "gh", "api",
      "repos/#{owner}/#{repo}/pulls/#{pr_number}",
      "--jq", "{state: .state, mergeable: .mergeable}"
    ]

    result = GithubCli.run(command, timeout: READ_TIMEOUT_SECONDS)

    # Anything short of a demonstrable exit 0 — a non-zero exit, an exit code lost
    # to a reap, a call that hung until its deadline — means no reading. nil says
    # that, and every caller fails open on it.
    unless result.success?
      Rails.logger.warn "[GithubPullRequestMergeability] gh api failed for #{owner}/#{repo}##{pr_number}: " \
        "#{result.failure_description}"
      return nil
    end

    parsed = JSON.parse(result.stdout.to_s)
    parsed.is_a?(Hash) ? parsed : nil
  rescue => e
    Rails.logger.warn "[GithubPullRequestMergeability] gh api raised for #{owner}/#{repo}##{pr_number}: " \
      "#{e.class}: #{e.message}"
    nil
  end

  # `mergeable: null` is GitHub still computing mergeability, which is common in
  # the seconds after a push. The poller retries through it because it is about
  # to write a debounce marker either way; here there is nothing to gain by
  # waiting — an indefinite answer is `:unknown` and the caller delivers.
  #
  # `state` is checked first because it outranks mergeability: a merged or closed
  # PR reports `mergeable: null`, and reading that as "no idea" would throw away
  # the one thing GitHub told us for certain.
  def interpret(payload, subject)
    return :unknown if payload.nil?

    state = payload["state"]
    return :not_open if state.is_a?(String) && state != "open"

    case payload["mergeable"]
    when true then :mergeable
    when false then :conflicting
    when nil then :unknown
    else
      Rails.logger.warn "[GithubPullRequestMergeability] Unexpected mergeable value " \
        "#{payload['mergeable'].inspect} for #{subject}"
      :unknown
    end
  end

  # Only `read` is the interface. The other two are split out for readability
  # and are stubbed by name in this module's own test, not called from elsewhere.
  private_class_method :fetch_pull_request, :interpret
end
