require "test_helper"
require "mocha/minitest"

class Github::PrPollPassTest < ActiveSupport::TestCase
  PR_URL = "https://github.com/owner/repo/pull/123".freeze

  setup do
    @session_with_pr = sessions(:with_pr_url)
    @session_without_pr = sessions(:running)
  end

  # ---- the enumeration the three jobs each used to make ----

  test "Session.with_github_prs returns active sessions with PR URLs" do
    result = Session.with_github_prs

    assert_includes result.pluck(:id), @session_with_pr.id
    assert_not_includes result.pluck(:id), @session_without_pr.id
  end

  test "Session.with_github_prs excludes archived and failed sessions" do
    archived_session = sessions(:archived)
    failed_session = sessions(:failed)

    archived_session.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/a/b/pull/1" ] })
    failed_session.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/c/d/pull/2" ] })

    result_ids = Session.with_github_prs.pluck(:id)

    assert_not_includes result_ids, archived_session.id
    assert_not_includes result_ids, failed_session.id
  end

  test "run handles errors for individual sessions without stopping" do
    session1 = Session.create!(
      agent_runtime: "claude_code",
      status: :running,
      prompt: "Test 1",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      custom_metadata: { "github_pull_request_urls" => [ "https://github.com/a/b/pull/1" ] }
    )
    session2 = Session.create!(
      agent_runtime: "claude_code",
      status: :running,
      prompt: "Test 2",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      custom_metadata: { "github_pull_request_urls" => [ "https://github.com/c/d/pull/2" ] }
    )

    assert_nothing_raised { GithubPrPollPassJob.perform_now }

    session1.destroy
    session2.destroy
  end

  # ---- one fetch per PR per pass ----
  #
  # This is what #711 was about: `gh pr view` and `gh api …/pulls/N` were two round
  # trips to the same resource, thirty seconds apart, from two processes.

  test "a pass reads each PR once and hands the same snapshot to both evaluators" do
    active_session_tracking(PR_URL)
    isolate

    snapshot = Github::PrSnapshot.new(
      ref: Github::PrRef.parse(PR_URL), state: "OPEN", merged_at: nil, mergeable: "CONFLICTING"
    )
    Github::PrSnapshot.expects(:fetch).once.returns(snapshot)

    Github::PrStatusEvaluator.any_instance.expects(:evaluate)
      .with { |_s, _refs, snapshots| snapshots[PR_URL].equal?(snapshot) }
    Github::MergeConflictEvaluator.any_instance.expects(:evaluate)
      .with { |_s, _refs, snapshots| snapshots[PR_URL].equal?(snapshot) }
    Github::CommentEvaluator.any_instance.expects(:evaluate)

    Github::PrPollPass.new.run
  end

  test "a pass with no fetchable answer still hands the evaluators an entry for the PR" do
    active_session_tracking(PR_URL)
    isolate

    Github::PrSnapshot.expects(:fetch).once.returns(nil)
    Github::PrStatusEvaluator.any_instance.expects(:evaluate)
      .with { |_s, refs, snapshots| refs.map(&:url) == [ PR_URL ] && snapshots.fetch(PR_URL).nil? }
    Github::PrPollPass.new.run
  end

  # ---- one stamp per pass, not three ----

  test "a pass stamps every key it ran in a single record_poll! call" do
    active_session_tracking(PR_URL)
    isolate
    stub_evaluators

    PollBackoff.expects(:record_poll!).once.with(
      instance_of(Session),
      job_key: [
        Github::PrPollPass::POLL_BACKOFF_KEY,
        Github::PrPollPass::MERGE_CONFLICT_BACKOFF_KEY,
        Github::PrPollPass::COMMENT_BACKOFF_KEY
      ]
    )

    Github::PrPollPass.new.run
  end

  test "record_poll! writes every key it is given in one metadata write" do
    PollBackoff.record_poll!(@session_with_pr, job_key: %w[alpha beta])

    @session_with_pr.reload
    stamps = @session_with_pr.custom_metadata["poller_last_polled_at"]
    assert_equal %w[alpha beta].sort, stamps.keys.sort
    assert_equal stamps["alpha"], stamps["beta"]
  end

  # ---- the merge-conflict evaluator keeps its own 2-minute floor inside the pass ----
  #
  # The pass ticks every 30 seconds. The debounce that filters GitHub's transient
  # conflicting readings needs its two readings two minutes apart, or it stops being a
  # debounce and starts confirming the transient it exists to reject.

  test "the merge conflict evaluator is skipped when it was run inside its own interval" do
    active_session_tracking(PR_URL, stamps: {
      Github::PrPollPass::MERGE_CONFLICT_BACKOFF_KEY => 30.seconds.ago.iso8601
    })
    isolate
    stub_evaluators

    Github::MergeConflictEvaluator.any_instance.expects(:evaluate).never
    Github::PrStatusEvaluator.any_instance.expects(:evaluate).once

    PollBackoff.expects(:record_poll!).once.with(
      instance_of(Session),
      job_key: [ Github::PrPollPass::POLL_BACKOFF_KEY, Github::PrPollPass::COMMENT_BACKOFF_KEY ]
    )

    Github::PrPollPass.new.run
  end

  test "the merge conflict evaluator runs again once its own interval has elapsed" do
    active_session_tracking(PR_URL, stamps: {
      Github::PrPollPass::MERGE_CONFLICT_BACKOFF_KEY => 3.minutes.ago.iso8601
    })
    isolate
    stub_evaluators

    Github::MergeConflictEvaluator.any_instance.expects(:evaluate).once

    Github::PrPollPass.new.run
  end

  # The comment evaluator keeps its own key because the pass's gate is CAPPED for a
  # session holding an unresolved PR and the comment endpoints were never polled on
  # that capped cadence. At three hours of idleness the curve's floor is five minutes
  # for both, so a session polled six minutes ago is due for the pass and a comment
  # read ten seconds ago is not.
  test "the comment evaluator is skipped when it was run inside its own interval" do
    active_session_tracking(PR_URL, activity_age: 3.hours, stamps: {
      Github::PrPollPass::POLL_BACKOFF_KEY => 6.minutes.ago.iso8601,
      Github::PrPollPass::COMMENT_BACKOFF_KEY => 10.seconds.ago.iso8601
    })
    isolate
    stub_evaluators

    Github::PrStatusEvaluator.any_instance.expects(:evaluate).once
    Github::CommentEvaluator.any_instance.expects(:evaluate).never

    Github::PrPollPass.new.run
  end

  # ---- one evaluator's failure does not cost a session the other two ----

  test "an evaluator that raises does not stop the rest of the pass or lose the stamp" do
    active_session_tracking(PR_URL)
    isolate
    Github::PrSnapshot.stubs(:fetch).returns(nil)

    Github::PrStatusEvaluator.any_instance.stubs(:evaluate).raises(RuntimeError, "boom")
    Github::MergeConflictEvaluator.any_instance.expects(:evaluate).once
    Github::CommentEvaluator.any_instance.expects(:evaluate).once
    PollBackoff.expects(:record_poll!).once

    assert_nothing_raised { Github::PrPollPass.new.run }
  end

  # ---- PollBackoff integration ----
  #
  # The rate-limit relief PollBackoff exists to provide, and the case that must
  # not regress: a session nobody has touched in over a day, with nothing left to
  # wait for, is polled once a day and no more. The merged status is load-bearing
  # — a session still holding an unresolved PR is capped at 30 minutes instead
  # (#494), which is the case immediately below.

  test "run skips a stale session when its last_polled_at is within the backoff window" do
    @session_with_pr.update!(
      metadata: (@session_with_pr.metadata || {}).merge("last_user_activity_at" => 2.days.ago.iso8601),
      custom_metadata: (@session_with_pr.custom_metadata || {}).merge(
        "github_pull_request_statuses" => { PR_URL => "merged" },
        "poller_last_polled_at" => { Github::PrPollPass::POLL_BACKOFF_KEY => 1.hour.ago.iso8601 }
      )
    )
    isolate

    PollBackoff.expects(:record_poll!).never
    Github::PrSnapshot.expects(:fetch).never

    Github::PrPollPass.new.run
  end

  # ---- the #494 defect: a session parked on an open PR slept through its merge ----
  #
  # Sessions 4419 and 4422 each held an open PR, carried no `last_user_activity_at`
  # at all (so the curve counted from `created_at`), and were last polled at 23.7
  # hours of activity age. Eighteen minutes later they crossed into the >24 hr
  # bucket, whose floor is 24 hours measured from that last poll — so the next
  # poll was not due until a full day later. Both PRs merged eight hours inside
  # that gap and neither session was ever told.

  test "run polls a >24 hr idle session that is still holding an unresolved PR" do
    idle_session_holding(PR_URL, status: "open")
    isolate
    stub_evaluators

    Github::PrSnapshot.expects(:fetch).once.returns(nil)
    PollBackoff.expects(:record_poll!).once

    Github::PrPollPass.new.run
  end

  test "run polls a >24 hr idle session whose PR has no recorded status yet" do
    @session_with_pr.update!(
      metadata: (@session_with_pr.metadata || {}).merge("last_user_activity_at" => 2.days.ago.iso8601),
      custom_metadata: (@session_with_pr.custom_metadata || {}).merge(
        "github_pull_request_urls" => [ PR_URL ],
        "poller_last_polled_at" => { Github::PrPollPass::POLL_BACKOFF_KEY => 1.hour.ago.iso8601 }
      )
    )
    isolate
    stub_evaluators

    Github::PrSnapshot.expects(:fetch).once.returns(nil)

    Github::PrPollPass.new.run
  end

  # The cap is a ceiling, not a target: inside 30 minutes the session still waits,
  # so an idle session holding an open PR costs at most two polls an hour.
  test "run skips a session holding an unresolved PR that was polled inside the cap" do
    idle_session_holding(PR_URL, status: "open", last_polled: 10.minutes.ago)
    isolate

    PollBackoff.expects(:record_poll!).never
    Github::PrSnapshot.expects(:fetch).never

    Github::PrPollPass.new.run
  end

  # The cap has an expiry, and it has one because "unresolved" is a state a
  # session can never leave: nothing removes an idle session from
  # `with_github_prs`, and a deleted PR (or one in a repo the token cannot read)
  # never gets a status recorded at all. Without the bound both pin a session at
  # two polls an hour forever and the capped population only grows.
  test "run stops capping a session idle past AWAITING_PR_OUTCOME_MAX_IDLE" do
    idle_session_holding(
      PR_URL, status: "open", idle_for: Github::PrPollPass::AWAITING_PR_OUTCOME_MAX_IDLE + 1.day
    )
    isolate

    PollBackoff.expects(:record_poll!).never
    Github::PrSnapshot.expects(:fetch).never

    Github::PrPollPass.new.run
  end

  test "run still caps a session holding an unresolved PR just inside the idle bound" do
    idle_session_holding(
      PR_URL, status: "open", idle_for: Github::PrPollPass::AWAITING_PR_OUTCOME_MAX_IDLE - 1.hour
    )
    isolate
    stub_evaluators

    Github::PrSnapshot.expects(:fetch).once.returns(nil)

    Github::PrPollPass.new.run
  end

  # End to end over the defect: the same session state 4419 was in, and the merge
  # message it never got — through the real job, the real pass and the real evaluators,
  # with only the `gh` call itself faked.
  test "a >24 hr idle session parked on an open PR is told when that PR merges" do
    @session_with_pr.update!(
      status: :running,
      metadata: (@session_with_pr.metadata || {}).merge("last_user_activity_at" => 2.days.ago.iso8601),
      custom_metadata: {
        "github_pull_request_urls" => [ PR_URL ],
        "github_pull_request_statuses" => { PR_URL => "open" },
        "poller_last_polled_at" => { Github::PrPollPass::POLL_BACKOFF_KEY => 1.hour.ago.iso8601 }
      }
    )
    isolate
    stub_gh(
      pr_view: { "state" => "MERGED", "mergedAt" => "2025-01-01T12:00:00Z", "mergeable" => "UNKNOWN" },
      pr_checks: [],
      comments: []
    )

    GithubPrPollPassJob.perform_now

    @session_with_pr.reload
    assert_equal "merged", @session_with_pr.custom_metadata["github_pull_request_statuses"][PR_URL]
    assert @session_with_pr.custom_metadata.dig("github_pull_request_merged_notified", PR_URL),
      "the session must be recorded as having been told about the merge"

    messages = @session_with_pr.enqueued_messages.pending.to_a
    assert_equal 1, messages.size
    assert_includes messages.first.content, PR_URL
    assert_includes messages.first.content, "has been merged"
  end

  # End to end over the CI-failure path: one pass, one `gh pr view`, one `gh pr checks`,
  # and a red PR recorded where the UI reads it.
  test "a pass records a failing CI reading for an open PR" do
    active_session_tracking(PR_URL)
    isolate
    stub_gh(
      pr_view: { "state" => "OPEN", "mergedAt" => nil, "mergeable" => "MERGEABLE" },
      pr_checks: [ { "bucket" => "fail" } ],
      comments: []
    )

    GithubPrPollPassJob.perform_now

    @session_with_pr.reload
    assert_equal({ PR_URL => "open" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    assert_equal({ PR_URL => "fail" }, @session_with_pr.custom_metadata["github_pull_request_ci_statuses"])
  end

  # End to end over the merge-conflict path, including the debounce: two gated passes
  # two minutes apart, and only the second one notifies.
  test "two gated passes are what it takes to notify a merge conflict" do
    @session_with_pr.update!(status: :running)
    active_session_tracking(PR_URL)
    isolate
    stub_gh(
      pr_view: { "state" => "OPEN", "mergedAt" => nil, "mergeable" => "CONFLICTING" },
      pr_checks: [],
      comments: []
    )

    GithubPrPollPassJob.perform_now

    @session_with_pr.reload
    assert_equal({ PR_URL => true }, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"])
    refute @session_with_pr.enqueued_messages.pending.exists?,
      "the first conflicting reading only suspects"

    # A tick 30 seconds later runs the pass but NOT the merge conflict evaluator, so
    # nothing is confirmed off the back of two readings half a minute apart.
    travel 30.seconds do
      GithubPrPollPassJob.perform_now
      @session_with_pr.reload
      refute @session_with_pr.enqueued_messages.pending.exists?,
        "the debounce must still take two minutes, not two 30-second ticks"
    end

    travel 3.minutes do
      GithubPrPollPassJob.perform_now
    end

    @session_with_pr.reload
    assert_equal({ PR_URL => true }, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"])
    assert @session_with_pr.enqueued_messages.pending.exists?,
      "the second gated conflicting reading confirms and notifies"
  end

  private

  # Restrict the sweep to the one fixture session, so `.never` and `.once`
  # expectations are about it rather than about whatever else the fixtures hold.
  def isolate
    Session.stubs(:with_github_prs).returns(Session.where(id: @session_with_pr.id))
  end

  def stub_evaluators
    Github::PrStatusEvaluator.any_instance.stubs(:evaluate)
    Github::MergeConflictEvaluator.any_instance.stubs(:evaluate)
    Github::CommentEvaluator.any_instance.stubs(:evaluate)
  end

  def active_session_tracking(pr_url, stamps: {}, activity_age: 5.minutes)
    @session_with_pr.update!(
      metadata: (@session_with_pr.metadata || {}).merge("last_user_activity_at" => activity_age.ago.iso8601),
      custom_metadata: (@session_with_pr.custom_metadata || {}).merge(
        "github_pull_request_urls" => [ pr_url ],
        "poller_last_polled_at" => stamps
      )
    )
  end

  def idle_session_holding(pr_url, status:, idle_for: 2.days, last_polled: 1.hour.ago)
    @session_with_pr.update!(
      metadata: (@session_with_pr.metadata || {}).merge("last_user_activity_at" => idle_for.ago.iso8601),
      custom_metadata: (@session_with_pr.custom_metadata || {}).merge(
        "github_pull_request_urls" => [ pr_url ],
        "github_pull_request_statuses" => { pr_url => status },
        "poller_last_polled_at" => { Github::PrPollPass::POLL_BACKOFF_KEY => last_polled.iso8601 }
      )
    )
  end

  # Answer every `gh` invocation the pass makes from its argv, so an end-to-end test
  # exercises the real evaluators without a network. Mocha prefers the most recently
  # defined matching expectation, so the specific matchers come after the catch-all.
  def stub_gh(pr_view:, pr_checks:, comments:)
    status = fake_process_status

    BoundedSubprocess.stubs(:run).returns([ "", "", status ])
    BoundedSubprocess.stubs(:run)
      .with { |*args| args.first[1] == "pr" && args.first[2] == "view" }
      .returns([ pr_view.to_json, "", status ])
    BoundedSubprocess.stubs(:run)
      .with { |*args| args.first[1] == "pr" && args.first[2] == "checks" }
      .returns([ pr_checks.to_json, "", status ])
    BoundedSubprocess.stubs(:run)
      .with { |*args| args.first[1] == "api" }
      .returns([ comments.to_json, "", status ])
  end
end
