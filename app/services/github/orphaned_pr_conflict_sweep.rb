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
  #   * Only sessions that ended within WATCH_WINDOW, and after WATCHED_SINCE. A PR
  #     whose producer ended longer ago than that is not this sweep's to revive.
  #   * One revival per conflict episode. The confirmed marker records the head it
  #     was confirmed on and is cleared by a clean reading or a new head, so a
  #     revived session that archives again without touching the PR is not revived
  #     a second time for the same conflict.
  #   * At most MAX_REVIVALS_PER_RUN revivals per run, so a burst of them cannot
  #     hold a `:pollers` thread for a dozen re-clones.
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

    # Producers that ended before this are never watched.
    #
    # Without a cutover, the first deploy would read every producer that ended in
    # the week before it and revive, within minutes, each one whose PR conflicts —
    # including PRs abandoned on purpose while nothing could have revived them.
    # The sweep only promises to watch producers that ended after it existed.
    WATCHED_SINCE = Time.utc(2026, 10, 16).freeze

    # WATCHED_SINCE, as a method so a test can move the cutover.
    def self.watched_since
      WATCHED_SINCE
    end

    # How often one ended producer's PRs are read when nothing is suspected.
    #
    # Every reading is a `gh pr view` plus a REST mergeability read. Fifteen
    # minutes keeps that to eight calls an hour per watched PR, and the population
    # is small: a terminal reading removes a PR from it on the first read.
    POLL_INTERVAL = 15.minutes.to_i

    # Slack under each interval. The poll stamp is written after the session's
    # `gh` calls, so a session read on one tick is a few seconds short of due on
    # the tick an interval later — and without this would be read on the tick
    # after that, doubling every interval.
    DUE_SLACK_SECONDS = 30

    POLL_BACKOFF_KEY = "github_orphaned_pr_conflict_sweep"

    # How many times this sweep may revive one session for one PR.
    MAX_REVIVALS_PER_PR = 3
    REVIVALS_METADATA_KEY = "github_pull_request_conflict_revivals"

    # How many sessions one run may bring back. A revival re-clones a repository,
    # serially, on a `:pollers` thread shared with every other periodic job; the
    # rest stay suspected and are revived on the next runs.
    MAX_REVIVALS_PER_RUN = 2

    # Raised by #revive_and_notify when this run has spent its revivals. Aborts
    # the evaluation before it writes anything, so the suspicion stands.
    class RevivalDeferred < StandardError; end

    # The columns a sweep reads. Everything but the transcript, which can be
    # megabytes and is needed only by a revival, which re-reads the row whole.
    def self.swept_columns
      Session.column_names - %w[transcript]
    end

    # Sessions this sweep may watch: archived or failed, with PR urls recorded.
    #
    # A deliberately loose SQL bound; #watched? applies the exact window in Ruby.
    # `updated_at` is never earlier than the end of a session, so the bound is a
    # superset, and it needs no cast of a stamp out of `metadata` — one malformed
    # value there would otherwise fail the query for the whole fleet.
    def self.candidates(now: Time.current)
      Session.where(status: %w[archived failed])
        .where("custom_metadata->>'github_pull_request_urls' IS NOT NULL")
        .where("COALESCE(archived_at, updated_at) >= ?", [ now - WATCH_WINDOW, watched_since ].max)
        .select(swept_columns)
    end

    # Whether +session+ ended inside the window.
    #
    # Measured from `archived_at`. A failed session has no failure timestamp, and
    # `updated_at` moves with every write this sweep makes, so a failed one is
    # measured from its last human activity (Session#last_user_activity_at, which
    # falls back to `created_at`).
    def self.watched?(session, now: Time.current)
      ended = session.archived_at || session.last_user_activity_at
      ended.present? && ended >= now - WATCH_WINDOW && ended >= watched_since
    end

    def initialize
      @revivals_this_run = 0
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
      return unless self.class.watched?(session)
      return if session.status_summary_fork?
      return unless due?(session)

      # The batch row may be minutes old by now; the debounce markers must not be.
      session = Session.select(self.class.swept_columns).find(session.id)
      return unless session.archived? || session.failed?

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
      rescue RevivalDeferred
        Rails.logger.info "[Github::OrphanedPrConflictSweep] Deferred reviving session #{session.id}: " \
          "this run has revived #{MAX_REVIVALS_PER_RUN} already"
      ensure
        stamp_poll(session)
      end
    end

    # Bring +session+ back and tell it +pr_url+ conflicts.
    #
    # Called by Reviver at the moment the debounce confirms a conflict. The PR is
    # marked notified BEFORE the session is brought back: from the moment the
    # session is live, Github::PrPollPass sees it, and a marker written only at the
    # end of the evaluation would let the pass confirm the same suspicion and send
    # a second notice. A revival that fails takes the marker back off and raises,
    # so the suspicion stands and the next sweep tries again, up to
    # MAX_REVIVALS_PER_PR.
    #
    # @param session [Session]
    # @param pr_url [String]
    # @param head_sha [String, nil] the head the conflict was read on
    # @return [void]
    def revive_and_notify(session, pr_url, head_sha)
      session = Session.find(session.id)
      marker = head_sha || true

      # Already live: revived a moment ago for another of its PRs in this same
      # evaluation, or brought back by someone else. If the live pass has not
      # already told it about this head, tell it here — the evaluator is about to
      # mark it notified, so nothing else will.
      unless session.archived? || session.failed?
        return if notified?(session, pr_url, head_sha)

        mark_notified!(session, pr_url, marker)
        delivered = deliver_automated_message(
          session, AutomatedPrompts.merge_conflict_message(pr_url),
          event_description: "Merge conflict detected on #{pr_url}", origin: "automated_merge_conflict"
        )
        unless delivered
          unmark_notified!(session, pr_url)
          raise "could not deliver the conflict notice to session #{session.id}"
        end
        return
      end

      skip = skip_revival_reason(session, pr_url)
      if skip
        # Recorded as handled by the evaluator, deliberately: every reason here is
        # permanent, so retrying it on every sweep would only repeat the skip.
        Rails.logger.info "[Github::OrphanedPrConflictSweep] Not reviving session #{session.id} for #{pr_url}: #{skip}"
        return
      end

      raise RevivalDeferred if @revivals_this_run >= MAX_REVIVALS_PER_RUN

      @revivals_this_run += 1
      from_status = session.status
      count_revival!(session, pr_url)
      mark_notified!(session, pr_url, marker)
      prompt = AutomatedPrompts.merge_conflict_revival_message(pr_url, from_status: from_status)
      event = "Merge conflict detected on #{pr_url} while this session was #{from_status}"

      begin
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
      rescue
        unmark_notified!(session, pr_url)
        raise
      end
    end

    private

    def due?(session)
      interval = MergeConflictEvaluator.fresh_suspicion?(session) ? PrPollPass::MERGE_CONFLICT_INTERVAL_SECONDS : POLL_INTERVAL
      interval -= DUE_SLACK_SECONDS
      PollBackoff.should_poll?(
        session,
        job_key: POLL_BACKOFF_KEY,
        base_interval: interval,
        min_interval: interval,
        max_interval: interval
      )
    end

    # Never lets a failed stamp replace the error that is already on its way out.
    def stamp_poll(session)
      PollBackoff.record_poll!(session, job_key: POLL_BACKOFF_KEY)
    rescue => e
      Rails.logger.error "[Github::OrphanedPrConflictSweep] Could not stamp the poll on session #{session.id}: " \
        "#{e.class}: #{e.message}"
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
    #
    # A session with no runtime session id has no conversation to resume:
    # UnarchiveSessionService refuses it, and a follow-up into it would be
    # reclassified as a fresh start.
    def skip_revival_reason(session, pr_url)
      return "it has no runtime session to resume" if session.session_id.blank?

      replacement = session.replacement_sessions.pick(:id)
      return "it was replaced by session #{replacement}" if replacement

      newer = Session.where("custom_metadata->'github_pull_request_urls' @> ?::jsonb", [ pr_url ].to_json)
        .where("id > ?", session.id)
        .pick(:id)
      return "session #{newer} tracks the same PR and is newer" if newer

      nil
    end

    def notified?(session, pr_url, head_sha)
      marker = session.custom_metadata&.dig(MergeConflictEvaluator::CONFIRMED_METADATA_KEY, pr_url)
      return false if marker.nil?

      marker == true || head_sha.blank? || marker == head_sha
    end

    def mark_notified!(session, pr_url, marker)
      confirmed = (session.custom_metadata&.dig(MergeConflictEvaluator::CONFIRMED_METADATA_KEY) || {}).merge(pr_url => marker)
      with_db_retry { session.merge_custom_metadata!(MergeConflictEvaluator::CONFIRMED_METADATA_KEY => confirmed) }
    end

    def unmark_notified!(session, pr_url)
      fresh = Session.find(session.id)
      confirmed = fresh.custom_metadata&.dig(MergeConflictEvaluator::CONFIRMED_METADATA_KEY) || {}
      return unless confirmed.key?(pr_url)

      with_db_retry { fresh.merge_custom_metadata!(MergeConflictEvaluator::CONFIRMED_METADATA_KEY => confirmed.except(pr_url)) }
    rescue => e
      Rails.logger.error "[Github::OrphanedPrConflictSweep] Could not clear the notified marker for #{pr_url} on " \
        "session #{session.id}: #{e.class}: #{e.message}"
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

      # Keeps this evaluation's readings, so a revival can record the head it was
      # told about.
      def evaluate(session, refs, snapshots)
        @snapshots = snapshots
        super
      end

      private

      def enqueue_merge_conflict_message(session, pr_url)
        @sweep.revive_and_notify(session, pr_url, @snapshots[pr_url]&.head_sha)
      end
    end
  end
end
