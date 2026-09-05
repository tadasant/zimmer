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
# - the key is absent - GitHub answered and the PR has no checks configured
#
# A CI reading that could not be taken at all is CI_STATUS_UNKNOWN, and leaves the
# recorded value alone rather than clearing it -- see that constant.
#
# When a PR goes from "open" to "merged" the session is told, once, via
# AutomatedPrompts.pr_merged_message — the merge is either the end of the
# session's work or the event it was parked waiting for, and it is the only one
# that can tell which. PRs already merged the first time this job sees them are
# not announced: a session that recorded a PR URL which was merged before the
# first poll never did the work in question, and waking it would be noise.
# github_pull_request_merged_notified records which PRs have been announced.
#
# That message also carries WHAT THE MERGE FIRED — the workflow runs GitHub
# created on the merge commit, read here at announcement time. For a PR whose
# merge triggers a deploy, merged is roughly the halfway point: the deploy takes
# minutes and can fail on a path the PR's own CI never exercised, and the session
# reading this message is the one holding the context to diagnose that
# (tadasant/tadasant-internal#1969). A session cannot see its repository's
# workflow triggers from the inside, so the poller answers the question for it
# rather than asking it to guess — and answers "nothing fired" the vast majority
# of the time, which leaves the ordinary archive-on-merge path exactly as it was.
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

  # Ceiling on the backed-off interval for a session that still holds a PR
  # Zimmer has not seen reach a terminal state.
  #
  # PollBackoff's curve measures how recently a *user* touched the session, and
  # past 24 hours of that it drops to one poll a day. A session parked holding a
  # PR is idle by construction — it did the work, said so, and is waiting for
  # exactly one event — so it decays into the slowest bucket precisely when the
  # message it is waiting for is the only thing that can release it. Sessions
  # 4419 and 4422 were last polled at 23.7 hours of activity age, crossed into
  # the 24-hour bucket eighteen minutes later, and so were not due again until a
  # full day after that: their PRs merged eight hours inside that gap and neither
  # session was ever told (#494).
  #
  # 30 minutes is deliberately not a new rate. It is the floor the 8–24 hr bucket
  # already applies, so a waiting session holds the cadence it had at 23:59 of
  # idleness instead of falling off a cliff at 24:00 — the fix removes the cliff
  # without introducing any polling rate the rate limit does not already absorb.
  #
  # A session whose every tracked PR has merged or closed is not waiting on
  # anything and keeps the full curve, 24-hour floor included. That is the case
  # PollBackoff was written for and it is untouched.
  AWAITING_PR_OUTCOME_MAX_POLL_INTERVAL = 30.minutes.to_i

  # How long the cap above is allowed to hold a session at that cadence.
  #
  # Without this the cap has no expiry, and "unresolved" is a state a session can
  # never leave: nothing removes an idle session from `Session.with_github_prs`
  # (archiving old sessions is an operator action, not a cron job), and a PR that
  # was deleted, or whose repo the token cannot read, returns nil from
  # `fetch_pr_status` on every tick so no status is ever recorded for it. Both
  # leave a session pinned at two polls an hour for the rest of its life, and the
  # capped population then only ever grows — which is the one way this change
  # could re-create the pressure PollBackoff exists to relieve. Bounding it keeps
  # that population proportional to a week of fleet throughput rather than to all
  # of time.
  #
  # A week is well past the point where the cap is buying anything. It exists so
  # a session waiting on a merge hears about it promptly; a PR still unmerged
  # after seven days with no human engagement at all is fleet hygiene for the
  # nightly sweep, not a notification-latency problem. Past the bound the session
  # falls back to the full curve — still polled, once a day, exactly as it was
  # before this change.
  AWAITING_PR_OUTCOME_MAX_IDLE = 7.days

  # Wall-clock bounds on the two `gh` children this job spawns, process group
  # killed on deadline. Without them a half-open connection to GitHub blocks the
  # tick forever and, because this job is a `total_limit: 1` singleton, every
  # later tick is a no-op enqueue — PR status quietly stops updating with nothing
  # raised and no watchdog to notice (#458).
  #
  # Both are deliberately generous. The failure being bounded is a hang, not
  # slowness, and a bound tight enough to fire on a merely-degraded API would
  # trade a rare wedge for a spurious failure on every 30s tick. A timeout here
  # means "ask again next tick": `fetch_pr_status` returns nil, which already
  # leaves the recorded status alone, and `fetch_ci_status` returns
  # CI_STATUS_UNKNOWN, which is what that constant exists for.
  #
  # `gh pr view` is one REST round trip.
  PR_STATUS_TIMEOUT = 20
  # `gh pr checks` is the slower of the two: it resolves the head commit and then
  # aggregates every check run and status on it, so it does more work server-side
  # and returns more rows on a PR with a large matrix.
  CI_STATUS_TIMEOUT = 30

  # `gh pr view` again for the merge commit, and one `gh api` page of the workflow
  # runs on it. Both run only on the open → merged transition — once per PR, ever —
  # so they add nothing to the steady-state poll cost or to the rate limit.
  MERGE_COMMIT_TIMEOUT = 20
  POST_MERGE_RUNS_TIMEOUT = 30

  # How many runs on the merge commit to ask GitHub for, in the one page this asks
  # for. A merge fires a handful of workflows directly — but `workflow_run`
  # listeners fire on each of those completing and carry the same head SHA, and
  # the API returns newest first, so a page small enough to be "generous" for the
  # direct runs can push them off the end on a merge this job sees late. One full
  # page costs the same round trip; the message only ever names the runs that are
  # unfinished or red, so a long tail of completed listeners adds no noise to it.
  POST_MERGE_RUNS_PAGE_SIZE = 100

  # What `fetch_ci_status` returns when the call did not complete, as distinct from
  # the nil it returns when GitHub answered and the PR simply has no checks.
  #
  # The two used to be the same nil, and the caller clears the recorded CI status on
  # nil — so a hung or failed `gh pr checks` erased a real `fail`/`pass` and wrote
  # "this PR has no checks" in its place. That is the one thing a timeout must never
  # be allowed to mean, so "we could not ask" gets its own value and the caller
  # leaves the recorded status alone.
  CI_STATUS_UNKNOWN = :unknown

  def perform
    Session.with_github_prs.find_each do |session|
      due = PollBackoff.should_poll?(
        session,
        job_key: POLL_BACKOFF_KEY,
        base_interval: BASE_POLL_INTERVAL_SECONDS,
        max_interval: max_poll_interval_for(session)
      )

      unless due
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

  # The backoff ceiling to hand PollBackoff for this session, or nil to let the
  # curve run its full course. See AWAITING_PR_OUTCOME_MAX_POLL_INTERVAL.
  #
  # The predicate is deliberately the recorded status rather than the session's
  # own state: a PR url with no status yet is unresolved too, which is what keeps
  # a just-recorded PR from waiting up to a day to be seen as `open` — the
  # transition the merge announcement is conditioned on.
  def max_poll_interval_for(session)
    return nil if session.unresolved_pr_urls.empty?
    return nil if Time.current - session.last_user_activity_at > AWAITING_PR_OUTCOME_MAX_IDLE

    AWAITING_PR_OUTCOME_MAX_POLL_INTERVAL
  end

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

        # CI_STATUS_UNKNOWN means we could not ask, so neither branch below is right:
        # leave whatever is recorded and ask again next tick. Clearing here would
        # report "no checks" for a PR whose CI we merely failed to read.
        unless ci_status == CI_STATUS_UNKNOWN
          if ci_status.present?
            updated_ci_statuses[pr_url] = ci_status
          else
            # GitHub answered and the PR has no checks (none configured).
            updated_ci_statuses.delete(pr_url)
          end
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
      automation = post_merge_automation(pr_url)

      deliver_automated_message(
        session,
        AutomatedPrompts.pr_merged_message(
          pr_url,
          post_merge_runs: automation[:runs],
          merge_commit_sha: automation[:merge_commit_sha]
        ),
        event_description: "PR merged: #{pr_url}",
        origin: "automated_pr_merged"
      )
    end
  end

  # What this merge set in motion on GitHub, for the message to report.
  #
  # `{ merge_commit_sha:, runs: }`, and a nil sha is the "we could not tell"
  # answer — AutomatedPrompts drops the whole paragraph on it and the message
  # reads exactly as it did before this existed. Failing open is the deliberate
  # choice: a lookup that GitHub would not answer must not leave a session that
  # finished its work sitting there waiting for a deploy nobody can name.
  #
  # An empty `runs` with a sha present is a different answer and a useful one —
  # "nothing fired that GitHub will admit to yet" — because the poller can see a
  # merge within a second of it happening, before the runs it fired exist. The
  # message turns that into one `gh run list` for the session to run, which is
  # authoritative where this reading was early.
  def post_merge_automation(pr_url)
    match = pr_url.match(%r{github\.com/([^/]+)/([^/]+)/pull/(\d+)})
    return { merge_commit_sha: nil, runs: [] } unless match

    owner, repo, pr_number = match.captures

    sha = fetch_merge_commit_sha(owner, repo, pr_number)
    return { merge_commit_sha: nil, runs: [] } if sha.blank?

    { merge_commit_sha: sha, runs: fetch_post_merge_runs(owner, repo, sha) || [] }
  end

  # The SHA the merge landed as, or nil if GitHub would not say.
  def fetch_merge_commit_sha(owner, repo, pr_number)
    command = [ "gh", "pr", "view", pr_number.to_s, "--repo", "#{owner}/#{repo}", "--json", "mergeCommit" ]

    result = GithubCli.run(command, timeout: MERGE_COMMIT_TIMEOUT)

    unless result.success?
      Rails.logger.warn "[GitHubPullRequestPollerJob] gh pr view (mergeCommit) failed: #{result.failure_description}"
      return nil
    end

    JSON.parse(result.stdout).dig("mergeCommit", "oid").presence
  rescue JSON::ParserError => e
    Rails.logger.error "[GitHubPullRequestPollerJob] Failed to parse merge commit: #{e.message}"
    nil
  end

  # The workflow runs GitHub has created on `sha`, or nil when the call did not
  # complete — which the caller treats as an empty list rather than as a claim.
  #
  # Queried by head SHA rather than by branch or by workflow name, deliberately.
  # It is the only question with one right answer: "which runs exist because THIS
  # merge landed". A name filter would have to guess which workflows deploy, and
  # the deploy that failed three times on 2026-08-30 was not called "deploy".
  def fetch_post_merge_runs(owner, repo, sha)
    command = [
      "gh", "api",
      "repos/#{owner}/#{repo}/actions/runs?head_sha=#{sha}&per_page=#{POST_MERGE_RUNS_PAGE_SIZE}",
      "--jq", "[.workflow_runs[] | {name: .name, status: .status, conclusion: .conclusion, url: .html_url}]"
    ]

    result = GithubCli.run(command, timeout: POST_MERGE_RUNS_TIMEOUT)

    unless result.success?
      Rails.logger.warn "[GitHubPullRequestPollerJob] gh api (post-merge runs) failed: #{result.failure_description}"
      return nil
    end

    runs = JSON.parse(result.stdout.presence || "[]")
    runs.is_a?(Array) ? runs : nil
  rescue JSON::ParserError => e
    Rails.logger.error "[GitHubPullRequestPollerJob] Failed to parse post-merge runs: #{e.message}"
    nil
  end

  def fetch_pr_status(owner, repo, pr_number)
    # Use gh CLI to get PR status in JSON format
    # Note: The field is "mergedAt" (timestamp or null), not "merged" (boolean)
    command = [ "gh", "pr", "view", pr_number.to_s, "--repo", "#{owner}/#{repo}", "--json", "state,mergedAt" ]

    result = GithubCli.run(command, timeout: PR_STATUS_TIMEOUT)

    # Anything short of a demonstrable exit 0 — a non-zero exit, a lost exit code, a
    # timeout — means we did not learn this PR's state. Returning nil says exactly
    # that; it must never be read as "the PR is gone". See GithubCli.
    unless result.success?
      Rails.logger.warn "[GitHubPullRequestPollerJob] gh command failed: #{result.failure_description}"
      return nil
    end

    data = JSON.parse(result.stdout)
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

  # Fetch CI check status for a PR.
  #
  # Returns the overall CI status — "pass", "fail", "pending", "skipping", "cancel" —
  # or nil when GitHub answered and the PR has no checks, or CI_STATUS_UNKNOWN when the
  # call did not complete. The caller treats those last two differently on purpose.
  def fetch_ci_status(owner, repo, pr_number)
    # Use gh CLI to get CI checks status in JSON format
    # The bucket field categorizes state into: pass, fail, pending, skipping, cancel
    command = [ "gh", "pr", "checks", pr_number.to_s, "--repo", "#{owner}/#{repo}", "--json", "bucket,state" ]

    result = GithubCli.run(command, timeout: CI_STATUS_TIMEOUT)

    # Exit code 8 means checks are pending (not an error). Neither a lost exit code nor
    # a timeout has an exit code to compare, so both correctly fall through to the
    # failure branch rather than being read as "pending".
    unless result.success? || result.exit_code == 8
      Rails.logger.warn "[GitHubPullRequestPollerJob] gh pr checks command failed: #{result.failure_description}"
      return CI_STATUS_UNKNOWN
    end

    checks = JSON.parse(result.stdout)

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
    CI_STATUS_UNKNOWN
  end
end
