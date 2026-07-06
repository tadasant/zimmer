require "open3"

# Job that polls GitHub PRs for merge conflicts on sessions with associated PRs
# Runs every 2 minutes via GoodJob cron configuration
#
# Tracks merge conflict status in custom_metadata across two keys:
#   github_pull_request_merge_conflicts           => confirmed (already notified)
#   github_pull_request_merge_conflicts_suspected => seen conflicting on the
#                                                    most recent poll only
# Both are hashes of { "https://github.com/owner/repo/pull/123" => true, ... }.
#
# Two-poll confirmation (debounce): a PR must read mergeable == false on TWO
# CONSECUTIVE polls before we notify the session. The first conflicting read
# only marks the PR "suspected"; the second promotes it to "confirmed" and
# enqueues the automated resolve-conflicts message. Any clean read clears both
# markers.
#
# This filters GitHub's stale/transient mergeable == false readings, which are
# common in the seconds-to-minute after a push or force-push while GitHub
# recomputes mergeability — without debounce, a single stale false enqueues a
# "resolve merge conflicts" nudge against a PR that is actually clean, burning
# the session's turn (see sessions 7235 and 3889 / PR #4064). The cost is up to
# one extra poll interval (~2 min) of latency before a genuine, persistent
# conflict is reported.
#
# Uses the GitHub REST API (gh api) to check PR mergeability, which is more
# reliable than the GraphQL mergeable field for conflict detection.
#
class GitHubMergeConflictPollerJob < ApplicationJob
  include DatabaseRetry

  queue_as :pollers

  # Singleton pattern: only allow one instance to run/queue at a time
  # This prevents queue backup when polling takes longer than the cron interval
  good_job_control_concurrency_with(
    key: -> { "github_merge_conflict_poller" },
    total_limit: 1
  )

  # Per-session backoff key + base cadence; see PollBackoff for the curve.
  POLL_BACKOFF_KEY = "github_merge_conflict_poller".freeze
  BASE_POLL_INTERVAL_SECONDS = 120

  def perform
    Session.with_github_prs.find_each do |session|
      unless PollBackoff.should_poll?(session, job_key: POLL_BACKOFF_KEY, base_interval: BASE_POLL_INTERVAL_SECONDS)
        Rails.logger.info "[GitHubMergeConflictPollerJob] Skipping session #{session.id} (PollBackoff: stale user activity)"
        next
      end

      poll_merge_conflicts(session)
      PollBackoff.record_poll!(session, job_key: POLL_BACKOFF_KEY)
    rescue => e
      Rails.logger.error "[GitHubMergeConflictPollerJob] Error polling merge conflicts for session #{session.id}: #{e.message}"
    end
  end

  private

  def poll_merge_conflicts(session)
    pr_urls = session.custom_metadata&.dig("github_pull_request_urls")
    return unless pr_urls.is_a?(Array) && pr_urls.present?

    # Only check open PRs — skip merged/closed PRs since they can't have actionable conflicts
    pr_statuses = session.custom_metadata&.dig("github_pull_request_statuses") || {}
    current_conflicts = session.custom_metadata&.dig("github_pull_request_merge_conflicts") || {}
    current_suspected = session.custom_metadata&.dig("github_pull_request_merge_conflicts_suspected") || {}
    updated_conflicts = current_conflicts.dup
    updated_suspected = current_suspected.dup
    newly_conflicting_prs = []

    pr_urls.each do |pr_url|
      match = pr_url.match(%r{github\.com/([^/]+)/([^/]+)/pull/(\d+)})
      next unless match

      owner, repo, pr_number = match.captures

      # Only check open PRs
      pr_status = pr_statuses[pr_url]
      unless pr_status == "open"
        # Clear conflict status for non-open PRs
        updated_conflicts.delete(pr_url)
        updated_suspected.delete(pr_url)
        next
      end

      has_conflict = fetch_merge_conflict_status(owner, repo, pr_number)

      # nil means we couldn't determine status — skip this PR
      next if has_conflict.nil?

      if has_conflict
        if updated_conflicts[pr_url] == true
          # Already confirmed + notified — nothing to do.
        elsif current_suspected[pr_url] == true
          # Conflict seen on the previous poll AND still present now — confirm it
          # and notify. Two consecutive readings rule out GitHub's stale/transient
          # mergeable == false (e.g. right after a push, before recomputation).
          updated_conflicts[pr_url] = true
          updated_suspected.delete(pr_url)
          newly_conflicting_prs << pr_url
        else
          # First conflicting reading — suspect only, do NOT notify yet. If the
          # next poll still reads conflicting it gets confirmed above; if it reads
          # clean (the transient/stale case) the marker is cleared below.
          updated_suspected[pr_url] = true
        end
      else
        # PR is clean — clear both the confirmed and suspected markers.
        updated_conflicts.delete(pr_url)
        updated_suspected.delete(pr_url)
      end
    end

    # Enqueue automated messages for newly conflicting PRs BEFORE updating metadata.
    # This ensures at-least-once delivery: if the job crashes after sending but before
    # recording the conflict, the suspected marker persists and the next poll will
    # re-confirm and re-notify (better than never notifying).
    newly_conflicting_prs.each do |pr_url|
      enqueue_merge_conflict_message(session, pr_url)
    end

    # Update metadata only for the keys that actually changed, so unchanged polls
    # don't touch the record (and don't pollute it with empty marker hashes).
    metadata_updates = {}
    metadata_updates["github_pull_request_merge_conflicts"] = updated_conflicts if updated_conflicts != current_conflicts
    metadata_updates["github_pull_request_merge_conflicts_suspected"] = updated_suspected if updated_suspected != current_suspected

    if metadata_updates.any?
      with_db_retry do
        # Reload to minimize stale-read window (other pollers may have updated custom_metadata)
        session.reload
        session.update!(
          custom_metadata: (session.custom_metadata || {}).merge(metadata_updates)
        )
      end
      Rails.logger.info "[GitHubMergeConflictPollerJob] Updated merge conflict statuses for session #{session.id}: confirmed=#{updated_conflicts} suspected=#{updated_suspected}"
    end
  end

  NULL_RETRY_DELAY = 5 # seconds between retries when GitHub returns null
  NULL_MAX_RETRIES = 3 # max retries before giving up on null response

  # Check if a PR has merge conflicts via the GitHub REST API.
  # Retries when GitHub returns null (still computing mergeability).
  #
  # Returns:
  # - true if the PR has merge conflicts (mergeable == false)
  # - false if the PR is mergeable (mergeable == true)
  # - nil if the status cannot be determined after retries
  def fetch_merge_conflict_status(owner, repo, pr_number)
    (NULL_MAX_RETRIES + 1).times do |attempt|
      result = fetch_mergeable_field(owner, repo, pr_number)

      case result
      when "true"
        return false
      when "false"
        return true
      when nil
        return nil
      when "null"
        if attempt < NULL_MAX_RETRIES
          Rails.logger.info "[GitHubMergeConflictPollerJob] GitHub returned null mergeability for #{owner}/#{repo}##{pr_number}, retrying (#{attempt + 1}/#{NULL_MAX_RETRIES})"
          sleep NULL_RETRY_DELAY
        else
          Rails.logger.warn "[GitHubMergeConflictPollerJob] GitHub returned null mergeability for #{owner}/#{repo}##{pr_number} after #{NULL_MAX_RETRIES} retries, skipping"
          return nil
        end
      else
        Rails.logger.warn "[GitHubMergeConflictPollerJob] Unexpected mergeable value '#{result}' for #{owner}/#{repo}##{pr_number}"
        return nil
      end
    end
  end

  # Fetches the raw mergeable field from the GitHub API.
  # Returns "true", "false", "null", or nil on API error.
  def fetch_mergeable_field(owner, repo, pr_number)
    # Note: owner/repo are extracted via regex from validated PR URLs (github.com/[^/]+/[^/]+/pull/\d+)
    # which prevents path injection. pr_number is validated as digits only.
    command = [
      "gh", "api",
      "repos/#{owner}/#{repo}/pulls/#{pr_number}",
      "--jq", ".mergeable"
    ]

    stdout, stderr, status = Open3.capture3(*command)

    unless status.success?
      Rails.logger.warn "[GitHubMergeConflictPollerJob] gh api command failed for #{owner}/#{repo}##{pr_number}: #{stderr}"
      return nil
    end

    stdout.strip
  end

  def enqueue_merge_conflict_message(session, pr_url)
    prompt = AutomatedPrompts.merge_conflict_message(pr_url)

    with_db_retry do
      ActiveRecord::Base.transaction do
        session.lock!

        if session.needs_input?
          send_prompt_immediately(session, prompt, pr_url)
        else
          enqueue_prompt_for_later(session, prompt, pr_url)
        end
      end
    end
  rescue => e
    Rails.logger.error "[GitHubMergeConflictPollerJob] Failed to enqueue merge conflict message for session #{session.id}, PR #{pr_url}: #{e.message}"
  end

  # Send prompt directly to the session, transitioning it to running
  # Used when session is in needs_input state
  def send_prompt_immediately(session, prompt, pr_url)
    # Reset SIGTERM retry state for fresh execution
    if session.metadata&.dig("sigterm_retry_count").present?
      session.update!(
        metadata: (session.metadata || {}).except(
          "sigterm_retry_count",
          "sigterm_retry_timestamps",
          "last_sigterm_at"
        )
      )
    end

    session.resume! if session.may_resume?

    session.logs.create!(
      content: "Merge conflict detected on #{pr_url} — automated message sent immediately",
      level: "info"
    )

    session.update!(
      metadata: (session.metadata || {}).merge("pending_follow_up_prompt" => prompt)
    )

    AgentSessionJob.enqueue_with_prompt(session.id, prompt)

    Rails.logger.info "[GitHubMergeConflictPollerJob] Sent immediate merge conflict message for session #{session.id}, PR #{pr_url}"
  end

  # Queue prompt as an enqueued message for later processing
  # Used when session is running or waiting
  def enqueue_prompt_for_later(session, prompt, pr_url)
    max_position = session.enqueued_messages.maximum(:position) || 0
    next_position = max_position + 1

    session.enqueued_messages.create!(
      content: prompt,
      position: next_position,
      status: "pending"
    )

    session.logs.create!(
      content: "Merge conflict detected on #{pr_url} — automated message enqueued",
      level: "info"
    )

    Rails.logger.info "[GitHubMergeConflictPollerJob] Enqueued merge conflict message for session #{session.id}, PR #{pr_url}"
  end
end
