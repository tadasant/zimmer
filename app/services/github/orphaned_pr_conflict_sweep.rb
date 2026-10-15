# frozen_string_literal: true

module Github
  # Watches the open pull requests whose producing session has archived or failed,
  # and brings that session back when one of them stops merging cleanly.
  #
  # WHY THIS EXISTS
  # ---------------
  # Github::PrPollPass enumerates `Session.with_github_prs`, which excludes archived
  # and failed sessions. That is right for everything else the pass does — a merged
  # notice to a session in the trash is a message nobody reads — but it leaves one
  # hole: a producer that archived while its PR was still open. That is common, not
  # exotic. A session archives when its wake budget is spent, when Zimmer never
  # recorded its PR, when a human tidies the queue, or when it simply decided it was
  # done. When `main` then moves under the PR, nothing notices until a merge gate
  # tries to merge it and finds it CONFLICTING — or a human does.
  #
  # WHAT IT DOES
  # ------------
  # For each recently-ended producer with a PR Zimmer has not seen reach a terminal
  # state, it takes the same `gh pr view` reading the pass takes and runs it through
  # MergeConflictEvaluator's two-reading debounce, unchanged. On a confirmed
  # conflict it brings the producer back — UnarchiveSessionService for an archived
  # one, a follow-up resume for a failed one — and delivers the conflict message
  # with a paragraph saying why it is running again.
  #
  # Terminal readings are recorded in `github_pull_request_statuses`, the same key
  # PrStatusEvaluator writes, so a PR that merged or closed after its producer ended
  # leaves the population on its first reading and is never fetched again.
  #
  # WHAT BOUNDS IT
  # --------------
  # Resurrecting a session is expensive (a re-clone) and visible (it takes a turn and
  # may land in the human's queue), so it is bounded several ways:
  #
  #   * Only sessions that ended within WATCH_WINDOW. A PR whose producer ended longer
  #     ago than that, and that nobody has touched since, is not this sweep's to
  #     revive.
  #   * One revival per conflict episode. The confirmed marker is cleared only by a
  #     clean reading, so a revived session that archives again without resolving the
  #     conflict is not revived a second time for it.
  #   * At most MAX_REVIVALS_PER_PR revival attempts per PR per session, ever. This
  #     is the backstop for a PR that flaps clean/conflicting, and for an unarchive
  #     that keeps failing.
  #   * Never a session that was replaced (`replaces_session`), and never when a
  #     newer session tracks the same PR. A newer session that is live is already
  #     covered by the pass; one that ended is the producer this sweep revives
  #     instead.
  #   * Each session is read at most every POLL_INTERVAL, or every
  #     PrPollPass::MERGE_CONFLICT_INTERVAL_SECONDS while a suspicion is fresh, so
  #     the confirming reading lands on the cadence the debounce was tuned for.
  class OrphanedPrConflictSweep
    include DatabaseRetry
    include AutomatedSessionMessage

    # How long after a producer ends its open PRs are still watched for conflicts.
    #
    # Matches PrPollPass::AWAITING_PR_OUTCOME_MAX_IDLE: past a week of nobody
    # touching the PR, the pass stops holding a live session's cadence too.
    WATCH_WINDOW = PrPollPass::AWAITING_PR_OUTCOME_MAX_IDLE

    # How often one ended producer's PRs are read when nothing is suspected.
    #
    # Every reading is a `gh pr view`. Fifteen minutes keeps the cost to four
    # calls an hour per watched PR, and the population is small: a terminal reading
    # removes a PR from it on the first read.
    POLL_INTERVAL = 15.minutes.to_i

    POLL_BACKOFF_KEY = "github_orphaned_pr_conflict_sweep"

    # How many times this sweep may revive one session for one PR.
    MAX_REVIVALS_PER_PR = 3
    REVIVALS_METADATA_KEY = "github_pull_request_conflict_revivals"

    # Sessions this sweep watches: ended within the window, with PR urls recorded.
    #
    # The window is measured from `archived_at` where there is one. A failed
    # session has no failure timestamp, and `updated_at` will not do — every write
    # this sweep makes bumps it, which would keep a session in the window for ever.
    # `last_user_activity_at` is the human-activity clock PrPollPass's own idle bound
    # reads, and nothing here moves it. It lives in `metadata`, so the cast is
    # guarded: one malformed value must not fail the query for the whole fleet.
    # Session#last_user_activity_at falls back to `created_at` the same way.
    def self.candidates(now: Time.current)
      Session.where(status: %w[archived failed])
        .where("custom_metadata->>'github_pull_request_urls' IS NOT NULL")
        .where(<<~SQL.squish, now - WATCH_WINDOW)
          COALESCE(
            archived_at,
            CASE WHEN metadata->>'last_user_activity_at' ~ '^\\d{4}-\\d{2}-\\d{2}T'
              THEN (metadata->>'last_user_activity_at')::timestamptz END,
            created_at
          ) >= ?
        SQL
    end

    def run
      self.class.candidates.find_each do |session|
        sweep_session(session)
      rescue => e
        Rails.logger.error "[Github::OrphanedPrConflictSweep] Error sweeping session #{session.id}: " \
          "#{e.class}: #{e.message}"
      end
    end

    # One ended producer: the gate, the reading, the debounce, and a revival on a
    # confirmed conflict.
    #
    # @param session [Session]
    # @return [void]
    def sweep_session(session)
      return if session.status_summary_fork?
      return unless due?(session)

      revivals = session.custom_metadata&.dig(REVIVALS_METADATA_KEY) || {}
      unresolved = session.unresolved_pr_urls
      refs = PrRef.for_session(session).select do |ref|
        unresolved.include?(ref.url) && revivals[ref.url].to_i < MAX_REVIVALS_PER_PR
      end

      begin
        if refs.any?
          snapshots = refs.to_h { |ref| [ ref.url, PrSnapshot.fetch(ref)&.with_rest_mergeability ] }
          record_terminal_statuses(session, snapshots)
          Reviver.new(self).evaluate(session, refs, snapshots)
        end
      ensure
        # Stamped even when a revival raised, so a failing unarchive is retried on
        # the debounce's cadence rather than on every cron tick.
        PollBackoff.record_poll!(session, job_key: POLL_BACKOFF_KEY)
      end
    end

    # Bring +session+ back and tell it +pr_url+ conflicts.
    #
    # Called by Reviver at the moment the debounce confirms a conflict. Raises when
    # the session could not be brought back, so the evaluator does not record the
    # conflict as notified: the suspicion stands and the next sweep tries again,
    # up to MAX_REVIVALS_PER_PR.
    #
    # @param session [Session]
    # @param pr_url [String]
    # @return [void]
    def revive_and_notify(session, pr_url)
      session.reload

      # Already live — revived a moment ago for another of its PRs in this same
      # evaluation, or brought back by someone else. Its own poller will not
      # announce this conflict: the evaluator is about to mark it notified. So
      # deliver it here, the ordinary way.
      unless session.archived? || session.failed?
        delivered = deliver_automated_message(
          session, AutomatedPrompts.merge_conflict_message(pr_url),
          event_description: "Merge conflict detected on #{pr_url}", origin: "automated_merge_conflict"
        )
        raise "could not deliver the conflict notice to session #{session.id}" unless delivered

        return
      end

      skip = skip_revival_reason(session, pr_url)
      if skip
        Rails.logger.info "[Github::OrphanedPrConflictSweep] Not reviving session #{session.id} for #{pr_url}: #{skip}"
        return
      end

      from_status = session.status
      count_revival!(session, pr_url)
      prompt = AutomatedPrompts.merge_conflict_revival_message(pr_url, from_status: from_status)
      event = "Merge conflict detected on #{pr_url} while this session was #{from_status}"

      if session.archived?
        result = UnarchiveSessionService.call(session: session)
        raise "could not unarchive session #{session.id}: #{result.error}" unless result.success?

        session.reload
        delivered = deliver_automated_message(
          session, prompt, event_description: "#{event} — unarchived to deliver it", origin: "automated_merge_conflict"
        )
        raise "unarchived session #{session.id} but could not deliver the conflict notice" unless delivered
      else
        resume_failed_session(session, prompt, event)
      end
    end

    private

    def due?(session)
      interval = MergeConflictEvaluator.fresh_suspicion?(session) ? PrPollPass::MERGE_CONFLICT_INTERVAL_SECONDS : POLL_INTERVAL
      PollBackoff.should_poll?(
        session,
        job_key: POLL_BACKOFF_KEY,
        base_interval: interval,
        min_interval: interval,
        max_interval: interval
      )
    end

    # Record merged and closed readings, so the PR leaves the population.
    #
    # Only terminal statuses are written. Writing "open" would be harmless but
    # pointless, and leaving CI statuses and the merged-notified marker alone keeps
    # this sweep out of PrStatusEvaluator's business: nothing announces a merge to a
    # session that has already ended.
    def record_terminal_statuses(session, snapshots)
      current = session.custom_metadata&.dig("github_pull_request_statuses") || {}
      updated = current.dup
      snapshots.each do |pr_url, snapshot|
        status = snapshot&.status
        updated[pr_url] = status if PrSnapshot::TERMINAL_STATUSES.include?(status)
      end
      return if updated == current

      with_db_retry { session.merge_custom_metadata!("github_pull_request_statuses" => updated) }
    end

    # Why this producer is not the one to bring back for +pr_url+, or nil.
    def skip_revival_reason(session, pr_url)
      return "a turn is already queued for it" if Sessions::LiveTurn.underway?(session)
      return "it has no runtime session to resume" if session.failed? && session.session_id.blank?

      replacement = Session.replacing_session(session.id).pick(:id)
      return "it was replaced by session #{replacement}" if replacement

      newer = Session.where("custom_metadata->'github_pull_request_urls' @> ?::jsonb", [ pr_url ].to_json)
        .where("id > ?", session.id)
        .pick(:id)
      return "session #{newer} tracks the same PR and is newer" if newer

      nil
    end

    def count_revival!(session, pr_url)
      revivals = (session.custom_metadata&.dig(REVIVALS_METADATA_KEY) || {}).dup
      revivals[pr_url] = revivals[pr_url].to_i + 1
      with_db_retry { session.merge_custom_metadata!(REVIVALS_METADATA_KEY => revivals) }
    end

    # A failed session has a conversation to continue but nothing that will read a
    # queue: AutomatedSessionMessage would park the notice in rows nothing drains.
    # `resume` is allowed from `failed`, so hand it the prompt directly — the same
    # path a human's follow-up to a failed session takes.
    def resume_failed_session(session, prompt, event)
      with_db_retry do
        ActiveRecord::Base.transaction do
          session.lock!
          raise "session #{session.id} left failed before it could be resumed" unless session.failed?

          session.logs.create!(content: "#{event} — resumed to deliver it", level: "info")
          session.deliver_follow_up!(prompt, clear_metadata_keys: Session::SIGTERM_RETRY_METADATA_KEYS)
        end
      end
    end

    # MergeConflictEvaluator with delivery swapped for a revival. Everything else —
    # the markers, the debounce, the clean-reading reset — is the evaluator's own.
    class Reviver < MergeConflictEvaluator
      def initialize(sweep)
        super()
        @sweep = sweep
      end

      private

      def enqueue_merge_conflict_message(session, pr_url)
        @sweep.revive_and_notify(session, pr_url)
      end
    end
  end
end
