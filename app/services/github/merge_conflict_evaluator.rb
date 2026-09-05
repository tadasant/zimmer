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
  #   github_pull_request_merge_conflicts           => confirmed (already notified)
  #   github_pull_request_merge_conflicts_suspected => seen conflicting on the
  #                                                    most recent poll only
  # Both are hashes of { "https://github.com/owner/repo/pull/123" => true, ... }.
  #
  # Two-poll confirmation (debounce): a PR must read conflicting on TWO CONSECUTIVE
  # polls before we notify the session. The first conflicting read only marks the PR
  # "suspected"; the second promotes it to "confirmed" and enqueues the automated
  # resolve-conflicts message. Any clean read clears both markers.
  #
  # This filters GitHub's stale/transient conflicting readings, which are common in the
  # seconds-to-minute after a push or force-push while GitHub recomputes mergeability —
  # without debounce, a single stale reading enqueues a "resolve merge conflicts" nudge
  # against a PR that is actually clean, burning the session's turn (see sessions 7235
  # and 3889). The cost is up to one extra poll interval of latency before a genuine,
  # persistent conflict is reported.
  #
  # THE DEBOUNCE INTERVAL IS STILL TWO MINUTES. The pass ticks every 30 seconds, which
  # would shorten the gap between the two readings to a quarter of what the debounce was
  # tuned for — so Github::PrPollPass gates this evaluator on its own 2-minute interval
  # inside the pass. "Two consecutive polls" means two consecutive *gated* polls, which
  # is the same four minutes it has always been.
  #
  class MergeConflictEvaluator
    include DatabaseRetry
    include AutomatedSessionMessage

    # The two custom_metadata keys this evaluator's debounce lives in. Named so the one
    # other place that has to touch them — .forget_conflict!, below — cannot drift
    # from the poll body that writes them.
    CONFIRMED_METADATA_KEY = "github_pull_request_merge_conflicts"
    SUSPECTED_METADATA_KEY = "github_pull_request_merge_conflicts_suspected"

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
          elsif current_suspected[pr_url] == true
            # Conflict seen on the previous poll AND still present now — confirm it
            # and notify. Two consecutive readings rule out GitHub's stale/transient
            # conflicting reading (e.g. right after a push, before recomputation).
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
