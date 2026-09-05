# frozen_string_literal: true

# Whether a GitHub PR can be merged into its base branch *right now*.
#
# Github::MergeConflictEvaluator answers a narrower version of the same question
# inside Github::PrPollPass, feeding the two-poll debounce. This module is the
# other caller — the one that has to ask again at the moment a conflict notice is
# taken off a session's queue, which can be several minutes after the poll that
# wrote it (see EnqueuedMessage#stale?).
#
# The two go through the SAME reader, Github::PrSnapshot, and that is load-bearing
# rather than tidy. This module's answer is what RETIRES a notice the evaluator
# wrote, and the evaluator clears its "confirmed" marker only on a clean reading —
# so a suppression taken on a reading the evaluator would not itself have made is
# a conflict nobody is ever told about. Two readers of two different GitHub APIs
# (GraphQL `mergeable` is MERGEABLE/CONFLICTING/UNKNOWN; REST's is
# true/false/null) is exactly how that divergence gets introduced without anyone
# noticing, so there is one reader and one vocabulary.
#
# `state` comes back on the same reading, because a PR that closed or merged while
# the notice sat in the queue is a *known* reason the notice is moot rather than
# an unknown.
#
# Every answer that is not a definite reading is `:unknown`, and every caller is
# expected to fail *open* on it. A guard that suppressed a notice on a read it
# could not complete would leave a session asleep on a PR that will never merge,
# with nothing in the log saying why — strictly worse than the false alarm the
# guard exists to stop.
module GithubPullRequestMergeability
  # Same shape Github::PrRef matches PR URLs with, tightened to the characters
  # GitHub actually allows in an owner or repo name so a `..` cannot ride into an
  # API path built from the captures.
  PR_URL_PATTERN = %r{github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)}

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

    interpret(fetch_snapshot(owner, repo, pr_number))
  end

  # This pull request as Github::PrSnapshot read it, or nil when the call could not
  # be completed.
  #
  # The ref is built from the captures this module validated rather than by
  # re-parsing the url through Github::PrRef, whose pattern is deliberately the
  # looser one the pollers have always used. Nothing downstream interpolates these
  # into a path any more — `gh pr view --repo owner/repo` passes them as arguments —
  # but the tighter check costs nothing and is one fewer thing to re-derive if that
  # ever changes.
  #
  # The wall-clock bound comes with the reader (Github::PrSnapshot::TIMEOUT), and is
  # the same 20 seconds this module used to set for itself: generous relative to a
  # normal API round trip and short relative to the turn boundary this sits in front
  # of. The point is that a wedged `gh` cannot hold up a session's delivery
  # indefinitely, not that a slow one is treated as a failure.
  def fetch_snapshot(owner, repo, pr_number)
    Github::PrSnapshot.fetch(
      Github::PrRef.new(url: "https://github.com/#{owner}/#{repo}/pull/#{pr_number}",
                        owner: owner, repo: repo, number: pr_number)
    )
  rescue => e
    # Wider than the reader's own rescue, and deliberately so. Github::PrSnapshot
    # answers nil for a call that failed or could not be parsed, but lets a local,
    # permanent condition through — `Errno::ENOENT`, no `gh` binary at all — which
    # GithubCli documents as the one thing it does not convert. The pass can afford
    # that: its per-session rescue logs it and the sweep continues. This runs on a
    # session's DELIVERY path, where an exception escaping would take down the
    # message the guard was only supposed to re-check. Fail open, like every other
    # unreadable answer here.
    Rails.logger.warn "[GithubPullRequestMergeability] read raised for #{owner}/#{repo}##{pr_number}: " \
      "#{e.class}: #{e.message}"
    nil
  end

  # An UNKNOWN mergeability reading is GitHub still computing it, which is common in
  # the seconds after a push. There is nothing to gain by waiting here — an
  # indefinite answer is `:unknown` and the caller delivers.
  #
  # A terminal `state` is checked first because it outranks mergeability: a merged
  # or closed PR reports no mergeability at all, and reading that as "no idea" would
  # throw away the one thing GitHub told us for certain. Only a POSITIVELY terminal
  # status suppresses — a status this could not establish falls through to the
  # mergeability question and, failing that, to `:unknown`.
  def interpret(snapshot)
    return :unknown if snapshot.nil?
    return :not_open if [ "merged", "closed" ].include?(snapshot.status)

    case snapshot.conflicting?
    when false then :mergeable
    when true then :conflicting
    else :unknown
    end
  end

  # Only `read` is the interface. The other two are split out for readability
  # and are stubbed by name in this module's own test, not called from elsewhere.
  private_class_method :fetch_snapshot, :interpret
end
