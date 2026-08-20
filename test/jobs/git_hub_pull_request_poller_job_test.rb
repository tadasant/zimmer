require "test_helper"
require "mocha/minitest"

class GitHubPullRequestPollerJobTest < ActiveSupport::TestCase
  setup do
    @session_with_pr = sessions(:with_pr_url)
    @session_without_pr = sessions(:running)
  end

  test "Session.with_github_prs returns active sessions with PR URLs" do
    result = Session.with_github_prs

    # Should include session with PR URL
    assert_includes result.pluck(:id), @session_with_pr.id

    # Should not include session without PR URL
    assert_not_includes result.pluck(:id), @session_without_pr.id
  end

  test "Session.with_github_prs excludes archived and failed sessions" do
    archived_session = sessions(:archived)
    failed_session = sessions(:failed)

    # Add PR URLs to these sessions
    archived_session.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/a/b/pull/1" ] })
    failed_session.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/c/d/pull/2" ] })

    result_ids = Session.with_github_prs.pluck(:id)

    # Should not include archived or failed sessions
    assert_not_includes result_ids, archived_session.id
    assert_not_includes result_ids, failed_session.id
  end

  # A poll cycle spans several seconds of GitHub API calls, so the session object this
  # job holds is stale by the time it writes. Before the write became a single-statement
  # jsonb merge, that write rebuilt the whole column from the stale snapshot — erasing a
  # PR URL the session's own transcript hook recorded during the poll, which is a session
  # where none of the GitHub integration ever engages again (issue #70).
  test "poll_pr_statuses keeps a PR url a transcript hook recorded during the poll" do
    first_pr = "https://github.com/owner/repo/pull/123"
    second_pr = "https://github.com/owner/repo/pull/456"
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ first_pr ] })

    stale_view = Session.find(@session_with_pr.id)

    # Mid-poll, the agent opens a second PR and the transcript hook records it.
    TranscriptHooks::BaseHook
      .new(session: Session.find(@session_with_pr.id), transcript_content: "", new_messages: [])
      .send(:update_custom_metadata, "github_pull_request_urls" => [ first_pr, second_pr ])

    TestJobReturningMerged.new.send(:poll_pr_statuses, stale_view)

    @session_with_pr.reload
    assert_equal [ first_pr, second_pr ], @session_with_pr.custom_metadata["github_pull_request_urls"],
      "the poller must not erase a PR url recorded while it was polling"
    assert_equal({ first_pr => "merged" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
  end

  test "poll_pr_statuses updates statuses when they change" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    # Use a test subclass that returns "merged"
    job = TestJobReturningMerged.new
    job.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    assert_equal({ "https://github.com/owner/repo/pull/123" => "merged" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
  end

  test "poll_pr_statuses does not update when statuses are unchanged" do
    # TestJobReturningOpen returns "open" status and nil CI status
    # Since nil CI status means no change (delete from empty hash = still empty),
    # and the PR status is already "open", nothing should change
    @session_with_pr.update!(
      custom_metadata: {
        "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
        "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/123" => "open" },
        "github_pull_request_ci_statuses" => {}
      }
    )

    original_updated_at = @session_with_pr.updated_at

    # Use a test subclass that returns "open" with nil CI status
    job = TestJobReturningOpen.new
    job.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    # updated_at should be unchanged since we didn't update
    assert_equal original_updated_at, @session_with_pr.updated_at
  end

  test "poll_pr_statuses handles nil fetch result gracefully" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    # Use a test subclass that returns nil
    job = TestJobReturningNil.new
    job.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    # Statuses should remain empty/nil since nil results are skipped
    assert_nil @session_with_pr.custom_metadata["github_pull_request_statuses"]
  end

  test "poll_pr_statuses updates all PR statuses" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [
        "https://github.com/owner/repo/pull/1",
        "https://github.com/owner/repo/pull/2"
      ]
    })

    job = TestJobReturningOpen.new
    job.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    assert_equal({
      "https://github.com/owner/repo/pull/1" => "open",
      "https://github.com/owner/repo/pull/2" => "open"
    }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
  end

  test "parses PR URL correctly with regex" do
    # Valid URLs
    test_cases = [
      [ "https://github.com/owner/repo/pull/123", "owner", "repo", "123" ],
      [ "https://github.com/my-org/my-repo/pull/456", "my-org", "my-repo", "456" ],
      [ "https://github.com/user_123/project-name/pull/999", "user_123", "project-name", "999" ]
    ]

    test_cases.each do |url, expected_owner, expected_repo, expected_pr|
      match = url.match(%r{github\.com/([^/]+)/([^/]+)/pull/(\d+)})
      assert_not_nil match, "Failed to match URL: #{url}"
      assert_equal expected_owner, match[1]
      assert_equal expected_repo, match[2]
      assert_equal expected_pr, match[3]
    end
  end

  test "fetch_pr_status detects merged PR from mergedAt field" do
    job = GitHubPullRequestPollerJob.new

    # Mock the gh CLI response for merged PR
    # gh pr view returns mergedAt as a timestamp string when merged, null otherwise
    merged_response = { "state" => "MERGED", "mergedAt" => "2025-01-01T12:00:00Z" }.to_json
    open_response = { "state" => "OPEN", "mergedAt" => nil }.to_json
    closed_response = { "state" => "CLOSED", "mergedAt" => nil }.to_json

    success_status = mock
    success_status.stubs(:success?).returns(true)

    Open3.stubs(:capture3).returns([ merged_response, "", success_status ])
    assert_equal "merged", job.send(:fetch_pr_status, "owner", "repo", "123")

    Open3.stubs(:capture3).returns([ open_response, "", success_status ])
    assert_equal "open", job.send(:fetch_pr_status, "owner", "repo", "123")

    Open3.stubs(:capture3).returns([ closed_response, "", success_status ])
    assert_equal "closed", job.send(:fetch_pr_status, "owner", "repo", "123")
  end

  test "perform handles errors for individual sessions without stopping" do
    # Create multiple sessions with PRs
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

    # The real job has error handling - just verify perform doesn't raise
    # when gh command isn't available (it will fail gracefully)
    assert_nothing_raised { GitHubPullRequestPollerJob.perform_now }

    # Cleanup
    session1.destroy
    session2.destroy
  end

  # Tests for CI status polling
  test "poll_pr_statuses fetches CI status for open PRs" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    # Use a test subclass that returns open status and pending CI
    job = TestJobWithCIStatusPending.new
    job.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    assert_equal({ "https://github.com/owner/repo/pull/123" => "open" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    assert_equal({ "https://github.com/owner/repo/pull/123" => "pending" }, @session_with_pr.custom_metadata["github_pull_request_ci_statuses"])
  end

  test "poll_pr_statuses clears CI status for merged PRs" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/123" => "open" },
      "github_pull_request_ci_statuses" => { "https://github.com/owner/repo/pull/123" => "pending" }
    })

    # Use a test subclass that returns merged status
    job = TestJobReturningMerged.new
    job.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    assert_equal({ "https://github.com/owner/repo/pull/123" => "merged" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    # CI status should be cleared for merged PRs
    assert_equal({}, @session_with_pr.custom_metadata["github_pull_request_ci_statuses"])
  end

  test "poll_pr_statuses does not update when statuses and ci statuses are unchanged" do
    @session_with_pr.update!(
      custom_metadata: {
        "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
        "github_pull_request_statuses" => { "https://github.com/owner/repo/pull/123" => "open" },
        "github_pull_request_ci_statuses" => { "https://github.com/owner/repo/pull/123" => "pass" }
      }
    )

    original_updated_at = @session_with_pr.updated_at

    # Use a test subclass that returns open with pass CI
    job = TestJobWithCIStatusPass.new
    job.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    # updated_at should be unchanged since we didn't update
    assert_equal original_updated_at, @session_with_pr.updated_at
  end

  test "fetch_ci_status determines overall status from multiple checks" do
    job = GitHubPullRequestPollerJob.new

    success_status = mock
    success_status.stubs(:success?).returns(true)
    success_status.stubs(:exitstatus).returns(0)

    # All passing
    all_pass_response = [
      { "bucket" => "pass", "state" => "SUCCESS" },
      { "bucket" => "pass", "state" => "SUCCESS" }
    ].to_json
    Open3.stubs(:capture3).returns([ all_pass_response, "", success_status ])
    assert_equal "pass", job.send(:fetch_ci_status, "owner", "repo", "123")

    # One failing
    one_fail_response = [
      { "bucket" => "pass", "state" => "SUCCESS" },
      { "bucket" => "fail", "state" => "FAILURE" }
    ].to_json
    Open3.stubs(:capture3).returns([ one_fail_response, "", success_status ])
    assert_equal "fail", job.send(:fetch_ci_status, "owner", "repo", "123")

    # One pending
    one_pending_response = [
      { "bucket" => "pass", "state" => "SUCCESS" },
      { "bucket" => "pending", "state" => "IN_PROGRESS" }
    ].to_json
    Open3.stubs(:capture3).returns([ one_pending_response, "", success_status ])
    assert_equal "pending", job.send(:fetch_ci_status, "owner", "repo", "123")

    # Fail takes precedence over pending
    fail_and_pending_response = [
      { "bucket" => "fail", "state" => "FAILURE" },
      { "bucket" => "pending", "state" => "IN_PROGRESS" }
    ].to_json
    Open3.stubs(:capture3).returns([ fail_and_pending_response, "", success_status ])
    assert_equal "fail", job.send(:fetch_ci_status, "owner", "repo", "123")
  end

  test "fetch_ci_status returns nil for empty checks array" do
    job = GitHubPullRequestPollerJob.new

    success_status = mock
    success_status.stubs(:success?).returns(true)
    success_status.stubs(:exitstatus).returns(0)

    # No checks
    Open3.stubs(:capture3).returns([ "[]", "", success_status ])
    assert_nil job.send(:fetch_ci_status, "owner", "repo", "123")
  end

  test "fetch_ci_status handles exit code 8 for pending checks" do
    job = GitHubPullRequestPollerJob.new

    pending_status = mock
    pending_status.stubs(:success?).returns(false)
    pending_status.stubs(:exitstatus).returns(8)

    pending_response = [
      { "bucket" => "pending", "state" => "IN_PROGRESS" }
    ].to_json
    Open3.stubs(:capture3).returns([ pending_response, "", pending_status ])
    assert_equal "pending", job.send(:fetch_ci_status, "owner", "repo", "123")
  end

  test "fetch_ci_status returns nil on command failure" do
    job = GitHubPullRequestPollerJob.new

    fail_status = mock
    fail_status.stubs(:success?).returns(false)
    fail_status.stubs(:exitstatus).returns(1)

    Open3.stubs(:capture3).returns([ "", "Error", fail_status ])
    assert_nil job.send(:fetch_ci_status, "owner", "repo", "123")
  end

  test "fetch_ci_status handles skipping status" do
    job = GitHubPullRequestPollerJob.new

    success_status = mock
    success_status.stubs(:success?).returns(true)
    success_status.stubs(:exitstatus).returns(0)

    # All skipping
    all_skipping_response = [
      { "bucket" => "skipping", "state" => "SKIPPED" },
      { "bucket" => "skipping", "state" => "SKIPPED" }
    ].to_json
    Open3.stubs(:capture3).returns([ all_skipping_response, "", success_status ])
    assert_equal "skipping", job.send(:fetch_ci_status, "owner", "repo", "123")

    # Mixed skipping and pass - should return pass
    skipping_and_pass_response = [
      { "bucket" => "skipping", "state" => "SKIPPED" },
      { "bucket" => "pass", "state" => "SUCCESS" }
    ].to_json
    Open3.stubs(:capture3).returns([ skipping_and_pass_response, "", success_status ])
    assert_equal "pass", job.send(:fetch_ci_status, "owner", "repo", "123")
  end

  test "fetch_ci_status handles cancel status with correct priority" do
    job = GitHubPullRequestPollerJob.new

    success_status = mock
    success_status.stubs(:success?).returns(true)
    success_status.stubs(:exitstatus).returns(0)

    # Cancel takes precedence over pass and skipping
    cancel_and_pass_response = [
      { "bucket" => "cancel", "state" => "CANCELLED" },
      { "bucket" => "pass", "state" => "SUCCESS" }
    ].to_json
    Open3.stubs(:capture3).returns([ cancel_and_pass_response, "", success_status ])
    assert_equal "cancel", job.send(:fetch_ci_status, "owner", "repo", "123")

    # Pending takes precedence over cancel
    pending_and_cancel_response = [
      { "bucket" => "pending", "state" => "IN_PROGRESS" },
      { "bucket" => "cancel", "state" => "CANCELLED" }
    ].to_json
    Open3.stubs(:capture3).returns([ pending_and_cancel_response, "", success_status ])
    assert_equal "pending", job.send(:fetch_ci_status, "owner", "repo", "123")

    # Fail takes precedence over cancel
    fail_and_cancel_response = [
      { "bucket" => "fail", "state" => "FAILURE" },
      { "bucket" => "cancel", "state" => "CANCELLED" }
    ].to_json
    Open3.stubs(:capture3).returns([ fail_and_cancel_response, "", success_status ])
    assert_equal "fail", job.send(:fetch_ci_status, "owner", "repo", "123")
  end

  # ---- Merged-PR automated message ----

  MERGED_PR_URL = "https://github.com/owner/repo/pull/123".freeze

  test "poll_pr_statuses tells a running session, once, when its PR goes open to merged" do
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" }
    })

    job = TestJobReturningMerged.new
    job.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    assert_equal({ MERGED_PR_URL => "merged" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    assert_equal({ MERGED_PR_URL => true }, @session_with_pr.custom_metadata["github_pull_request_merged_notified"])

    messages = @session_with_pr.enqueued_messages.pending.to_a
    assert_equal 1, messages.size, "Expected exactly one enqueued message for the merge"
    assert_includes messages.first.content, "[AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]"
    assert_includes messages.first.content, MERGED_PR_URL
    assert_includes messages.first.content, "has been merged"
    assert_equal 1, @session_with_pr.logs.where("content LIKE ?", "%PR merged: #{MERGED_PR_URL}%").count

    # The next poll still reads "merged" — it must not re-notify.
    job.send(:poll_pr_statuses, Session.find(@session_with_pr.id))

    @session_with_pr.reload
    assert_equal 1, @session_with_pr.enqueued_messages.pending.count,
      "The merged message must be delivered once per PR, not on every poll"
    assert_equal 1, @session_with_pr.logs.where("content LIKE ?", "%PR merged: #{MERGED_PR_URL}%").count
  end

  test "poll_pr_statuses sends the merged message immediately to a session in needs_input" do
    @session_with_pr.update!(status: :needs_input, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" }
    })

    # Stub AgentSessionJob to prevent actual job enqueuing
    AgentSessionJob.stubs(:enqueue_with_prompt)

    TestJobReturningMerged.new.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    assert_equal "running", @session_with_pr.status,
      "A parked session should be woken by the merge rather than left in needs_input"
    assert @session_with_pr.logs.where("content LIKE ?", "%PR merged: #{MERGED_PR_URL}%sent immediately%").exists?
    refute @session_with_pr.enqueued_messages.pending.exists?,
      "An immediately-delivered message must not also be queued"
  end

  test "poll_pr_statuses says nothing about a PR that was already merged and notified" do
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "merged" },
      "github_pull_request_merged_notified" => { MERGED_PR_URL => true }
    })

    TestJobReturningMerged.new.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    refute @session_with_pr.enqueued_messages.pending.exists?
    refute @session_with_pr.logs.where("content LIKE ?", "%PR merged:%").exists?
  end

  test "poll_pr_statuses does not announce a PR that was already merged the first time it is seen" do
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ]
    })

    TestJobReturningMerged.new.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    assert_equal({ MERGED_PR_URL => "merged" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merged_notified"]
    refute @session_with_pr.enqueued_messages.pending.exists?,
      "A PR already merged before the first poll is not this session's merge event"
  end

  test "poll_pr_statuses announces only the PR that merged when a session has several" do
    merged = "https://github.com/owner/repo/pull/102"
    still_open = "https://github.com/owner/repo/pull/103"
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ merged, still_open ],
      "github_pull_request_statuses" => { merged => "open", still_open => "open" }
    })

    TestJobMergingPr102.new.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    assert_equal({ merged => "merged", still_open => "open" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    assert_equal({ merged => true }, @session_with_pr.custom_metadata["github_pull_request_merged_notified"])

    messages = @session_with_pr.enqueued_messages.pending.to_a
    assert_equal 1, messages.size
    assert_includes messages.first.content, merged
    refute_includes messages.first.content, still_open
  end

  test "poll_pr_statuses does not message a session that reached a terminal state mid-poll" do
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" }
    })

    # The poller reads the session before it spends seconds talking to GitHub, so the
    # status it holds is the one from the top of the sweep. Poll a stale view of a
    # session that archived itself in the meantime — the state this guard exists for.
    stale_view = Session.find(@session_with_pr.id)
    @session_with_pr.update!(status: :archived)

    TestJobReturningMerged.new.send(:poll_pr_statuses, stale_view)

    @session_with_pr.reload
    # The status is still recorded — only the message is withheld, and the PR is
    # never marked notified because it never was.
    assert_equal({ MERGED_PR_URL => "merged" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merged_notified"]
    refute @session_with_pr.enqueued_messages.pending.exists?
    refute @session_with_pr.logs.where("content LIKE ?", "%PR merged:%").exists?
  end

  test "poll_pr_statuses queues the merged message for a waiting session" do
    @session_with_pr.update!(status: :waiting, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" }
    })

    TestJobReturningMerged.new.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    assert_equal "waiting", @session_with_pr.status,
      "A sleeping session is not woken by the poller — the message waits for its next turn"
    assert_equal 1, @session_with_pr.enqueued_messages.pending.count
    assert @session_with_pr.logs.where("content LIKE ?", "%PR merged: #{MERGED_PR_URL}%enqueued%").exists?
  end

  test "poll_pr_statuses says nothing when a PR is closed without merging" do
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" }
    })

    TestJobReturningClosed.new.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    assert_equal({ MERGED_PR_URL => "closed" }, @session_with_pr.custom_metadata["github_pull_request_statuses"])
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merged_notified"]
    refute @session_with_pr.enqueued_messages.pending.exists?,
      "Only a merge is worth interrupting a session for"
  end

  test "poll_pr_statuses announces two PRs that merge in the same poll" do
    first = "https://github.com/owner/repo/pull/201"
    second = "https://github.com/owner/repo/pull/202"
    @session_with_pr.update!(status: :running, custom_metadata: {
      "github_pull_request_urls" => [ first, second ],
      "github_pull_request_statuses" => { first => "open", second => "open" }
    })

    TestJobReturningMerged.new.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    assert_equal({ first => true, second => true }, @session_with_pr.custom_metadata["github_pull_request_merged_notified"])

    # Two deliveries against one session in a single sweep: each takes its own lock and
    # its own position, so neither overwrites the other.
    contents = @session_with_pr.enqueued_messages.pending.order(:position).pluck(:content)
    assert_equal 2, contents.size
    assert contents.any? { |c| c.include?(first) }
    assert contents.any? { |c| c.include?(second) }
    assert_equal [ 1, 2 ], @session_with_pr.enqueued_messages.pending.order(:position).pluck(:position)
  end

  test "poll_pr_statuses does not record a PR as notified when delivery failed" do
    @session_with_pr.update!(status: :needs_input, custom_metadata: {
      "github_pull_request_urls" => [ MERGED_PR_URL ],
      "github_pull_request_statuses" => { MERGED_PR_URL => "open" }
    })

    # Delivery blows up mid-transaction. The poller swallows it — one session that
    # cannot take a message must not abort the sweep — but the marker must not then
    # claim a notification that never left.
    Session.any_instance.stubs(:deliver_follow_up!).raises(RuntimeError, "boom")

    TestJobReturningMerged.new.send(:poll_pr_statuses, @session_with_pr)

    @session_with_pr.reload
    assert_nil @session_with_pr.custom_metadata["github_pull_request_merged_notified"]
    refute @session_with_pr.logs.where("content LIKE ?", "%PR merged:%").exists?,
      "The log entry is written inside the delivery transaction and must roll back with it"
  end

  test "pr_merged_message names the PR and both outcomes" do
    message = AutomatedPrompts.pr_merged_message(MERGED_PR_URL)

    assert_includes message, "[AUTOMATED SYSTEM MESSAGE - NOT USER INPUT]"
    assert_includes message, MERGED_PR_URL
    assert_includes message, "has been merged"
    assert_match(/archive this session/i, message)
    assert_match(/waiting on this merge/i, message)
    # An outstanding human request outranks archiving — say so, or the session
    # can close itself on top of a question nobody answered.
    assert_match(/outranks archiving/i, message)
  end

  # ---- PollBackoff integration ----

  test "perform skips a stale session when its last_polled_at is within the backoff window" do
    @session_with_pr.update!(
      metadata: (@session_with_pr.metadata || {}).merge("last_user_activity_at" => 2.days.ago.iso8601),
      custom_metadata: (@session_with_pr.custom_metadata || {}).merge(
        "poller_last_polled_at" => { "github_pr_poller" => 1.hour.ago.iso8601 }
      )
    )

    # Isolate from other fixtures so .never expectations only check this session
    Session.stubs(:with_github_prs).returns(Session.where(id: @session_with_pr.id))

    PollBackoff.expects(:record_poll!).never
    GitHubPullRequestPollerJob.any_instance.expects(:poll_pr_statuses).never

    GitHubPullRequestPollerJob.perform_now
  end

  test "perform polls and records the poll for a fresh session" do
    @session_with_pr.update!(
      metadata: (@session_with_pr.metadata || {}).merge("last_user_activity_at" => 5.minutes.ago.iso8601)
    )

    # Isolate from other fixtures so the record_poll! expectation only fires for this session
    Session.stubs(:with_github_prs).returns(Session.where(id: @session_with_pr.id))
    GitHubPullRequestPollerJob.any_instance.stubs(:poll_pr_statuses)
    PollBackoff.expects(:record_poll!).with(
      instance_of(Session),
      job_key: GitHubPullRequestPollerJob::POLL_BACKOFF_KEY
    ).at_least_once

    GitHubPullRequestPollerJob.perform_now
  end

  # Test subclasses to mock fetch_pr_status behavior
  class TestJobReturningMerged < GitHubPullRequestPollerJob
    def fetch_pr_status(_owner, _repo, _pr_number)
      "merged"
    end

    def fetch_ci_status(_owner, _repo, _pr_number)
      nil
    end
  end

  class TestJobReturningOpen < GitHubPullRequestPollerJob
    def fetch_pr_status(_owner, _repo, _pr_number)
      "open"
    end

    def fetch_ci_status(_owner, _repo, _pr_number)
      nil
    end
  end

  class TestJobReturningClosed < GitHubPullRequestPollerJob
    def fetch_pr_status(_owner, _repo, _pr_number)
      "closed"
    end

    def fetch_ci_status(_owner, _repo, _pr_number)
      nil
    end
  end

  # One PR of several merges; the rest stay open.
  class TestJobMergingPr102 < GitHubPullRequestPollerJob
    def fetch_pr_status(_owner, _repo, pr_number)
      pr_number == "102" ? "merged" : "open"
    end

    def fetch_ci_status(_owner, _repo, _pr_number)
      nil
    end
  end

  class TestJobReturningNil < GitHubPullRequestPollerJob
    def fetch_pr_status(_owner, _repo, _pr_number)
      nil
    end

    def fetch_ci_status(_owner, _repo, _pr_number)
      nil
    end
  end

  # ---- Nil subprocess status (ZombieReaperJob reaped the gh child) ----
  #
  # Open3.capture3 returns `[stdout, stderr, nil]` when something else reaps the child
  # before its waiter thread does — in production, ZombieReaperJob's blanket
  # `Process.waitpid(-1, WNOHANG)` in this same worker. A nil status is a failed call.

  test "fetch_pr_status treats a nil status as a failure instead of raising" do
    Open3.stubs(:capture3).returns([ "", "gh: connection reset", nil ])

    job = GitHubPullRequestPollerJob.new

    result = nil
    assert_nothing_raised do
      result = job.send(:fetch_pr_status, "owner", "repo", "42")
    end

    assert_nil result, "an unverifiable gh call must not report a PR state"
  end

  test "fetch_ci_status treats a nil status as a failure, not as the exit-8 pending code" do
    Open3.stubs(:capture3).returns([ "", "gh: connection reset", nil ])

    job = GitHubPullRequestPollerJob.new

    result = nil
    assert_nothing_raised do
      result = job.send(:fetch_ci_status, "owner", "repo", "42")
    end

    # The success? / exitstatus == 8 line dereferenced the nil twice. Neither branch may
    # be taken: an unknown exit code is not the "checks pending" code.
    assert_nil result
  end

  test "fetch_ci_status still treats a real exit 8 as pending checks" do
    checks = [ { "bucket" => "pending", "state" => "IN_PROGRESS" } ].to_json
    Open3.stubs(:capture3).returns([ checks, "", fake_process_status(exitstatus: 8) ])

    assert_equal "pending", GitHubPullRequestPollerJob.new.send(:fetch_ci_status, "owner", "repo", "42")
  end

  class TestJobWithCIStatusPending < GitHubPullRequestPollerJob
    def fetch_pr_status(_owner, _repo, _pr_number)
      "open"
    end

    def fetch_ci_status(_owner, _repo, _pr_number)
      "pending"
    end
  end

  class TestJobWithCIStatusPass < GitHubPullRequestPollerJob
    def fetch_pr_status(_owner, _repo, _pr_number)
      "open"
    end

    def fetch_ci_status(_owner, _repo, _pr_number)
      "pass"
    end
  end

  # The queue could not tell Zimmer's own notices from a caller's, and the
  # archive alert is the one reader that must: a session archiving over this
  # message is complying with it, not discarding something somebody is waiting
  # on. See EnqueuedMessage::ARCHIVE_SATISFIED_ORIGINS.
  test "a queued merged-PR notice is stamped with its origin" do
    @session_with_pr.update!(status: :running)

    GitHubPullRequestPollerJob.new.send(
      :notify_merged_prs, @session_with_pr, [ "https://github.com/owner/repo/pull/1" ]
    )

    message = @session_with_pr.enqueued_messages.sole
    assert_equal "automated_pr_merged", message.origin
    assert message.archive_satisfied?
  end
end
