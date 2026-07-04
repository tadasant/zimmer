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
class GitHubPullRequestPollerJob < ApplicationJob
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
    updated_statuses = current_statuses.dup
    updated_ci_statuses = current_ci_statuses.dup

    pr_urls.each do |pr_url|
      # Extract owner, repo, and PR number from URL
      # Format: https://github.com/owner/repo/pull/123
      match = pr_url.match(%r{github\.com/([^/]+)/([^/]+)/pull/(\d+)})
      next unless match

      owner, repo, pr_number = match.captures

      # Use gh CLI to get PR status (requires gh to be installed and authenticated)
      status = fetch_pr_status(owner, repo, pr_number)
      next unless status.present?

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

    # Check if anything changed
    statuses_changed = updated_statuses != current_statuses
    ci_statuses_changed = updated_ci_statuses != current_ci_statuses

    return unless statuses_changed || ci_statuses_changed

    # Build updates
    updates = {}
    updates["github_pull_request_statuses"] = updated_statuses if statuses_changed
    updates["github_pull_request_ci_statuses"] = updated_ci_statuses if ci_statuses_changed

    # Update the statuses
    session.update!(
      custom_metadata: (session.custom_metadata || {}).merge(updates)
    )

    Rails.logger.info "[GitHubPullRequestPollerJob] Updated PR statuses for session #{session.id}: #{updated_statuses}" if statuses_changed
    Rails.logger.info "[GitHubPullRequestPollerJob] Updated CI statuses for session #{session.id}: #{updated_ci_statuses}" if ci_statuses_changed
  end

  def fetch_pr_status(owner, repo, pr_number)
    # Use gh CLI to get PR status in JSON format
    # Note: The field is "mergedAt" (timestamp or null), not "merged" (boolean)
    command = [ "gh", "pr", "view", pr_number.to_s, "--repo", "#{owner}/#{repo}", "--json", "state,mergedAt" ]

    stdout, stderr, status = Open3.capture3(*command)

    unless status.success?
      Rails.logger.warn "[GitHubPullRequestPollerJob] gh command failed: #{stderr}"
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

    # Exit code 8 means checks are pending (not an error)
    unless status.success? || status.exitstatus == 8
      Rails.logger.warn "[GitHubPullRequestPollerJob] gh pr checks command failed: #{stderr}"
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
