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
# the session's turn (see sessions 7235 and 3889). The cost is up to
# one extra poll interval (~2 min) of latency before a genuine, persistent
# conflict is reported.
#
# Uses the GitHub REST API (gh api) to check PR mergeability, which is more
# reliable than the GraphQL mergeable field for conflict detection.
#
class GitHubMergeConflictPollerJob < ApplicationJob
  include DatabaseRetry
  include AutomatedSessionMessage

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

  # The two custom_metadata keys this job's debounce lives in. Named so the one
  # other place that has to touch them — #forget_conflict!, below — cannot drift
  # from the poll body that writes them.
  CONFIRMED_METADATA_KEY = "github_pull_request_merge_conflicts".freeze
  SUSPECTED_METADATA_KEY = "github_pull_request_merge_conflicts_suspected".freeze

  # Forget everything the debounce remembers about one PR, so the next poll
  # re-derives its conflict state from scratch.
  #
  # Exists for exactly one caller: the delivery-time re-validation that retires a
  # conflict notice whose PR now reads mergeable (EnqueuedMessage#stale?). By the
  # time that happens this job has already recorded the PR as confirmed, and the
  # confirmed marker is what makes #poll_merge_conflicts skip it — cleared only
  # by a CLEAN reading. So without this call a suppression would be permanent:
  # if the `mergeable == true` that justified it was itself one of the stale
  # readings the two-poll debounce exists because GitHub produces, the PR is
  # still conflicting, every later poll takes the "already notified" branch, and
  # the session is never told. That is the silent, strictly-worse failure the
  # guard is supposed to avoid, reintroduced by the guard.
  #
  # Clearing both markers instead makes the guard self-correcting: a conflict
  # that was real is re-suspected on the next poll and re-confirmed on the one
  # after, costing one debounce cycle rather than the notice.
  #
  # @param session [Session]
  # @param pr_url [String]
  # @return [void]
  def self.forget_conflict!(session, pr_url)
    # Read and write through a FRESH copy rather than the caller's instance.
    # merge_custom_metadata! replaces each named key wholesale, so a stale read
    # of the markers hash would clobber a marker a concurrent poll had just
    # written for a DIFFERENT PR — and reloading the caller's object under it
    # would be a side effect it did not ask for.
    fresh = Session.find_by(id: session.id)
    return unless fresh

    confirmed = fresh.custom_metadata&.dig(CONFIRMED_METADATA_KEY) || {}
    suspected = fresh.custom_metadata&.dig(SUSPECTED_METADATA_KEY) || {}
    return unless confirmed.key?(pr_url) || suspected.key?(pr_url)

    fresh.merge_custom_metadata!(
      CONFIRMED_METADATA_KEY => confirmed.except(pr_url),
      SUSPECTED_METADATA_KEY => suspected.except(pr_url)
    )
    Rails.logger.info "[GitHubMergeConflictPollerJob] Cleared conflict markers for #{pr_url} on session " \
      "#{session.id} so the next poll re-derives them"
  end

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
    current_conflicts = session.custom_metadata&.dig(CONFIRMED_METADATA_KEY) || {}
    current_suspected = session.custom_metadata&.dig(SUSPECTED_METADATA_KEY) || {}
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
    metadata_updates[CONFIRMED_METADATA_KEY] = updated_conflicts if updated_conflicts != current_conflicts
    metadata_updates[SUSPECTED_METADATA_KEY] = updated_suspected if updated_suspected != current_suspected

    if metadata_updates.any?
      # The merge happens in PostgreSQL, so there is no stale-read window left for a
      # reload to narrow: keys other pollers wrote during this poll survive.
      with_db_retry { session.merge_custom_metadata!(metadata_updates) }
      Rails.logger.info "[GitHubMergeConflictPollerJob] Updated merge conflict statuses for session #{session.id}: confirmed=#{updated_conflicts} suspected=#{updated_suspected}"
    end
  end

  NULL_RETRY_DELAY = 5 # seconds between retries when GitHub returns null
  NULL_MAX_RETRIES = 3 # max retries before giving up on null response

  # Wall-clock bound on the `gh` child, process group killed on deadline. This job is a
  # `total_limit: 1` singleton, so without it a half-open connection to GitHub holds the
  # only slot and every later tick is a no-op enqueue — merge conflicts stop being
  # detected with nothing raised and no watchdog to notice (#458).
  #
  # PER ATTEMPT. `fetch_merge_conflict_status` already calls this up to
  # `NULL_MAX_RETRIES + 1` times while GitHub computes mergeability, and each of those
  # is its own round trip that can hang on its own. A timeout is a nil reading, which
  # this poller already treats as "no answer this tick" and never as "conflicting".
  #
  # 20s matches GithubPullRequestMergeability, which reads the same endpoint: GitHub
  # computes mergeability on demand, so this call is not always the cheap one it looks.
  MERGEABLE_TIMEOUT = 20

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

    result = GithubCli.run(command, timeout: MERGEABLE_TIMEOUT)

    # Anything short of a demonstrable exit 0 — a non-zero exit, a lost exit code, a
    # timeout — means we took no reading. nil says that; it is never "conflicting".
    # See GithubCli.
    unless result.success?
      Rails.logger.warn "[GitHubMergeConflictPollerJob] gh api command failed for #{owner}/#{repo}##{pr_number}: " \
        "#{result.failure_description}"
      return nil
    end

    result.stdout.strip
  end

  # Delivery itself — immediate when the session is parked in needs_input, queued
  # behind the current turn otherwise — lives in AutomatedSessionMessage, shared
  # with the merged-PR message the PR poller sends.
  def enqueue_merge_conflict_message(session, pr_url)
    deliver_automated_message(
      session,
      AutomatedPrompts.merge_conflict_message(pr_url),
      event_description: "Merge conflict detected on #{pr_url}",
      origin: "automated_merge_conflict"
    )
  end
end
