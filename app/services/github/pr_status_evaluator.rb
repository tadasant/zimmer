# frozen_string_literal: true

module Github
  # Records what a pass's reading of each tracked PR says about its lifecycle, and
  # tells the session when one of them merges.
  #
  # Driven by Github::PrPollPass, which owns the enumeration, the backoff gate and the
  # single `gh pr view` this evaluator reads. Everything below the fetch is unchanged
  # from GitHubPullRequestPollerJob, which is what this was.
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
  # rather than asking it to guess.
  #
  # The question is "which runs exist because THIS merge landed", not "which of them
  # is a deploy" — the second is a name-matching guess, and the deploy that failed
  # three times on 2026-08-30 was not called `deploy`. So a repository with any
  # workflow on pushes to its default branch — this one has two — will name runs on
  # most merges and the merging session will sleep through them. That cost is
  # deliberate and bounded: a red `main` or a failed release build is the merging
  # session's business too, the wait is a sleep in `waiting` rather than a claim on
  # the human's action queue, and it expires. A merge that fires nothing keeps the
  # archive-immediately path exactly as it was.
  #
  class PrStatusEvaluator
    include DatabaseRetry
    include AutomatedSessionMessage

    # Wall-clock bound on the `gh pr checks` child, process group killed on deadline.
    # Without it a half-open connection to GitHub blocks the pass forever and, because
    # the pass job is a `total_limit: 1` singleton, every later tick is a no-op enqueue
    # — PR status quietly stops updating with nothing raised and no watchdog to notice
    # (#458).
    #
    # Deliberately generous. The failure being bounded is a hang, not slowness, and a
    # bound tight enough to fire on a merely-degraded API would trade a rare wedge for a
    # spurious failure on every 30s tick. A timeout here means "ask again next tick":
    # `fetch_ci_status` returns CI_STATUS_UNKNOWN, which is what that constant exists
    # for.
    #
    # `gh pr checks` is the slower of the pass's two per-PR calls: it resolves the head
    # commit and then aggregates every check run and status on it, so it does more work
    # server-side and returns more rows on a PR with a large matrix.
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

    # @param session [Session]
    # @param refs [Array<Github::PrRef>] the session's tracked PRs, already resolved
    # @param snapshots [Hash{String => Github::PrSnapshot, nil}] this pass's reading of
    #   each PR, keyed by url. A nil value is "we could not ask about this one".
    # @return [void]
    def evaluate(session, refs, snapshots)
      return if refs.empty?

      current_statuses = session.custom_metadata&.dig("github_pull_request_statuses") || {}
      current_ci_statuses = session.custom_metadata&.dig("github_pull_request_ci_statuses") || {}
      current_merged_notified = session.custom_metadata&.dig("github_pull_request_merged_notified") || {}
      updated_statuses = current_statuses.dup
      updated_ci_statuses = current_ci_statuses.dup
      updated_merged_notified = current_merged_notified.dup
      newly_merged_prs = []

      refs.each do |ref|
        pr_url = ref.url
        status = snapshots[pr_url]&.status
        next unless status.present?

        # Only the open → merged transition is announced, and only once. No debounce:
        # unlike the merge conflict evaluator's mergeable field, `mergedAt` has no
        # transient-false failure mode — a PR with a merge timestamp is merged, and
        # stays merged.
        if status == "merged" && current_statuses[pr_url] == "open" && !current_merged_notified[pr_url]
          newly_merged_prs << pr_url
        end

        updated_statuses[pr_url] = status

        # Fetch CI status only for open PRs
        if status == "open"
          ci_status = fetch_ci_status(ref)

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
      # the session row this pass read at the start is stale by now — a whole-column write
      # here would erase whatever the session's own worker recorded in the meantime,
      # `github_pull_request_urls` included.
      with_db_retry { session.merge_custom_metadata!(updates) }

      Rails.logger.info "[Github::PrStatusEvaluator] Updated PR statuses for session #{session.id}: #{updated_statuses}" if statuses_changed
      Rails.logger.info "[Github::PrStatusEvaluator] Updated CI statuses for session #{session.id}: #{updated_ci_statuses}" if ci_statuses_changed
    end

    private

    # Tell the session about each PR that just merged.
    #
    # Delivery goes through AutomatedSessionMessage, the same path the merge conflict
    # evaluator uses: immediate when the session is parked in needs_input, queued behind
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
        Rails.logger.info "[Github::PrStatusEvaluator] Skipping merged-PR message for #{session.status} session #{session.id}: #{pr_urls.join(', ')}"
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
      ref = PrRef.parse(pr_url)
      return { merge_commit_sha: nil, runs: [] } unless ref

      sha = fetch_merge_commit_sha(ref)
      return { merge_commit_sha: nil, runs: [] } if sha.blank?

      { merge_commit_sha: sha, runs: fetch_post_merge_runs(ref, sha) || [] }
    end

    # The SHA the merge landed as, or nil if GitHub would not say.
    def fetch_merge_commit_sha(ref)
      command = [ "gh", "pr", "view", ref.number.to_s, "--repo", ref.slug, "--json", "mergeCommit" ]

      result = GithubCli.run(command, timeout: MERGE_COMMIT_TIMEOUT)

      unless result.success?
        Rails.logger.warn "[Github::PrStatusEvaluator] gh pr view (mergeCommit) failed: #{result.failure_description}"
        return nil
      end

      JSON.parse(result.stdout).dig("mergeCommit", "oid").presence
    rescue JSON::ParserError => e
      Rails.logger.error "[Github::PrStatusEvaluator] Failed to parse merge commit: #{e.message}"
      nil
    end

    # The workflow runs GitHub has created on `sha`, or nil when the call did not
    # complete — which the caller treats as an empty list rather than as a claim.
    #
    # Queried by head SHA rather than by branch or by workflow name, deliberately.
    # It is the only question with one right answer: "which runs exist because THIS
    # merge landed". A name filter would have to guess which workflows deploy, and
    # the deploy that failed three times on 2026-08-30 was not called "deploy".
    def fetch_post_merge_runs(ref, sha)
      command = [
        "gh", "api",
        "repos/#{ref.slug}/actions/runs?head_sha=#{sha}&per_page=#{POST_MERGE_RUNS_PAGE_SIZE}",
        "--jq", "[.workflow_runs[] | {name: .name, status: .status, conclusion: .conclusion, url: .html_url}]"
      ]

      result = GithubCli.run(command, timeout: POST_MERGE_RUNS_TIMEOUT)

      unless result.success?
        Rails.logger.warn "[Github::PrStatusEvaluator] gh api (post-merge runs) failed: #{result.failure_description}"
        return nil
      end

      runs = JSON.parse(result.stdout.presence || "[]")
      runs.is_a?(Array) ? runs : nil
    rescue JSON::ParserError => e
      Rails.logger.error "[Github::PrStatusEvaluator] Failed to parse post-merge runs: #{e.message}"
      nil
    end

    # Fetch CI check status for a PR.
    #
    # Returns the overall CI status — "pass", "fail", "pending", "skipping", "cancel" —
    # or nil when GitHub answered and the PR has no checks, or CI_STATUS_UNKNOWN when the
    # call did not complete. The caller treats those last two differently on purpose.
    #
    # This is the pass's second per-PR GitHub call and the only one this evaluator makes
    # itself: `gh pr checks` reads check runs, not the PR object, so there is nothing in
    # Github::PrSnapshot to answer it with.
    def fetch_ci_status(ref)
      # The bucket field categorizes state into: pass, fail, pending, skipping, cancel
      command = [ "gh", "pr", "checks", ref.number.to_s, "--repo", ref.slug, "--json", "bucket,state" ]

      result = GithubCli.run(command, timeout: CI_STATUS_TIMEOUT)

      # Exit code 8 means checks are pending (not an error). Neither a lost exit code nor
      # a timeout has an exit code to compare, so both correctly fall through to the
      # failure branch rather than being read as "pending".
      unless result.success? || result.exit_code == 8
        Rails.logger.warn "[Github::PrStatusEvaluator] gh pr checks command failed: #{result.failure_description}"
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
      Rails.logger.error "[Github::PrStatusEvaluator] Failed to parse gh pr checks output: #{e.message}"
      CI_STATUS_UNKNOWN
    end
  end
end
