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
    assert_equal({ PR_URL => true }, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"])

    # No notification yet — a single (possibly stale/transient) reading must not nudge.
    refute @session_with_pr.logs.where("content LIKE ?", "%Merge conflict detected%").exists?,
      "Should not notify on the first conflicting poll"
    refute @session_with_pr.enqueued_messages.pending.exists?,
      "Should not enqueue a message on the first conflicting poll"
  end

  test "evaluate confirms and notifies on the second consecutive conflicting poll" do
    track(PR_URL, status: :running)

    evaluate(@session_with_pr, :conflicting) # first poll: suspect
    @session_with_pr.reload
    evaluate(@session_with_pr, :conflicting) # second poll: confirm + notify

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
    @session_with_pr.reload
    evaluate(@session_with_pr, :clean) # clean → clears suspicion

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
    assert_equal "running", @session_with_pr.status
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
