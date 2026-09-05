# frozen_string_literal: true

module Github
  # One poll of GitHub for every session that is tracking a pull request.
  #
  # WHY THIS IS ONE PASS
  # --------------------
  # It used to be three cron jobs — PR status, PR comments, merge conflicts — and each
  # of them walked `Session.with_github_prs` on its own tick, read the same
  # `github_pull_request_urls`, parsed each url with its own verbatim copy of the same
  # regex, and took its own `PollBackoff` gate and its own stamp. Two of the three then
  # fetched the SAME pull request object thirty seconds apart to answer two questions
  # about it, and the third read the first one's stored answer out of the database
  # rather than being handed it (#711).
  #
  # So: enumerate once, gate once, parse once, fetch each PR once, stamp once. The three
  # evaluators own only their own state transitions, and the PR reading they share is a
  # local variable rather than a round trip and a column.
  #
  # WHAT THIS COSTS
  # ---------------
  # The pass job is a `total_limit: 1` singleton, so the three evaluators that used to
  # run in three parallel singletons now run in series. A slow comment fetch delays the
  # merged-PR notification behind it, where before it could not. That is the deliberate
  # trade: every call is bounded by GithubCli, the sweep is ordered cheapest-and-most-
  # load-bearing first, and a tick that overruns is dropped rather than queued — the same
  # behaviour each of the three jobs already had on its own.
  class PrPollPass
    # The pass's own backoff key and cadence. Deliberately the PR poller's old key: every
    # session in the fleet already carries a stamp under it, so the pass inherits their
    # cadence at deploy instead of polling all of them at once on the first tick.
    POLL_BACKOFF_KEY = "github_pr_poller"
    BASE_POLL_INTERVAL_SECONDS = 30

    # The two evaluators that keep a cadence of their own INSIDE the pass, under the keys
    # their jobs used to stamp.
    #
    # This is not a second backoff — the pass's own gate has already decided the session
    # is due. It is the cadence each evaluator was written against, preserved now that
    # cron no longer supplies it:
    #
    #   Merge conflicts ran on a 2-minute cron, and its two-consecutive-readings debounce
    #   is tuned to that gap — two readings 30 seconds apart would confirm exactly the
    #   transient it exists to reject. PollBackoff's curve answers 0 for a recently-active
    #   session, so the floor has to be stated: MIN, not just base.
    #
    #   Comments ran on the same 30-second cron as PR status, which is the pass's own
    #   cadence, so it needs no floor. It keeps its key and its curve because the PR
    #   status gate is CAPPED for a session holding an unresolved PR (see below) and the
    #   comment endpoints were never polled on that capped cadence.
    #
    # Both stamps are written in the pass's single metadata write.
    #
    # The pass's own gate is never looser than either of these at any point on
    # PollBackoff's curve, so gating the pass cannot starve an evaluator.
    MERGE_CONFLICT_BACKOFF_KEY = "github_merge_conflict_poller"
    MERGE_CONFLICT_INTERVAL_SECONDS = 120
    COMMENT_BACKOFF_KEY = "github_comment_poller"
    COMMENT_INTERVAL_SECONDS = 30

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
    # `Github::PrSnapshot.fetch` on every tick so no status is ever recorded for it. Both
    # leave a session pinned at two polls an hour for the rest of its life, and the
    # capped population then only ever grows — which is the one way this cap could
    # re-create the pressure PollBackoff exists to relieve. Bounding it keeps
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

    # Sweep every session tracking a PR.
    #
    # One session's failure never ends the sweep: the rescue is per session, exactly
    # where each of the three jobs put its own.
    def run
      Session.with_github_prs.find_each do |session|
        poll_session(session)
      rescue => e
        Rails.logger.error "[Github::PrPollPass] Error polling session #{session.id}: #{e.message}"
      end
    end

    # One session's poll: the gate, the fetch, the three evaluators, the stamp.
    #
    # @param session [Session]
    # @return [void]
    def poll_session(session)
      unless due?(session)
        Rails.logger.info "[Github::PrPollPass] Skipping session #{session.id} (PollBackoff: stale user activity)"
        return
      end

      refs = PrRef.for_session(session)
      snapshots = refs.to_h { |ref| [ ref.url, PrSnapshot.fetch(ref) ] }

      stamped_keys = [ POLL_BACKOFF_KEY ]

      # PR status first: it is the cheapest of the three and it carries the fleet's
      # archive signal, so nothing slower gets to run in front of it.
      run_evaluator(session, "PrStatusEvaluator") do
        PrStatusEvaluator.new.evaluate(session, refs, snapshots)
      end

      if PollBackoff.should_poll?(
        session,
        job_key: MERGE_CONFLICT_BACKOFF_KEY,
        base_interval: MERGE_CONFLICT_INTERVAL_SECONDS,
        min_interval: MERGE_CONFLICT_INTERVAL_SECONDS
      )
        stamped_keys << MERGE_CONFLICT_BACKOFF_KEY
        run_evaluator(session, "MergeConflictEvaluator") do
          MergeConflictEvaluator.new.evaluate(session, refs, snapshots)
        end
      end

      if PollBackoff.should_poll?(session, job_key: COMMENT_BACKOFF_KEY, base_interval: COMMENT_INTERVAL_SECONDS)
        stamped_keys << COMMENT_BACKOFF_KEY
        run_evaluator(session, "CommentEvaluator") do
          CommentEvaluator.new.evaluate(session, refs)
        end
      end

      PollBackoff.record_poll!(session, job_key: stamped_keys)
    end

    private

    # Whether this session has earned another pass. See PollBackoff for the curve, and
    # #max_poll_interval_for for the ceiling.
    def due?(session)
      PollBackoff.should_poll?(
        session,
        job_key: POLL_BACKOFF_KEY,
        base_interval: BASE_POLL_INTERVAL_SECONDS,
        max_interval: max_poll_interval_for(session)
      )
    end

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

    # Run one evaluator, and keep its failure to itself.
    #
    # The three used to be three jobs, so a raise in one could not touch the other two.
    # Fusing them would have handed that isolation back to the per-session rescue in
    # #run — where a raise in the first evaluator also costs the session its remaining
    # two evaluators AND its stamp, which would then make it due again immediately.
    # Keeping the boundary here preserves what the three separate jobs gave for free.
    def run_evaluator(session, name)
      yield
    rescue => e
      Rails.logger.error "[Github::PrPollPass] #{name} failed for session #{session.id}: #{e.class} - #{e.message}"
    end
  end
end
