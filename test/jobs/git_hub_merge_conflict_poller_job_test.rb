require "test_helper"
require "mocha/minitest"

class GitHubMergeConflictPollerJobTest < ActiveSupport::TestCase
  setup do
    @session_with_pr = sessions(:with_pr_url_and_status)
  end

  test "Session.with_github_prs returns active sessions with PR URLs" do
    result = Session.with_github_prs

    assert_includes result.pluck(:id), @session_with_pr.id
    assert_not_includes result.pluck(:id), sessions(:running).id
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

  test "poll_merge_conflicts only suspects (does not notify) on the first conflicting poll" do
    pr_url = "https://github.com/owner/repo/pull/456"
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ pr_url ],
      "github_pull_request_statuses" => { pr_url => "open" }
    })

    job = TestJobWithConflict.new
    job.send(:poll_merge_conflicts, @session_with_pr)

    @session_with_pr.reload
    # First conflicting reading marks the PR suspected, NOT confirmed. The
    # confirmed-conflicts key is never written because nothing was confirmed.
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"]
    assert_equal({ pr_url => true }, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"])

    # No notification yet — a single (possibly stale/transient) false must not nudge.
    refute @session_with_pr.logs.where("content LIKE ?", "%Merge conflict detected%").exists?,
      "Should not notify on the first conflicting poll"
    refute @session_with_pr.enqueued_messages.pending.exists?,
      "Should not enqueue a message on the first conflicting poll"
  end

  test "poll_merge_conflicts confirms and notifies on the second consecutive conflicting poll" do
    pr_url = "https://github.com/owner/repo/pull/456"
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ pr_url ],
      "github_pull_request_statuses" => { pr_url => "open" }
    })

    job = TestJobWithConflict.new
    job.send(:poll_merge_conflicts, @session_with_pr) # first poll: suspect
    @session_with_pr.reload
    job.send(:poll_merge_conflicts, @session_with_pr) # second poll: confirm + notify

    @session_with_pr.reload
    # Promoted to confirmed, suspected marker cleared.
    assert_equal({ pr_url => true }, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"])
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"])

    # Now the message is enqueued.
    assert @session_with_pr.logs.where("content LIKE ?", "%Merge conflict detected%").exists?,
      "Expected a log entry about merge conflict detection after the second poll"
    assert @session_with_pr.enqueued_messages.pending.exists?,
      "Expected a pending enqueued message after the second poll"
  end

  test "poll_merge_conflicts never notifies for a transient false (conflict then clean)" do
    pr_url = "https://github.com/owner/repo/pull/456"
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ pr_url ],
      "github_pull_request_statuses" => { pr_url => "open" }
    })

    job = GitHubMergeConflictPollerJob.new
    # GitHub returns a stale/transient false on the first poll, then the real
    # (clean) state on the next poll.
    job.stubs(:fetch_merge_conflict_status).returns(true, false)

    job.send(:poll_merge_conflicts, @session_with_pr) # suspect
    @session_with_pr.reload
    job.send(:poll_merge_conflicts, @session_with_pr) # clean → clears suspicion

    @session_with_pr.reload
    # Confirmed-conflicts key was never written (nothing confirmed); the
    # suspected marker set on the first poll is cleared by the clean read.
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"]
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"])
    refute @session_with_pr.logs.where("content LIKE ?", "%Merge conflict detected%").exists?,
      "A transient false must never produce a conflict notification"
    refute @session_with_pr.enqueued_messages.pending.exists?,
      "A transient false must never enqueue a message"
  end

  test "poll_merge_conflicts does not re-notify for already known conflicts" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/456" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/456" => "open" },
      "github_pull_request_merge_conflicts" => { "https://github.com/owner/repo/pull/456" => true }
    })

    initial_log_count = @session_with_pr.logs.count

    job = TestJobWithConflict.new
    job.send(:poll_merge_conflicts, @session_with_pr)

    @session_with_pr.reload
    # No new logs should be created since conflict was already known
    assert_equal initial_log_count, @session_with_pr.logs.count,
      "Should not create new logs for already-known conflicts"
  end

  test "poll_merge_conflicts clears conflict when PR becomes mergeable" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/456" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/456" => "open" },
      "github_pull_request_merge_conflicts" => { "https://github.com/owner/repo/pull/456" => true }
    })

    job = TestJobNoConflict.new
    job.send(:poll_merge_conflicts, @session_with_pr)

    @session_with_pr.reload
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"])
  end

  test "poll_merge_conflicts clears both confirmed and suspected markers on a clean read" do
    pr_url = "https://github.com/owner/repo/pull/456"
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ pr_url ],
      "github_pull_request_statuses" => { pr_url => "open" },
      "github_pull_request_merge_conflicts" => { pr_url => true },
      "github_pull_request_merge_conflicts_suspected" => { pr_url => true }
    })

    job = TestJobNoConflict.new
    job.send(:poll_merge_conflicts, @session_with_pr)

    @session_with_pr.reload
    # A clean read must clear BOTH markers, not just one.
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"])
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"])
  end

  test "poll_merge_conflicts skips non-open PRs" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/456" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/456" => "merged" },
      "github_pull_request_merge_conflicts" => { "https://github.com/owner/repo/pull/456" => true }
    })

    job = TestJobWithConflict.new
    job.send(:poll_merge_conflicts, @session_with_pr)

    @session_with_pr.reload
    # Conflict should be cleared for non-open PRs
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"])
  end

  test "poll_merge_conflicts clears a suspected marker when the PR is no longer open" do
    pr_url = "https://github.com/owner/repo/pull/456"
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ pr_url ],
      "github_pull_request_statuses" => { pr_url => "merged" },
      "github_pull_request_merge_conflicts_suspected" => { pr_url => true }
    })

    job = TestJobWithConflict.new
    job.send(:poll_merge_conflicts, @session_with_pr)

    @session_with_pr.reload
    # A merged/closed PR can't have actionable conflicts, so a lingering
    # suspected marker must be cleared (and never promoted to confirmed).
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_merge_conflicts_suspected"])
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"]
  end

  test "poll_merge_conflicts does not update when conflicts unchanged" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/456" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/456" => "open" },
      "github_pull_request_merge_conflicts" => { "https://github.com/owner/repo/pull/456" => true }
    })

    original_updated_at = @session_with_pr.updated_at

    job = TestJobWithConflict.new
    job.send(:poll_merge_conflicts, @session_with_pr)

    @session_with_pr.reload
    assert_equal original_updated_at, @session_with_pr.updated_at
  end

  test "poll_merge_conflicts skips PR when status is nil (undetermined)" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/456" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/456" => "open" }
    })

    job = TestJobNilConflict.new
    job.send(:poll_merge_conflicts, @session_with_pr)

    @session_with_pr.reload
    # Should not have created any conflict metadata since result was nil
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merge_conflicts"]
  end

  test "fetch_mergeable_field returns raw value for conflicting PR" do
    job = GitHubMergeConflictPollerJob.new

    success_status = mock
    success_status.stubs(:success?).returns(true)

    Open3.stubs(:capture3).returns([ "false\n", "", success_status ])
    assert_equal "false", job.send(:fetch_mergeable_field, "owner", "repo", "123")
  end

  test "fetch_mergeable_field returns raw value for mergeable PR" do
    job = GitHubMergeConflictPollerJob.new

    success_status = mock
    success_status.stubs(:success?).returns(true)

    Open3.stubs(:capture3).returns([ "true\n", "", success_status ])
    assert_equal "true", job.send(:fetch_mergeable_field, "owner", "repo", "123")
  end

  test "fetch_mergeable_field returns nil on command failure" do
    job = GitHubMergeConflictPollerJob.new

    fail_status = mock
    fail_status.stubs(:success?).returns(false)

    Open3.stubs(:capture3).returns([ "", "Error", fail_status ])
    assert_nil job.send(:fetch_mergeable_field, "owner", "repo", "123")
  end

  test "fetch_merge_conflict_status returns true for conflicting PR without retrying" do
    job = GitHubMergeConflictPollerJob.new
    job.stubs(:fetch_mergeable_field).returns("false")
    job.expects(:sleep).never

    assert_equal true, job.send(:fetch_merge_conflict_status, "owner", "repo", "123")
  end

  test "fetch_merge_conflict_status returns false for mergeable PR without retrying" do
    job = GitHubMergeConflictPollerJob.new
    job.stubs(:fetch_mergeable_field).returns("true")
    job.expects(:sleep).never

    assert_equal false, job.send(:fetch_merge_conflict_status, "owner", "repo", "123")
  end

  test "fetch_merge_conflict_status retries on null then returns result" do
    job = GitHubMergeConflictPollerJob.new
    job.stubs(:fetch_mergeable_field).returns("null", "null", "false")
    job.expects(:sleep).with(GitHubMergeConflictPollerJob::NULL_RETRY_DELAY).times(2)

    assert_equal true, job.send(:fetch_merge_conflict_status, "owner", "repo", "123")
  end

  test "fetch_merge_conflict_status returns nil after max retries on null" do
    job = GitHubMergeConflictPollerJob.new
    job.stubs(:fetch_mergeable_field).returns("null", "null", "null", "null")
    job.expects(:sleep).with(GitHubMergeConflictPollerJob::NULL_RETRY_DELAY).times(3)

    assert_nil job.send(:fetch_merge_conflict_status, "owner", "repo", "123")
  end

  test "fetch_merge_conflict_status does not retry on API error" do
    job = GitHubMergeConflictPollerJob.new
    job.stubs(:fetch_mergeable_field).returns(nil)
    job.expects(:sleep).never

    assert_nil job.send(:fetch_merge_conflict_status, "owner", "repo", "123")
  end

  test "fetch_merge_conflict_status does not retry on unexpected value" do
    job = GitHubMergeConflictPollerJob.new
    job.stubs(:fetch_mergeable_field).returns("unexpected")
    job.expects(:sleep).never

    assert_nil job.send(:fetch_merge_conflict_status, "owner", "repo", "123")
  end

  test "perform handles errors for individual sessions without stopping" do
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

    assert_nothing_raised { GitHubMergeConflictPollerJob.perform_now }

    session1.destroy
    session2.destroy
  end

  test "enqueue_merge_conflict_message sends immediately when session needs_input" do
    @session_with_pr.update!(
      status: :needs_input,
      custom_metadata: {
        "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/456" ],
        "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/456" => "open" }
      }
    )

    pr_url = "https://github.com/owner/repo/pull/456"

    # Stub AgentSessionJob to prevent actual job enqueuing
    AgentSessionJob.stubs(:enqueue_with_prompt)

    job = GitHubMergeConflictPollerJob.new
    job.send(:enqueue_merge_conflict_message, @session_with_pr, pr_url)

    @session_with_pr.reload
    assert_equal "running", @session_with_pr.status
    assert @session_with_pr.logs.where("content LIKE ?", "%sent immediately%").exists?
  end

  test "enqueue_merge_conflict_message enqueues for later when session is running" do
    @session_with_pr.update!(
      status: :running,
      custom_metadata: {
        "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/456" ],
        "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/456" => "open" }
      }
    )

    pr_url = "https://github.com/owner/repo/pull/456"

    job = GitHubMergeConflictPollerJob.new
    job.send(:enqueue_merge_conflict_message, @session_with_pr, pr_url)

    @session_with_pr.reload
    assert @session_with_pr.enqueued_messages.pending.exists?,
      "Expected a pending enqueued message"
    assert_match(/merge conflict/i, @session_with_pr.enqueued_messages.pending.first.content)
    assert @session_with_pr.logs.where("content LIKE ?", "%enqueued%").exists?
  end

  test "automated message includes PR URL" do
    pr_url = "https://github.com/owner/repo/pull/123"
    message = AutomatedPrompts.merge_conflict_message(pr_url)

    assert_includes message, pr_url
    assert_includes message, "[AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]"
    assert_includes message, "merge conflicts"
  end

  # ---- PollBackoff integration ----

  test "perform skips a stale session when its last_polled_at is within the backoff window" do
    @session_with_pr.update!(
      metadata: (@session_with_pr.metadata || {}).merge("last_user_activity_at" => 2.days.ago.iso8601),
      custom_metadata: (@session_with_pr.custom_metadata || {}).merge(
        "poller_last_polled_at" => { "github_merge_conflict_poller" => 1.hour.ago.iso8601 }
      )
    )

    # Isolate from other fixtures so .never expectations only check this session
    Session.stubs(:with_github_prs).returns(Session.where(id: @session_with_pr.id))

    PollBackoff.expects(:record_poll!).never
    GitHubMergeConflictPollerJob.any_instance.expects(:poll_merge_conflicts).never

    GitHubMergeConflictPollerJob.perform_now
  end

  test "perform polls and records the poll for a fresh session" do
    @session_with_pr.update!(
      metadata: (@session_with_pr.metadata || {}).merge("last_user_activity_at" => 5.minutes.ago.iso8601)
    )

    # Isolate from other fixtures so the record_poll! expectation only fires for this session
    Session.stubs(:with_github_prs).returns(Session.where(id: @session_with_pr.id))
    GitHubMergeConflictPollerJob.any_instance.stubs(:poll_merge_conflicts)
    PollBackoff.expects(:record_poll!).with(
      instance_of(Session),
      job_key: GitHubMergeConflictPollerJob::POLL_BACKOFF_KEY
    ).at_least_once

    GitHubMergeConflictPollerJob.perform_now
  end

  # Test subclasses to mock fetch_merge_conflict_status behavior
  class TestJobWithConflict < GitHubMergeConflictPollerJob
    def fetch_merge_conflict_status(_owner, _repo, _pr_number)
      true
    end
  end

  class TestJobNoConflict < GitHubMergeConflictPollerJob
    def fetch_merge_conflict_status(_owner, _repo, _pr_number)
      false
    end
  end

  class TestJobNilConflict < GitHubMergeConflictPollerJob
    def fetch_merge_conflict_status(_owner, _repo, _pr_number)
      nil
    end
  end
end
