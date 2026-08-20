require "open3"

# Job that polls GitHub PR status for running sessions with associated PRs
# Runs every 30 seconds via GoodJob cron configuration
#
# Updates the github_pull_request_statuses field in custom_metadata as a hash:
# { "https://github.com/owner/repo/pull/123" => "open", ... }
#
# Status values:
# - "open" - PR is open
# - "merged" - PR has been merged
# - "closed" - PR was closed without merging
#
# Also updates github_pull_request_ci_statuses for open PRs:
# { "https://github.com/owner/repo/pull/123" => "pending", ... }
#
# CI status values:
# - "pass" - All CI checks passed
# - "fail" - One or more CI checks failed
# - "pending" - CI checks still running
# - "skipping" - CI checks skipped
# - "cancel" - CI checks cancelled
# - nil - No CI checks or status unknown
#
# When a PR goes from "open" to "merged" the session is told, once, via
# AutomatedPrompts.pr_merged_message — the merge is either the end of the
# session's work or the event it was parked waiting for, and it is the only one
# that can tell which. PRs already merged the first time this job sees them are
# not announced: a session that recorded a PR URL which was merged before the
# first poll never did the work in question, and waking it would be noise.
# github_pull_request_merged_notified records which PRs have been announced.
#
class GitHubPullRequestPollerJob < ApplicationJob
  include DatabaseRetry
  include AutomatedSessionMessage

  queue_as :pollers

  # Singleton pattern: only allow one instance to run/queue at a time
  # This prevents queue backup when polling takes longer than the cron interval
  good_job_control_concurrency_with(
    key: -> { "github_pr_poller" },
    total_limit: 1
  )

  # Per-session backoff key + base cadence; see PollBackoff for the curve.
  POLL_BACKOFF_KEY = "github_pr_poller".freeze
  BASE_POLL_INTERVAL_SECONDS = 30

  def perform
    Session.with_github_prs.find_each do |session|
      unless PollBackoff.should_poll?(session, job_key: POLL_BACKOFF_KEY, base_interval: BASE_POLL_INTERVAL_SECONDS)
        Rails.logger.info "[GitHubPullRequestPollerJob] Skipping session #{session.id} (PollBackoff: stale user activity)"
        next
      end

      poll_pr_statuses(session)
      PollBackoff.record_poll!(session, job_key: POLL_BACKOFF_KEY)
    rescue => e
      Rails.logger.error "[GitHubPullRequestPollerJob] Error polling PRs for session #{session.id}: #{e.message}"
    end
  end

  private

  def poll_pr_statuses(session)
    pr_urls = session.custom_metadata&.dig("github_pull_request_urls")
    return unless pr_urls.is_a?(Array) && pr_urls.present?

    current_statuses = session.custom_metadata&.dig("github_pull_request_statuses") || {}
    current_ci_statuses = session.custom_metadata&.dig("github_pull_request_ci_statuses") || {}
    current_merged_notified = session.custom_metadata&.dig("github_pull_request_merged_notified") || {}
    updated_statuses = current_statuses.dup
    updated_ci_statuses = current_ci_statuses.dup
    updated_merged_notified = current_merged_notified.dup
    newly_merged_prs = []

    pr_urls.each do |pr_url|
      # Extract owner, repo, and PR number from URL
      # Format: https://github.com/owner/repo/pull/123
      match = pr_url.match(%r{github\.com/([^/]+)/([^/]+)/pull/(\d+)})
      next unless match

      owner, repo, pr_number = match.captures

      # Use gh CLI to get PR status (requires gh to be installed and authenticated)
      status = fetch_pr_status(owner, repo, pr_number)
      next unless status.present?

      # Only the open → merged transition is announced, and only once. No debounce:
      # unlike the merge conflict poller's mergeable field, `mergedAt` has no
      # transient-false failure mode — a PR with a merge timestamp is merged, and
      # stays merged.
      if status == "merged" && current_statuses[pr_url] == "open" && !current_merged_notified[pr_url]
        newly_merged_prs << pr_url
      end

      updated_statuses[pr_url] = status

      # Fetch CI status only for open PRs
      if status == "open"
        ci_status = fetch_ci_status(owner, repo, pr_number)
        if ci_status.present?
          updated_ci_statuses[pr_url] = ci_status
        else
          # Clear CI status if not available (e.g., no checks configured)
          updated_ci_statuses.delete(pr_url)
        end
      else
        # Clear CI status for closed/merged PRs
        updated_ci_statuses.delete(pr_url)
      end
    end

    # Deliver the merged-PR messages BEFORE the markers below are persisted. A crash
    # in between then costs at most one duplicate message on the next poll, where the
    # other order would drop the notification silently and forever. A delivery that
    # fails and is swallowed is a different case: the status write below advances past
    # the transition, so that message is not retried — see docs/limitations.
    notify_merged_prs(session, newly_merged_prs).each do |pr_url|
      updated_merged_notified[pr_url] = true
    end

    # Check if anything changed
    statuses_changed = updated_statuses != current_statuses
    ci_statuses_changed = updated_ci_statuses != current_ci_statuses
    merged_notified_changed = updated_merged_notified != current_merged_notified

    return unless statuses_changed || ci_statuses_changed || merged_notified_changed

    # Build updates
    updates = {}
    updates["github_pull_request_statuses"] = updated_statuses if statuses_changed
    updates["github_pull_request_ci_statuses"] = updated_ci_statuses if ci_statuses_changed
    updates["github_pull_request_merged_notified"] = updated_merged_notified if merged_notified_changed

    # Update the statuses. A poll cycle spans several seconds of GitHub API calls, so
    # the session row this job read at the start is stale by now — a whole-column write
    # here would erase whatever the session's own worker recorded in the meantime,
    # `github_pull_request_urls` included.
    with_db_retry { session.merge_custom_metadata!(updates) }

    Rails.logger.info "[GitHubPullRequestPollerJob] Updated PR statuses for session #{session.id}: #{updated_statuses}" if statuses_changed
    Rails.logger.info "[GitHubPullRequestPollerJob] Updated CI statuses for session #{session.id}: #{updated_ci_statuses}" if ci_statuses_changed
  end

  # Tell the session about each PR that just merged.
  #
  # Delivery goes through AutomatedSessionMessage, the same path the merge conflict
  # poller uses: immediate when the session is parked in needs_input, queued behind
  # the current turn when it is running or waiting.
  #
  # @return [Array<String>] the PR urls a message was delivered for — the caller
  #   marks exactly these as notified, so a session skipped here, or one whose
  #   delivery failed, is never recorded as having been told.
  def notify_merged_prs(session, pr_urls)
    return [] if pr_urls.empty?

    # `with_github_prs` already excludes archived and failed sessions, but a session
    # can reach either state during the seconds this poll spends talking to GitHub.
    # There is nothing for it to decide at that point, so say nothing. The reload is
    # what makes that check real: the row was read before the GitHub calls and nothing
    # since has refreshed it, so the in-memory status is the one from the top of the
    # sweep. Reloading here is safe — every hash this method's caller is about to write
    # was dup'd before the first GitHub call, and the write itself merges in Postgres.
    session.reload

    if session.archived? || session.failed?
      Rails.logger.info "[GitHubPullRequestPollerJob] Skipping merged-PR message for #{session.status} session #{session.id}: #{pr_urls.join(', ')}"
      return []
    end

    pr_urls.select do |pr_url|
      deliver_automated_message(
        session,
        AutomatedPrompts.pr_merged_message(pr_url),
        event_description: "PR merged: #{pr_url}",
        origin: "automated_pr_merged"
      )
    end
  end

  def fetch_pr_status(owner, repo, pr_number)
    # Use gh CLI to get PR status in JSON format
    # Note: The field is "mergedAt" (timestamp or null), not "merged" (boolean)
    command = [ "gh", "pr", "view", pr_number.to_s, "--repo", "#{owner}/#{repo}", "--json", "state,mergedAt" ]

    stdout, stderr, status = Open3.capture3(*command)

    # A nil status (this `gh` child reaped by ZombieReaperJob before capture3's waiter
    # got to it) is a failed call, not a successful one — see SubprocessStatus.
    unless SubprocessStatus.success?(status)
      Rails.logger.warn "[GitHubPullRequestPollerJob] gh command failed: #{SubprocessStatus.describe_failure(status, stderr)}"
      return nil
    end

    data = JSON.parse(stdout)
    state = data["state"]&.downcase
    merged_at = data["mergedAt"]

    # Map GitHub state to our status
    # mergedAt is a timestamp string when merged, nil otherwise
    if merged_at.present?
      "merged"
    elsif state == "open"
      "open"
    elsif state == "closed"
      "closed"
    else
      nil
    end
  rescue JSON::ParserError => e
    Rails.logger.error "[GitHubPullRequestPollerJob] Failed to parse gh output: #{e.message}"
    nil
  end

  # Fetch CI check status for a PR
  # Returns the overall CI status: "pass", "fail", "pending", "skipping", "cancel", or nil
  def fetch_ci_status(owner, repo, pr_number)
    # Use gh CLI to get CI checks status in JSON format
    # The bucket field categorizes state into: pass, fail, pending, skipping, cancel
    command = [ "gh", "pr", "checks", pr_number.to_s, "--repo", "#{owner}/#{repo}", "--json", "bucket,state" ]

    stdout, stderr, status = Open3.capture3(*command)

    # Exit code 8 means checks are pending (not an error). A nil status has no exit code
    # to compare, so it correctly falls through to the failure branch rather than raising.
    unless SubprocessStatus.success?(status) || SubprocessStatus.exit_code(status) == 8
      Rails.logger.warn "[GitHubPullRequestPollerJob] gh pr checks command failed: #{SubprocessStatus.describe_failure(status, stderr)}"
      return nil
    end

    checks = JSON.parse(stdout)

    # If no checks exist, return nil
    return nil if checks.empty?

    # Determine overall CI status based on bucket field
    # Priority: fail > pending > cancel > skipping > pass
    buckets = checks.map { |check| check["bucket"] }

    if buckets.include?("fail")
      "fail"
    elsif buckets.include?("pending")
      "pending"
    elsif buckets.include?("cancel")
      "cancel"
    elsif buckets.include?("skipping")
      # If all checks are skipping, show skipping; otherwise show pass
      buckets.all? { |b| b == "skipping" } ? "skipping" : "pass"
    elsif buckets.include?("pass")
      "pass"
    else
      nil
    end
  rescue JSON::ParserError => e
    Rails.logger.error "[GitHubPullRequestPollerJob] Failed to parse gh pr checks output: #{e.message}"
    nil
  end
end
