# frozen_string_literal: true

module Github
  # Decides, from a pass's reading of each tracked PR, which of them have a merge
  # conflict the session should be told to resolve.
  #
  # Driven by Github::PrPollPass, which owns the enumeration, the backoff gate and the
  # single `gh pr view` this evaluator reads. It takes no GitHub calls of its own: the
  # mergeability it used to fetch from `gh api repos/O/R/pulls/N --jq .mergeable` is a
  # field on the snapshot the pass already has.
  #
  # Tracks merge conflict status in custom_metadata across two keys:
  #   github_pull_request_merge_conflicts           => confirmed (already notified),
  #                                                    { pr_url => true }
  #   github_pull_request_merge_conflicts_suspected => seen conflicting, not yet
  #                                                    confirmed, { pr_url => iso8601 }
  #
  # Two-reading confirmation (debounce): a PR must read conflicting twice, at least
  # MIN_CONFIRMATION_GAP_SECONDS apart, before we notify the session. The first
  # conflicting read records the PR as "suspected" and WHEN; a later conflicting read
  # far enough after that promotes it to "confirmed" and enqueues the automated
  # resolve-conflicts message. Any clean read clears both markers.
  #
  # This filters GitHub's stale/transient conflicting readings, which are common in the
  # seconds-to-minute after a push or force-push while GitHub recomputes mergeability —
  # without debounce, a single stale reading enqueues a "resolve merge conflicts" nudge
  # against a PR that is actually clean, burning the session's turn (see sessions 7235
  # and 3889). The cost is up to one extra poll interval of latency before a genuine,
  # persistent conflict is reported.
  #
  # THE DEBOUNCE IS A DURATION, NOT A POLL COUNT, and that is the fix for
  # tadasant/zimmer#1123. It used to mean "two consecutive gated polls", which is only
  # two minutes if the gate that supplies the cadence actually ticks every two minutes.
  # It does not for the population this evaluator exists to serve: Github::PrPollPass
  # caps a session holding an unresolved PR at AWAITING_PR_OUTCOME_MAX_POLL_INTERVAL
  # (30 minutes), and past 24 hours of no user activity this evaluator's own gate rode
  # PollBackoff's curve all the way to its 24-hour floor. "Two consecutive polls" was
  # therefore half an hour or a day apart for exactly the idle PR-holding sessions the
  # conflict notice is for, and any single clean reading in between — a stale MERGEABLE
  # is the reading GitHub's lazily-recomputed mergeability produces — reset the streak
  # to zero. A PR open since 2026-09-06 was still un-notified five days later, and a
  # human flagged the conflict by hand.
  #
  # Measuring the gap in seconds makes the debounce say what its own comment always
  # claimed. The other half of the fix is in Github::PrPollPass: a session with a fresh
  # suspicion is polled at MERGE_CONFLICT_INTERVAL_SECONDS so the confirming reading
  # lands on the cadence this was tuned for rather than whenever the curve next allows.
  #
  class MergeConflictEvaluator
    include DatabaseRetry
    include AutomatedSessionMessage

    # The two custom_metadata keys this evaluator's debounce lives in. Named so the one
    # other place that has to touch them — .forget_conflict!, below — cannot drift
    # from the poll body that writes them.
    CONFIRMED_METADATA_KEY = "github_pull_request_merge_conflicts"
    SUSPECTED_METADATA_KEY = "github_pull_request_merge_conflicts_suspected"

    # How long a suspicion must stand before a second conflicting reading may
    # confirm it. The debounce interval, stated as the duration it always claimed
    # to be rather than as a count of polls whose spacing lives in another class.
    #
    # Two minutes is the cron cadence the debounce was originally tuned against,
    # unchanged. What changes is that it is now enforced here: an evaluator run at
    # any cadence — 30 seconds, 30 minutes, a day — confirms on the first
    # conflicting reading at least this long after the first, and never sooner.
    MIN_CONFIRMATION_GAP_SECONDS = 120

    # How long a suspicion entitles its session to the fast poll cadence
    # Github::PrPollPass grants it.
    #
    # A suspicion normally lasts exactly one gated evaluation: the next conflicting
    # reading confirms it, the next clean one clears it. The window bounds the case
    # that does neither — Github::PrSnapshot.fetch returning nil on every tick for a
    # deleted PR or a repo the token cannot read, which leaves the marker standing
    # with nothing to resolve it. Without a bound that session would poll every two
    # minutes for the rest of its life, which is the pressure
    # AWAITING_PR_OUTCOME_MAX_IDLE exists to keep out of the fleet. Past the window
    # the session falls back to its ordinary cadence and the suspicion is still
    # confirmable — later, not never.
    SUSPICION_FAST_POLL_WINDOW = 30.minutes

    # When a suspected conflict was first seen, or nil if the marker cannot say.
    #
    # Nil covers two cases and both are deliberately the same answer. A marker
    # written before this key held timestamps reads `true`, and one whose value will
    # not parse reads as nothing — in both, the suspicion is real and its age is
    # unknown. #confirmable? and .fresh_suspicion? then take opposite fail-safe
    # directions on it, which is the whole reason this returns nil rather than
    # guessing a time. See each of them.
    #
    # @param value [Object] one value out of the suspected-markers hash
    # @return [ActiveSupport::TimeWithZone, nil]
    def self.suspected_since(value)
      return nil if value.blank? || value == true

      Time.zone.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    # Whether +session+ holds a suspicion young enough to be worth polling fast for.
    #
    # Github::PrPollPass asks this to decide whether to cap the session's interval at
    # the debounce's own cadence, so the confirming reading lands two minutes after
    # the first rather than whenever PollBackoff's curve next allows. That is the
    # half of tadasant/zimmer#1123 that made a genuine conflict unreportable: the
    # confirming poll was half an hour or a day away, and a single clean reading in
    # between reset the streak.
    #
    # A marker with no readable timestamp is NOT fresh. The fail-safe direction here
    # is the opposite of #confirmable?'s, and on purpose: an unknown age must not
    # grant an unbounded fast cadence to the fleet, while it may grant a
    # confirmation to one PR that has already been suspected at least a poll.
    #
    # @param session [Session]
    # @param now [Time]
    # @return [Boolean]
    def self.fresh_suspicion?(session, now: Time.current)
      suspected = session.custom_metadata&.dig(SUSPECTED_METADATA_KEY)
      return false unless suspected.is_a?(Hash)

      suspected.any? do |_pr_url, value|
        since = suspected_since(value)
        since.present? && now - since <= SUSPICION_FAST_POLL_WINDOW
      end
    rescue StandardError => e
      # Never worth failing a whole pass over. Answering "no" leaves the session on
      # its ordinary cadence, which is what it had before this existed.
      Rails.logger.warn(
        "[Github::MergeConflictEvaluator] Could not read the suspicion age for session " \
        "#{session&.id}: #{e.class}: #{e.message}"
      )
      false
    end

    # Forget everything the debounce remembers about one PR, so the next poll
    # re-derives its conflict state from scratch.
    #
    # Exists for exactly one caller: the delivery-time re-validation that retires a
    # conflict notice whose PR now reads mergeable (EnqueuedMessage#stale?). By the
    # time that happens this evaluator has already recorded the PR as confirmed, and the
    # confirmed marker is what makes #evaluate skip it — cleared only by a CLEAN
    # reading. So without this call a suppression would be permanent: if the
    # `mergeable == true` that justified it was itself one of the stale readings the
    # two-poll debounce exists because GitHub produces, the PR is still conflicting,
    # every later poll takes the "already notified" branch, and the session is never
    # told. That is the silent, strictly-worse failure the guard is supposed to avoid,
    # reintroduced by the guard.
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
      Rails.logger.info "[Github::MergeConflictEvaluator] Cleared conflict markers for #{pr_url} on session " \
        "#{session.id} so the next poll re-derives them"
    end

    # @param session [Session]
    # @param refs [Array<Github::PrRef>] the session's tracked PRs, already resolved
    # @param snapshots [Hash{String => Github::PrSnapshot, nil}] this pass's reading of
    #   each PR, keyed by url. A nil value is "we could not ask about this one".
    # @return [void]
    def evaluate(session, refs, snapshots)
      return if refs.empty?

      # One reading of the clock for the whole pass, so every PR on this session is
      # judged against the same instant.
      now = Time.current
      current_conflicts = session.custom_metadata&.dig(CONFIRMED_METADATA_KEY) || {}
      current_suspected = session.custom_metadata&.dig(SUSPECTED_METADATA_KEY) || {}
      updated_conflicts = current_conflicts.dup
      updated_suspected = current_suspected.dup
      newly_conflicting_prs = []

      refs.each do |ref|
        pr_url = ref.url
        snapshot = snapshots[pr_url]

        # No reading this tick — not "clean", not "conflicting". Leave both markers
        # alone and ask again on the next gated poll. This is also where a PR whose
        # status could not be established lands, which is why the open-PR check below
        # can read the snapshot rather than the status the PR poller stored.
        next if snapshot.nil?

        # Only check open PRs — merged/closed PRs can't have actionable conflicts
        unless snapshot.status == "open"
          # Clear conflict status for non-open PRs
          updated_conflicts.delete(pr_url)
          updated_suspected.delete(pr_url)
          next
        end

        has_conflict = snapshot.conflicting?

        # nil means GitHub has not computed mergeability yet — skip this PR
        next if has_conflict.nil?

        if has_conflict
          if updated_conflicts[pr_url] == true
            # Already confirmed + notified — nothing to do.
          elsif current_suspected.key?(pr_url)
            if confirmable?(current_suspected[pr_url], now)
              # Conflict seen before AND still present now, far enough apart to rule
              # out GitHub's stale/transient conflicting reading (e.g. right after a
              # push, before recomputation) — confirm it and notify.
              updated_conflicts[pr_url] = true
              updated_suspected.delete(pr_url)
              newly_conflicting_prs << pr_url
            end
            # Still suspected but too soon to confirm: leave the marker EXACTLY as it
            # is. Re-stamping it with `now` would restart the debounce on every poll,
            # so a PR polled faster than the gap would never confirm at all — the
            # defect this whole change is about, inverted.
          else
            # First conflicting reading — suspect only, do NOT notify yet, and record
            # WHEN so the gap to the confirming reading is measurable. If a later
            # reading still says conflicting it gets confirmed above; if it reads
            # clean (the transient/stale case) the marker is cleared below.
            updated_suspected[pr_url] = now.utc.iso8601
          end
        else
          # PR is clean — clear both the confirmed and suspected markers.
          updated_conflicts.delete(pr_url)
          updated_suspected.delete(pr_url)
        end
      end

      # Enqueue automated messages for newly conflicting PRs BEFORE updating metadata.
      # This ensures at-least-once delivery: if the pass crashes after sending but before
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
        # reload to narrow: keys other writers touched during this pass survive.
        with_db_retry { session.merge_custom_metadata!(metadata_updates) }
        Rails.logger.info "[Github::MergeConflictEvaluator] Updated merge conflict statuses for session #{session.id}: confirmed=#{updated_conflicts} suspected=#{updated_suspected}"
      end
    end

    private

    # Whether a standing suspicion is old enough for a conflicting reading to
    # confirm it.
    #
    # A marker with no readable timestamp answers TRUE, which is the opposite
    # fail-safe from .fresh_suspicion? and is the right way round here. Every such
    # marker was written by an earlier gated evaluation — the legacy `true` shape, or
    # a value that will not parse — so the reading in front of us is genuinely the
    # second one, and the gap is at least whatever the gate was. Refusing to confirm
    # on it would suppress the notice for a real conflict, which is the failure this
    # evaluator exists to prevent; confirming costs at worst the transient nudge the
    # debounce is there to filter, once, on the deploy that introduces timestamps.
    def confirmable?(suspected_value, now)
      since = self.class.suspected_since(suspected_value)
      return true if since.nil?

      now - since >= MIN_CONFIRMATION_GAP_SECONDS
    end

    # Delivery itself — immediate when the session is parked in needs_input, queued
    # behind the current turn otherwise — lives in AutomatedSessionMessage, shared
    # with the merged-PR message the PR status evaluator sends.
    def enqueue_merge_conflict_message(session, pr_url)
      deliver_automated_message(
        session,
        AutomatedPrompts.merge_conflict_message(pr_url),
        event_description: "Merge conflict detected on #{pr_url}",
        origin: "automated_merge_conflict"
      )
    end
  end
end
