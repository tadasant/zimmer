require "test_helper"
require "mocha/minitest"

class Github::MergeConflictEvaluatorTest < ActiveSupport::TestCase
  PR_URL = "https://github.com/owner/repo/pull/456".freeze

  setup do
    @session_with_pr = sessions(:with_pr_url_and_status)
  end

  test "evaluate only suspects (does not notify) on the first conflicting poll" do
    track(PR_URL)

    evaluate(@session_with_pr, :conflicting)

    @session_with_pr.reload
    # First conflicting reading marks the PR suspected, NOT confirmed. The
    # confirmed-conflicts key is never written because nothing was confirmed.
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"]
    # The marker records WHEN, not just THAT: the debounce is a duration, so the
    # gap to the confirming reading has to be measurable from the marker itself.
    suspected = @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"]
    assert_equal [ PR_URL ], suspected.keys
    assert_in_delta Time.current, Time.zone.parse(suspected[PR_URL]), 5.seconds

    # No notification yet — a single (possibly stale/transient) reading must not nudge.
    refute @session_with_pr.logs.where("content LIKE ?", "%Merge conflict detected%").exists?,
      "Should not notify on the first conflicting poll"
    refute @session_with_pr.enqueued_messages.pending.exists?,
      "Should not enqueue a message on the first conflicting poll"
  end

  test "evaluate confirms and notifies on a conflicting poll a debounce interval later" do
    track(PR_URL, status: :running)

    evaluate(@session_with_pr, :conflicting) # first poll: suspect
    evaluate_later(@session_with_pr, :conflicting) # a gap later: confirm + notify

    @session_with_pr.reload
    # Promoted to confirmed, suspected marker cleared.
    assert_equal({ PR_URL => true }, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"])
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"])

    # Now the message is enqueued.
    assert @session_with_pr.logs.where("content LIKE ?", "%Merge conflict detected%").exists?,
      "Expected a log entry about merge conflict detection after the second poll"
    assert @session_with_pr.enqueued_messages.pending.exists?,
      "Expected a pending enqueued message after the second poll"
  end

  test "evaluate never notifies for a transient conflicting reading (conflict then clean)" do
    track(PR_URL)

    # GitHub returns a stale/transient CONFLICTING on the first poll, then the real
    # (clean) state on the next poll.
    evaluate(@session_with_pr, :conflicting) # suspect
    evaluate_later(@session_with_pr, :clean) # clean → clears suspicion

    @session_with_pr.reload
    # Confirmed-conflicts key was never written (nothing confirmed); the
    # suspected marker set on the first poll is cleared by the clean read.
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"]
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"])
    refute @session_with_pr.logs.where("content LIKE ?", "%Merge conflict detected%").exists?,
      "A transient conflicting reading must never produce a conflict notification"
    refute @session_with_pr.enqueued_messages.pending.exists?,
      "A transient conflicting reading must never enqueue a message"
  end

  test "evaluate does not re-notify for already known conflicts" do
    track(PR_URL, extra: { "github_pull_request_merge_conflicts" => { PR_URL => true } })

    initial_log_count = @session_with_pr.logs.count

    evaluate(@session_with_pr, :conflicting)

    @session_with_pr.reload
    assert_equal initial_log_count, @session_with_pr.logs.count,
      "Should not create new logs for already-known conflicts"
  end

  test "evaluate clears conflict when PR becomes mergeable" do
    track(PR_URL, extra: { "github_pull_request_merge_conflicts" => { PR_URL => true } })

    evaluate(@session_with_pr, :clean)

    @session_with_pr.reload
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"])
  end

  test "evaluate clears both confirmed and suspected markers on a clean read" do
    track(PR_URL, extra: {
      "github_pull_request_merge_conflicts" => { PR_URL => true },
      "github_pull_request_merge_conflicts_suspected" => { PR_URL => true }
    })

    evaluate(@session_with_pr, :clean)

    @session_with_pr.reload
    # A clean read must clear BOTH markers, not just one.
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"])
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"])
  end

  # The open-PR check now reads the pass's own snapshot rather than the status the PR
  # poller had stored on a previous tick. Same decision, one tick fresher.
  test "evaluate skips non-open PRs" do
    track(PR_URL, extra: { "github_pull_request_merge_conflicts" => { PR_URL => true } })

    evaluate(@session_with_pr, :conflicting, state: "MERGED")

    @session_with_pr.reload
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"])
  end

  test "evaluate clears a suspected marker when the PR is no longer open" do
    track(PR_URL, extra: { "github_pull_request_merge_conflicts_suspected" => { PR_URL => true } })

    evaluate(@session_with_pr, :conflicting, state: "MERGED")

    @session_with_pr.reload
    # A merged/closed PR can't have actionable conflicts, so a lingering
    # suspected marker must be cleared (and never promoted to confirmed).
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"])
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"]
  end

  test "evaluate does not update when conflicts unchanged" do
    track(PR_URL, extra: { "github_pull_request_merge_conflicts" => { PR_URL => true } })

    original_updated_at = @session_with_pr.updated_at

    evaluate(@session_with_pr, :conflicting)

    @session_with_pr.reload
    assert_equal original_updated_at, @session_with_pr.updated_at
  end

  test "evaluate skips a PR whose mergeability GitHub has not computed yet" do
    track(PR_URL)

    evaluate(@session_with_pr, :uncomputed)

    @session_with_pr.reload
    # UNKNOWN is not a reading. Nothing is suspected, nothing is confirmed.
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"]
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"]
  end

  # ---- a PR the pass could not read at all ----
  #
  # This is the case the evaluator used to answer from the PR poller's stored status:
  # with no snapshot there is no status AND no mergeability, so neither marker may move.
  # In particular it must not be read as "not open" and clear a real confirmed conflict.

  test "evaluate leaves both markers alone when the PR could not be read" do
    track(PR_URL, extra: {
      "github_pull_request_merge_conflicts" => { PR_URL => true },
      "github_pull_request_merge_conflicts_suspected" => { PR_URL => true }
    })

    original_updated_at = @session_with_pr.updated_at

    evaluate(@session_with_pr, :no_reading)

    @session_with_pr.reload
    assert_equal({ PR_URL => true }, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"])
    assert_equal({ PR_URL => true }, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"])
    assert_equal original_updated_at, @session_with_pr.updated_at
  end

  test "a mergeability reading that never arrived records no conflict and enqueues no notice" do
    track(PR_URL, status: :running)

    evaluate(@session_with_pr, :no_reading)

    @session_with_pr.reload
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"]
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"]
    assert_equal 0, @session_with_pr.enqueued_messages.count
  end

  # ---- delivery ----

  test "enqueue_merge_conflict_message sends immediately when session needs_input" do
    track(PR_URL, status: :needs_input)

    AgentSessionJob.stubs(:enqueue_with_prompt)

    Github::MergeConflictEvaluator.new.send(:enqueue_merge_conflict_message, @session_with_pr, PR_URL)

    @session_with_pr.reload
    # Delivered: the session left `needs_input` and its turn queued for a worker.
    assert_equal "waiting", @session_with_pr.status
    assert @session_with_pr.logs.where("content LIKE ?", "%sent immediately%").exists?
  end

  test "enqueue_merge_conflict_message enqueues for later when session is running" do
    track(PR_URL, status: :running)

    Github::MergeConflictEvaluator.new.send(:enqueue_merge_conflict_message, @session_with_pr, PR_URL)

    @session_with_pr.reload
    assert @session_with_pr.enqueued_messages.pending.exists?,
      "Expected a pending enqueued message"
    assert_match(/merge conflict/i, @session_with_pr.enqueued_messages.pending.first.content)
    assert @session_with_pr.logs.where("content LIKE ?", "%enqueued%").exists?
  end

  test "automated message includes PR URL" do
    message = AutomatedPrompts.merge_conflict_message(PR_URL)

    assert_includes message, PR_URL
    assert_includes message, "[AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]"
    assert_includes message, "merge conflicts"
  end

  # Stamped like the merged-PR notice, and deliberately NOT archive-satisfied:
  # a PR left unmergeable stays unmergeable after the archive, and the strand
  # alert is the only thing that says so.
  test "a queued merge-conflict notice is stamped with its origin and still alerts" do
    session = sessions(:with_pr_url)
    session.update!(status: :running)

    Github::MergeConflictEvaluator.new.send(
      :enqueue_merge_conflict_message, session, "https://github.com/owner/repo/pull/1"
    )

    message = session.enqueued_messages.sole
    assert_equal "automated_merge_conflict", message.origin
  end

  # A conflict that stays unresolved is reported ONCE, however many polls see it.
  #
  # The re-fire half of #214: session 460 was told three times about merge conflicts
  # on one PR. Dedup lives in the confirmed marker, and nothing but a clean reading
  # clears it — behaviour that already holds, pinned here over more polls than the
  # report saw rather than changed.
  test "a persistent conflict notifies once, not once per poll" do
    track(PR_URL)

    evaluate(@session_with_pr, :conflicting)
    5.times { evaluate_later(@session_with_pr, :conflicting) }

    assert_equal 1, @session_with_pr.reload.enqueued_messages.where(origin: "automated_merge_conflict").count,
      "one unresolved conflict is one notice"
    assert_equal 1, @session_with_pr.logs.where("content LIKE ?", "%Merge conflict detected%").count
  end

  # ---- the debounce is a DURATION, not a poll count (#1123) ----
  #
  # "Two consecutive polls" is only two minutes if whatever supplies the cadence
  # actually ticks every two minutes. Github::PrPollPass caps an idle PR-holding
  # session at 30 minutes and the evaluator's own gate rode PollBackoff's curve to
  # its 24-hour floor, so for exactly the population a conflict notice is for the
  # two readings were half an hour or a day apart. Stating the gap in seconds here
  # is what makes the interval true at any cadence.

  test "two conflicting readings inside the debounce gap do not confirm" do
    track(PR_URL, status: :running)

    evaluate(@session_with_pr, :conflicting)
    travel 30.seconds
    @session_with_pr.reload
    evaluate(@session_with_pr, :conflicting)

    @session_with_pr.reload
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"],
      "30 seconds is not the two minutes the debounce is tuned to"
    refute @session_with_pr.enqueued_messages.pending.exists?
  end

  # The failure mode a naive "re-stamp the marker every poll" would introduce: a PR
  # polled faster than the gap would restart its own debounce forever and never
  # confirm at all — #1123 inverted.
  test "a reading too soon to confirm leaves the suspicion timestamp alone" do
    track(PR_URL, status: :running)

    evaluate(@session_with_pr, :conflicting)
    first_seen = @session_with_pr.reload.custom_metadata["github_pull_request_merge_conflicts_suspected"][PR_URL]

    travel 30.seconds
    @session_with_pr.reload
    evaluate(@session_with_pr, :conflicting)

    assert_equal first_seen,
      @session_with_pr.reload.custom_metadata["github_pull_request_merge_conflicts_suspected"][PR_URL],
      "an early reading must not restart the debounce"

    # ...and the confirmation still lands a gap after the FIRST reading.
    travel (Github::MergeConflictEvaluator::MIN_CONFIRMATION_GAP_SECONDS + 1).seconds
    @session_with_pr.reload
    evaluate(@session_with_pr, :conflicting)

    assert_equal({ PR_URL => true },
      @session_with_pr.reload.custom_metadata["github_pull_request_merge_conflicts"])
  end

  # The deploy that introduces timestamps finds `true` in every suspected marker in
  # the fleet. Those were written by an earlier gated poll, so the reading in front
  # of us really is the second one: confirm on it rather than suppressing a real
  # conflict for a cycle.
  test "a legacy boolean suspected marker still confirms" do
    track(PR_URL, status: :running,
      extra: { "github_pull_request_merge_conflicts_suspected" => { PR_URL => true } })

    evaluate(@session_with_pr, :conflicting)

    @session_with_pr.reload
    assert_equal({ PR_URL => true }, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"])
    assert @session_with_pr.enqueued_messages.pending.exists?
  end

  # ---- .fresh_suspicion?, which is what buys the confirming poll its cadence ----

  test "fresh_suspicion? is true for a suspicion inside the window" do
    track(PR_URL, extra: {
      "github_pull_request_merge_conflicts_suspected" => { PR_URL => 1.minute.ago.utc.iso8601 }
    })

    assert Github::MergeConflictEvaluator.fresh_suspicion?(@session_with_pr)
  end

  test "fresh_suspicion? lapses past SUSPICION_FAST_POLL_WINDOW" do
    stale = (Github::MergeConflictEvaluator::SUSPICION_FAST_POLL_WINDOW + 1.minute).ago.utc.iso8601
    track(PR_URL, extra: { "github_pull_request_merge_conflicts_suspected" => { PR_URL => stale } })

    refute Github::MergeConflictEvaluator.fresh_suspicion?(@session_with_pr),
      "a suspicion nothing ever resolves must not pin a session at two-minute polling"
  end

  # The opposite fail-safe from #confirmable?, and deliberately so: an unknown age
  # may buy one PR a confirmation, but it must not buy the fleet a fast cadence
  # with no bound on it.
  test "fresh_suspicion? is false for a marker with no readable timestamp" do
    track(PR_URL, extra: { "github_pull_request_merge_conflicts_suspected" => { PR_URL => true } })
    refute Github::MergeConflictEvaluator.fresh_suspicion?(@session_with_pr)

    track(PR_URL, extra: { "github_pull_request_merge_conflicts_suspected" => { PR_URL => "not a time" } })
    refute Github::MergeConflictEvaluator.fresh_suspicion?(@session_with_pr)
  end

  test "fresh_suspicion? is false when nothing is suspected" do
    track(PR_URL)

    refute Github::MergeConflictEvaluator.fresh_suspicion?(@session_with_pr)
  end

  private

  def track(pr_url, status: nil, extra: {})
    @session_with_pr.update!(
      **(status ? { status: status } : {}),
      custom_metadata: { "github_pull_request_urls" => [ pr_url ] }.merge(extra)
    )
  end

  # Run the evaluator over a session's tracked PRs with one shared reading.
  #
  # `reading` is what this pass's `gh pr view` came back with:
  #   :conflicting  — MergeableState CONFLICTING
  #   :clean        — MergeableState MERGEABLE
  #   :uncomputed   — MergeableState UNKNOWN, GitHub still computing
  #   :no_reading   — the call did not complete, so the pass hands over no snapshot
  def evaluate(session, reading, state: "OPEN")
    refs = Github::PrRef.for_session(session)
    snapshots = refs.to_h { |pr_ref| [ pr_ref.url, snapshot_for(pr_ref, reading, state) ] }
    Github::MergeConflictEvaluator.new.evaluate(session, refs, snapshots)
  end

  # A later gated poll: far enough after the previous reading for the debounce's
  # MIN_CONFIRMATION_GAP_SECONDS to have elapsed. `travel` without a block
  # accumulates, so repeated calls walk the clock forward one gap at a time.
  def evaluate_later(session, reading, state: "OPEN")
    travel (Github::MergeConflictEvaluator::MIN_CONFIRMATION_GAP_SECONDS + 1).seconds
    session.reload
    evaluate(session, reading, state: state)
  end

  def snapshot_for(pr_ref, reading, state)
    return nil if reading == :no_reading

    mergeable = case reading
    when :conflicting then "CONFLICTING"
    when :clean then "MERGEABLE"
    when :uncomputed then "UNKNOWN"
    else raise ArgumentError, "unknown reading #{reading.inspect}"
    end

    Github::PrSnapshot.new(
      ref: pr_ref,
      state: state,
      merged_at: state == "MERGED" ? "2025-01-01T12:00:00Z" : nil,
      mergeable: mergeable
    )
  end
end
