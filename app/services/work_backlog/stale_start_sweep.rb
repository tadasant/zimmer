# frozen_string_literal: true

module WorkBacklog
  # Re-examines `started` backlog rows whose session has ended, and puts back the
  # ones the fleet dropped.
  #
  # == The hole this closes
  #
  # A row that reached `started` was never looked at again. The pull marks it,
  # spawns a session and moves on; `Ranking` only ever reads `queued` rows; and
  # nothing anywhere asks what became of the session. So an implementing session
  # that archived without closing its issue left the item in a state that is
  # neither queued nor being worked — and, because the only thing that would ever
  # have moved it is a pull, permanently.
  #
  # Measured 2026-09-11 across the fleet's five gated repos: of 159 open
  # convergent issues, 41 were `started`, and 13 of those had been started four
  # or more days earlier with the issue still open. One had been sitting for 37
  # days behind a session that archived after five minutes.
  #
  # The loss was silent in the worst way. The Issues page shows such an issue
  # under "In GitHub, not on the queue", which reads as "nobody has rated this
  # yet" rather than "the fleet started this and dropped it" — so the pile grew
  # and looked like ordinary un-triaged work. This sweep is the thing that looks,
  # and WorkBacklogItem.stranded is the name it gave the population.
  #
  # == The decision is three-way, and the third direction is the expensive one
  #
  # Getting it wrong toward "leave it alone" strands the item again, visibly, on
  # a page that now counts it. Getting it wrong toward "put it back" spawns a
  # session to redo work that is already done and opens a second pull request for
  # it. Those are not symmetric, so the rule is: **re-queue only when the session
  # demonstrably left nothing behind.**
  #
  #   1. The issue is CLOSED                       → finished. Terminal.
  #   2. The session merged a PR                   → the work landed.
  #   3. The session left an unresolved PR         → work to show; leave it.
  #   4. GitHub links a PR to the issue            → somebody else has it.
  #   5. Otherwise, the issue is open and nothing  → re-queue at its old rank.
  #      came of the session
  #
  # Rules 2 and 3 read Zimmer's own record (`github_pull_request_urls` and the
  # statuses the PR poller writes beside them) rather than GitHub, because that
  # is the only signal that survives a PR with no closing keyword in it — the
  # case where GitHub knows of no link and the work is nevertheless done. Rule 4
  # reads GitHub's `linked:pr`, one search per repo, because a *different*
  # session picking the issue up afterwards leaves no trace on this item at all.
  # Verified against the sample that motivated this: `tadasant/strad#281` looks
  # exactly like a stranded row until you ask GitHub, which answers with open PR
  # `tadasant/strad#323`.
  #
  # A read that fails is never a conclusion. An unreadable repo, an issue the
  # snapshot does not carry, a `linked:pr` search that errors — each leaves the
  # row as `unknown` and re-examined next pass, rather than re-queued on a guess.
  #
  # == Re-queuing keeps the rank
  #
  # `WorkBacklogItem#requeue!` does not recompute a precedence, and that is the
  # point: an item is pulled because it sits at the top of its band, so placing a
  # recovered one GAP below the band's lowest peer would sink it to the bottom
  # and it would never be reached. See the method for the rest of it.
  #
  # == And the pull re-checks anyway
  #
  # This sweep is not the last line of defence, which is what makes its
  # conservatism affordable. `WORK_BACKLOG.md`'s pull protocol requires the
  # groomer to re-check every candidate on GitHub before starting it, and to drop
  # a dead one into the pull's `dead` list with a mechanical reason — so an item
  # this sweep re-queues in error is caught one step later as `issue_closed` or
  # `issue_has_open_pr` and removed without a session being spent.
  class StaleStartSweep
    # How long after its session ends a started row is left alone. A merge closes
    # the issue seconds later and a PR-poll notification lands shortly after, so a
    # row examined immediately looks stranded while it is merely settling. Six
    # hours is far past either and still three orders of magnitude short of the 37
    # days the worst observed row sat for, so the bound on the damage is the
    # sweep's cadence, not this.
    GRACE = 6.hours

    # How many times one item may be put back before the sweep stops and alerts.
    # A session that dies with nothing to show is the ordinary failure this
    # recovers; an item on its fourth attempt is not being lost, it is failing,
    # and more sessions will not fix it.
    MAX_REQUEUES = 3

    # Rows examined in one pass. Every row costs a hash lookup and no GitHub call
    # of its own — the reads are per REPO, not per row — so this is generous. It
    # exists so a surprise population cannot turn one tick into an hour.
    MAX_EXAMINED_PER_SWEEP = 200

    # Rows re-queued in one pass. Deliberately far below the examined bound: a
    # re-queue is a write to the queue the groomer pulls from, and a bug here
    # putting eighty items back at once would be felt as eighty sessions the next
    # morning. Recovering ten a pass drains any backlog this could have within a
    # day of hourly ticks.
    MAX_REQUEUES_PER_SWEEP = 10

    # One page per repo, which is what GithubSearchService's ceiling allows and
    # far more linked issues than any of these repos carries.
    LINKED_PR_QUERY = "repo:%s is:issue is:open linked:pr"

    # Counted in `outcomes` beside the liveness states, but deliberately not one
    # of them: nothing is written to the row, because the pass simply ran out of
    # its re-queue budget before reaching it.
    DEFERRED = "deferred"

    ALERT_DEDUP_KEY = "work-backlog-requeue-exhausted"

    # What one pass did, in the shape the job logs and the tests assert on.
    Result = Data.define(:examined, :outcomes, :requeued_keys, :oldest_stranded_age) do
      def count(state) = outcomes.fetch(state, 0)
    end

    class << self
      # @param now [Time]
      # @param logger [StructuredLogger, Logger]
      # @return [Result]
      def sweep!(now: Time.current, logger: Rails.logger)
        candidates = candidates(now)
        return empty_result(now, logger) if candidates.empty?

        snapshot = Issues::GithubSnapshot.fetch
        issues_by_url = snapshot.issues.index_by(&:url)
        linked = linked_issue_urls(candidates.map(&:repo).uniq, logger)

        outcomes = Hash.new(0)
        requeued = []

        Ranking.with_lock do
          candidates.each do |item|
            state = examine(item, issues_by_url: issues_by_url, linked: linked,
                            requeued_so_far: requeued.size, now: now)
            outcomes[state] += 1
            requeued << item.key if state == WorkBacklogItem::LIVENESS_REQUEUED
          end

          # Every writer re-ranks. A re-queued item lands back inside its band by
          # construction, so this normally moves nothing — but an item whose band
          # was re-spaced while it was away is exactly the drift `rerank!` exists
          # to correct, and skipping it here would be the one queue write that
          # does not.
          Ranking.rerank!(now: now) if requeued.any?
        end

        result = Result.new(examined: candidates.size, outcomes: outcomes, requeued_keys: requeued,
                            oldest_stranded_age: oldest_stranded_age(now))
        report(result, logger)
        result
      end

      # The rows worth looking at, least-recently-checked first so that a large
      # population round-robins instead of the sweep re-reading the same head of
      # it every tick. Never-checked rows sort first: they are the ones nothing
      # has ever said anything about.
      def candidates(now)
        WorkBacklogItem.stranded(grace: GRACE, now: now)
                       .includes(:started_session)
                       .order(Arel.sql("liveness_checked_at ASC NULLS FIRST"), started_at: :asc)
                       .limit(MAX_EXAMINED_PER_SWEEP)
                       .to_a
      end

      private

      # The five-way decision, in the order the class comment states it, plus the
      # two bookkeeping outcomes that stop a re-queue from happening: an item the
      # gate has already re-appended, and one that has been round this loop
      # MAX_REQUEUES times.
      def examine(item, issues_by_url:, linked:, requeued_so_far:, now:)
        issue = item.issueless? ? nil : issues_by_url[item.issue_url]

        # An issue we could not read says nothing, and "says nothing" must never
        # come out as "nothing came of it". Issueless items skip this: there is no
        # thread to read, and the session's own PRs are the whole signal.
        return record(item, WorkBacklogItem::LIVENESS_UNKNOWN, now) if issue.nil? && !item.issueless?
        return record(item, WorkBacklogItem::LIVENESS_ISSUE_CLOSED, now) if issue && !issue.open?

        session = item.started_session
        return record(item, WorkBacklogItem::LIVENESS_PR_MERGED, now) if merged_pr?(session)
        return record(item, WorkBacklogItem::LIVENESS_SESSION_PR_OPEN, now) if unresolved_pr?(session)

        # `linked` is nil for a repo whose search failed — unknown, not "no link".
        repo_links = linked[item.repo]
        return record(item, WorkBacklogItem::LIVENESS_UNKNOWN, now) if repo_links.nil? && !item.issueless?
        return record(item, WorkBacklogItem::LIVENESS_ISSUE_HAS_OPEN_PR, now) if repo_links&.include?(item.issue_url)

        requeue(item, requeued_so_far: requeued_so_far, now: now)
      end

      def requeue(item, requeued_so_far:, now:)
        if item.requeue_count >= MAX_REQUEUES
          return record(item, WorkBacklogItem::LIVENESS_REQUEUE_EXHAUSTED, now, alert: true)
        end
        # The unique partial index on (key) where status = 'queued' would raise
        # here, and the raise would be right: the gate re-appended the issue while
        # this row sat, and the work is already back on the queue.
        if WorkBacklogItem.queued.exists?(key: item.key)
          return record(item, WorkBacklogItem::LIVENESS_ALREADY_QUEUED, now)
        end
        # Not a liveness state: the row is simply left for the next pass, keeping
        # its old `liveness_checked_at` so it sorts to the front of it. Counted
        # under its own word so a pass that hit the cap says so.
        return DEFERRED if requeued_so_far >= MAX_REQUEUES_PER_SWEEP

        item.requeue!(now: now)
        WorkBacklogItem::LIVENESS_REQUEUED
      end

      def record(item, state, now, alert: false)
        item.record_liveness!(state, now: now)
        alert_on_exhaustion(item) if alert
        state
      end

      # Any PR this session opened that GitHub has since merged. Read off the
      # statuses the PR poller writes, which is the only place a merge is
      # recorded against the session rather than against the issue.
      def merged_pr?(session)
        statuses = session&.custom_metadata&.dig("github_pull_request_statuses")
        statuses.is_a?(Hash) && statuses.value?("merged")
      end

      # A PR the session opened whose last recorded status is not terminal. For an
      # ended session that can mean "still open" or "the poller never rated it",
      # and both are work to show — so both stop a re-queue. An item left here
      # rather than re-queued is not lost: it is counted as stranded and named on
      # the Issues page, which is the difference between this and what it replaced.
      def unresolved_pr?(session)
        session.present? && session.unresolved_pr_urls.any?
      end

      # `{ repo => Set<issue_url> }` for the open issues GitHub says have a PR
      # linked by a closing reference, and NO KEY AT ALL for a repo whose search
      # failed. The absence is load-bearing: it is what makes an unreadable repo
      # leave its rows alone instead of re-queuing all of them.
      def linked_issue_urls(repos, logger)
        repos.each_with_object({}) do |repo, found|
          items = GithubSearchService.search_issues(format(LINKED_PR_QUERY, repo))
          found[repo] = items.filter_map { |item| item["html_url"] }.to_set
        rescue GithubSearchService::SearchError => e
          logger.warn("[WorkBacklog::StaleStartSweep] could not read linked PRs for #{repo}: #{e.message}")
        end
      end

      # How long the oldest stranded row has been stranded, in seconds. The one
      # number that answers "is this getting better or worse" — reported every
      # pass whether or not the pass acted, so it is greppable over time.
      def oldest_stranded_age(now)
        oldest = WorkBacklogItem.stranded(grace: GRACE, now: now).minimum(:started_at)
        oldest && (now - oldest).to_i
      end

      def empty_result(now, logger)
        result = Result.new(examined: 0, outcomes: {}, requeued_keys: [],
                            oldest_stranded_age: oldest_stranded_age(now))
        report(result, logger)
        result
      end

      # WARN when the pass re-queued something, INFO otherwise. A re-queue means
      # the fleet had dropped work and this repaired it, which is worth finding
      # in the log store; a pass that found nothing to repair is the expected
      # outcome. The split is also what makes the repair findable at all:
      # production exports WARN and above only (#584), so an INFO-only sweep
      # would be invisible there. The standing count lives on the Issues page and
      # in get_work_backlog, not here.
      def report(result, logger)
        level = result.requeued_keys.any? ? :warn : :info
        logger.public_send(level, "[WorkBacklog::StaleStartSweep] examined #{result.examined}, " \
                    "re-queued #{result.requeued_keys.size}" \
                    "#{" (#{result.requeued_keys.join(', ')})" if result.requeued_keys.any?}; " \
                    "outcomes #{result.outcomes.sort.to_h.inspect}; " \
                    "oldest stranded #{result.oldest_stranded_age ? "#{result.oldest_stranded_age}s" : "none"}")
      end

      # The one case the mechanism cannot fix by itself, so the one case that
      # pages. Everything else this sweep finds it either resolves or counts on
      # the Issues page; an item that has burned MAX_REQUEUES sessions is a
      # different fault wearing this one's clothes.
      def alert_on_exhaustion(item)
        AlertService.raise_alert(
          "Work backlog item cannot be recovered",
          details: "#{item.key} (#{item.issue_url || "no issue"}) has been re-queued " \
                   "#{item.requeue_count} times and its session has ended each time with nothing to " \
                   "show. It is left `started` rather than put back again — it is on the Issues page " \
                   "under Stranded, and sessions #{item.attempted_session_ids.join(', ')} are what " \
                   "became of it. Something other than a lost session is wrong here.",
          source: "WorkBacklog::StaleStartSweep",
          dedup_key: ALERT_DEDUP_KEY
        )
      end
    end
  end
end
