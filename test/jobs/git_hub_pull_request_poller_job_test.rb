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

  class TestJobReturningNil < GitHubPullRequestPollerJob
    def fetch_pr_status(_owner, _repo, _pr_number)
      nil
    end

    def fetch_ci_status(_owner, _repo, _pr_number)
      nil
    end
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
end
