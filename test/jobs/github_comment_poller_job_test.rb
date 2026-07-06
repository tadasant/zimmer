require "test_helper"
require "mocha/minitest"

class GithubCommentPollerJobTest < ActiveSupport::TestCase
  setup do
    @session_with_pr = sessions(:with_pr_url)
    @session_without_pr = sessions(:running)
  end

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

  test "build_pr_comment_data correctly identifies agent comments" do
    job = GithubCommentPollerJob.new

    # Regular user comment
    user_comment = {
      "id" => 123,
      "user" => { "login" => "tadasant" },
      "body" => "Can you fix this bug?",
      "html_url" => "https://github.com/owner/repo/pull/1#issuecomment-123",
      "created_at" => "2025-01-01T12:00:00Z"
    }

    result = job.send(:build_pr_comment_data, user_comment, "https://github.com/owner/repo/pull/1", "1")

    assert_equal 123, result["id"]
    assert_equal "tadasant", result["author"]
    assert_equal "tadasant", result["attribution"]
    assert_equal "Can you fix this bug?", result["body"]
  end

  test "build_pr_comment_data identifies self attribution for agent comments" do
    job = GithubCommentPollerJob.new

    # Agent comment with marker
    agent_comment = {
      "id" => 456,
      "user" => { "login" => "some-user" },
      "body" => "[CC Says] I've made the requested changes...",
      "html_url" => "https://github.com/owner/repo/pull/1#issuecomment-456",
      "created_at" => "2025-01-01T12:05:00Z"
    }

    result = job.send(:build_pr_comment_data, agent_comment, "https://github.com/owner/repo/pull/1", "1")

    assert_equal 456, result["id"]
    assert_equal "some-user", result["author"]
    assert_equal "self", result["attribution"]
  end

  test "build_review_comment_data includes code context" do
    job = GithubCommentPollerJob.new

    review_comment = {
      "id" => 789,
      "user" => { "login" => "macoughl" },
      "body" => "This looks wrong",
      "html_url" => "https://github.com/owner/repo/pull/1#discussion_r789",
      "path" => "src/main.rb",
      "line" => 42,
      "diff_hunk" => "@@ -40,3 +40,5 @@\n def method\n   # code here\n+ puts 'hello'\n end",
      "in_reply_to_id" => nil,
      "created_at" => "2025-01-01T12:00:00Z"
    }

    result = job.send(:build_review_comment_data, review_comment, "https://github.com/owner/repo/pull/1", "1")

    assert_equal 789, result["id"]
    assert_equal "macoughl", result["author"]
    assert_equal "macoughl", result["attribution"]
    assert_equal "src/main.rb", result["path"]
    assert_equal 42, result["line"]
    assert_includes result["diff_hunk"], "def method"
  end

  test "poll_comments_for_session updates custom_metadata with new comments" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    # Create job with mocked API calls
    job = TestJobWithMockedComments.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    comments = @session_with_pr.custom_metadata["github_comments"]
    assert_not_nil comments
    assert comments.key?("https://github.com/owner/repo/pull/123")
    assert_equal 1, comments["https://github.com/owner/repo/pull/123"]["pr_comments"].size
    assert_equal 1, comments["https://github.com/owner/repo/pull/123"]["review_comments"].size
  end

  test "poll_comments_for_session does not create duplicate comments with same ID" do
    # Pre-populate with the same comment that the mock returns (ID 111)
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_comments" => {
        "https://github.com/owner/repo/pull/123" => {
          "pr_comments" => [
            { "id" => 111, "author" => "randomuser", "attribution" => "randomuser", "body" => "Some comment", "url" => "https://github.com/owner/repo/pull/123#issuecomment-111", "created_at" => "2025-01-01T12:00:00Z" }
          ],
          "review_comments" => [
            { "id" => 222, "author" => "randomuser", "attribution" => "randomuser", "body" => "Review comment", "url" => "https://github.com/owner/repo/pull/123#discussion_r222", "path" => "test.rb", "line" => 10, "diff_hunk" => "@@ code", "in_reply_to_id" => nil, "created_at" => "2025-01-01T12:00:00Z" }
          ]
        }
      }
    })

    job = TestJobWithMockedComments.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    pr_comments = @session_with_pr.custom_metadata.dig("github_comments", "https://github.com/owner/repo/pull/123", "pr_comments")
    review_comments = @session_with_pr.custom_metadata.dig("github_comments", "https://github.com/owner/repo/pull/123", "review_comments")

    # Should still have only 1 of each since the mock returns comments with same IDs
    assert_equal 1, pr_comments.size
    assert_equal 1, review_comments.size
  end

  test "poll_comments_for_session enqueues follow-up for whitelisted user comments" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    # Mock the prompt builder
    mock_builder = mock
    mock_builder.stubs(:build).returns("Test prompt content")
    GithubCommentPromptBuilder.stubs(:new).returns(mock_builder)

    job = TestJobWithWhitelistedComment.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    # Should have created an enqueued message
    assert_equal 1, @session_with_pr.enqueued_messages.count
    assert_equal "Test prompt content", @session_with_pr.enqueued_messages.first.content
  end

  test "poll_comments_for_session does not enqueue for non-whitelisted users" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    job = TestJobWithNonWhitelistedComment.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    # Should not have created any enqueued message
    assert_equal 0, @session_with_pr.enqueued_messages.count
  end

  test "poll_comments_for_session does not enqueue for self attributed comments" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    job = TestJobWithAgentComment.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    # Should not have created any enqueued message (agent's own comment)
    assert_equal 0, @session_with_pr.enqueued_messages.count
  end

  test "WHITELISTED_USERS contains expected usernames" do
    assert_includes GithubCommentPollerJob::WHITELISTED_USERS, "tadasant"
    assert_includes GithubCommentPollerJob::WHITELISTED_USERS, "macoughl"
    assert_equal 2, GithubCommentPollerJob::WHITELISTED_USERS.size
  end

  test "AGENT_COMMENT_MARKER is the expected string" do
    assert_equal "[CC Says]", GithubCommentPollerJob::AGENT_COMMENT_MARKER
  end

  test "BLACKLISTED_PATTERNS contains deploy command pattern" do
    assert GithubCommentPollerJob::BLACKLISTED_PATTERNS.any? { |p| p.is_a?(Regexp) }
    assert_equal 1, GithubCommentPollerJob::BLACKLISTED_PATTERNS.size
  end

  test "blacklisted_comment? returns true for exact /deploy staging match" do
    job = GithubCommentPollerJob.new

    assert job.send(:blacklisted_comment?, "/deploy staging")
    assert job.send(:blacklisted_comment?, "/Deploy Staging")  # case insensitive
    assert job.send(:blacklisted_comment?, "/DEPLOY STAGING")  # case insensitive
  end

  test "blacklisted_comment? returns false for non-matching comments" do
    job = GithubCommentPollerJob.new

    assert_not job.send(:blacklisted_comment?, "Please fix this bug")
    assert_not job.send(:blacklisted_comment?, "Can you deploy this?")
    assert_not job.send(:blacklisted_comment?, "The /deploy staging command should work")  # not at start
    assert_not job.send(:blacklisted_comment?, "/deploy production")  # different command
    assert_not job.send(:blacklisted_comment?, "/deploy staging\nsome other text")  # has extra content
    assert_not job.send(:blacklisted_comment?, "")
    assert_not job.send(:blacklisted_comment?, nil)
  end

  test "poll_comments_for_session does not enqueue for blacklisted comments" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    job = TestJobWithBlacklistedComment.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    # Should not have created any enqueued message (blacklisted /deploy command)
    assert_equal 0, @session_with_pr.enqueued_messages.count
  end

  test "poll_comments_for_session does not enqueue for blacklisted review comments" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    job = TestJobWithBlacklistedReviewComment.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    # Should not have created any enqueued message (blacklisted /deploy command in review comment)
    assert_equal 0, @session_with_pr.enqueued_messages.count
  end

  test "poll_comments_for_session sends prompt immediately when session is needs_input" do
    # Use a session that is in needs_input state
    session_needs_input = sessions(:needs_input)
    session_needs_input.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    # Mock the prompt builder
    mock_builder = mock
    mock_builder.stubs(:build).returns("Test prompt for immediate send")
    GithubCommentPromptBuilder.stubs(:new).returns(mock_builder)

    # Track if AgentSessionJob.enqueue_with_prompt is called
    AgentSessionJob.expects(:enqueue_with_prompt).with(session_needs_input.id, "Test prompt for immediate send").once

    job = TestJobWithWhitelistedComment.new
    job.send(:poll_comments_for_session, session_needs_input)

    session_needs_input.reload

    # Should NOT have created an enqueued message (sent immediately instead)
    assert_equal 0, session_needs_input.enqueued_messages.count

    # Should have transitioned to running
    assert session_needs_input.running?

    # Should have stored the pending prompt in metadata
    assert_equal "Test prompt for immediate send", session_needs_input.metadata["pending_follow_up_prompt"]

    # Should have created a log entry about immediate send with comment type and URL
    immediate_log = session_needs_input.logs.find { |l| l.content.include?("sent immediately") }
    assert_not_nil immediate_log, "Expected to find a log entry containing 'sent immediately'"
    assert_includes immediate_log.content, "PR comment"
    assert_includes immediate_log.content, "https://github.com/owner/repo/pull/123#issuecomment-333"
  end

  test "poll_comments_for_session enqueues prompt when session is running" do
    # Use a session that is in running state (status 0)
    session_running = sessions(:running)
    session_running.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    # Mock the prompt builder
    mock_builder = mock
    mock_builder.stubs(:build).returns("Test prompt for queue")
    GithubCommentPromptBuilder.stubs(:new).returns(mock_builder)

    # Should NOT call AgentSessionJob.enqueue_with_prompt
    AgentSessionJob.expects(:enqueue_with_prompt).never

    job = TestJobWithWhitelistedComment.new
    job.send(:poll_comments_for_session, session_running)

    session_running.reload

    # Should have created an enqueued message
    assert_equal 1, session_running.enqueued_messages.count
    assert_equal "Test prompt for queue", session_running.enqueued_messages.first.content

    # Should still be running
    assert session_running.running?
  end

  test "poll_comments_for_session enqueues prompt when session is waiting" do
    # Use a session that is in waiting state (status 1)
    session_waiting = sessions(:waiting)
    session_waiting.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    # Mock the prompt builder
    mock_builder = mock
    mock_builder.stubs(:build).returns("Test prompt for waiting queue")
    GithubCommentPromptBuilder.stubs(:new).returns(mock_builder)

    # Should NOT call AgentSessionJob.enqueue_with_prompt
    AgentSessionJob.expects(:enqueue_with_prompt).never

    job = TestJobWithWhitelistedComment.new
    job.send(:poll_comments_for_session, session_waiting)

    session_waiting.reload

    # Should have created an enqueued message
    assert_equal 1, session_waiting.enqueued_messages.count
    assert_equal "Test prompt for waiting queue", session_waiting.enqueued_messages.first.content
  end

  test "add_eyes_reaction calls correct API for PR comments" do
    job = GithubCommentPollerJob.new

    comment_info = {
      type: "pr",
      owner: "testowner",
      repo: "testrepo",
      pr_number: "42",
      data: { "id" => 12345, "author" => "tadasant" }
    }

    # Mock Open3.capture3 to verify the correct command is called
    expected_command = [
      "gh", "api",
      "--method", "POST",
      "repos/testowner/testrepo/issues/comments/12345/reactions",
      "-f", "content=eyes"
    ]

    mock_status = mock
    mock_status.stubs(:success?).returns(true)
    Open3.expects(:capture3).with(*expected_command).returns([ "{}", "", mock_status ])

    job.send(:add_eyes_reaction, comment_info)
  end

  test "add_eyes_reaction calls correct API for review comments" do
    job = GithubCommentPollerJob.new

    comment_info = {
      type: "review",
      owner: "testowner",
      repo: "testrepo",
      pr_number: "42",
      data: { "id" => 67890, "author" => "macoughl" }
    }

    # Mock Open3.capture3 to verify the correct command is called
    expected_command = [
      "gh", "api",
      "--method", "POST",
      "repos/testowner/testrepo/pulls/comments/67890/reactions",
      "-f", "content=eyes"
    ]

    mock_status = mock
    mock_status.stubs(:success?).returns(true)
    Open3.expects(:capture3).with(*expected_command).returns([ "{}", "", mock_status ])

    job.send(:add_eyes_reaction, comment_info)
  end

  test "add_eyes_reaction logs warning on API failure but does not raise" do
    job = GithubCommentPollerJob.new

    comment_info = {
      type: "pr",
      owner: "testowner",
      repo: "testrepo",
      pr_number: "42",
      data: { "id" => 11111, "author" => "tadasant" }
    }

    mock_status = mock
    mock_status.stubs(:success?).returns(false)
    Open3.stubs(:capture3).returns([ "", "API error", mock_status ])

    # Should not raise an exception
    assert_nothing_raised do
      job.send(:add_eyes_reaction, comment_info)
    end
  end

  test "add_eyes_reaction handles malformed comment_info gracefully" do
    job = GithubCommentPollerJob.new

    # Test with nil data
    malformed_info_nil_data = {
      type: "pr",
      owner: "testowner",
      repo: "testrepo",
      data: nil
    }

    # Should not raise an exception and should return early
    assert_nothing_raised do
      job.send(:add_eyes_reaction, malformed_info_nil_data)
    end

    # Test with missing id in data
    malformed_info_no_id = {
      type: "pr",
      owner: "testowner",
      repo: "testrepo",
      data: { "author" => "someone" }  # No "id" key
    }

    assert_nothing_raised do
      job.send(:add_eyes_reaction, malformed_info_no_id)
    end
  end

  test "enqueue_follow_up_prompt adds eyes reaction before creating enqueued message" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    # Mock the prompt builder
    mock_builder = mock
    mock_builder.stubs(:build).returns("Test prompt content")
    GithubCommentPromptBuilder.stubs(:new).returns(mock_builder)

    # Track the order of operations
    call_order = []

    job = GithubCommentPollerJob.new

    # Stub add_eyes_reaction to track when it's called
    job.define_singleton_method(:add_eyes_reaction) do |comment_info|
      call_order << :eyes_reaction
    end

    comment_info = {
      type: "pr",
      owner: "owner",
      repo: "repo",
      pr_number: "123",
      pr_url: "https://github.com/owner/repo/pull/123",
      data: { "id" => 999, "author" => "tadasant", "body" => "Please fix this" }
    }

    job.send(:enqueue_follow_up_prompt, @session_with_pr, comment_info)

    # Verify eyes reaction was called
    assert_includes call_order, :eyes_reaction

    # Verify enqueued message was still created
    @session_with_pr.reload
    assert_equal 1, @session_with_pr.enqueued_messages.count
  end

  # ---- PollBackoff integration ----

  test "perform skips a stale session when its last_polled_at is within the backoff window" do
    @session_with_pr.update!(
      metadata: (@session_with_pr.metadata || {}).merge("last_user_activity_at" => 2.days.ago.iso8601),
      custom_metadata: (@session_with_pr.custom_metadata || {}).merge(
        "poller_last_polled_at" => { "github_comment_poller" => 1.hour.ago.iso8601 }
      )
    )

    # Isolate from other fixtures so .never expectations only check this session
    Session.stubs(:with_github_prs).returns(Session.where(id: @session_with_pr.id))

    PollBackoff.expects(:record_poll!).never
    GithubCommentPollerJob.any_instance.expects(:poll_comments_for_session).never

    GithubCommentPollerJob.perform_now
  end

  test "perform polls and records the poll for a fresh session" do
    @session_with_pr.update!(
      metadata: (@session_with_pr.metadata || {}).merge("last_user_activity_at" => 5.minutes.ago.iso8601)
    )

    # Isolate from other fixtures so the record_poll! expectation only fires for this session
    Session.stubs(:with_github_prs).returns(Session.where(id: @session_with_pr.id))
    GithubCommentPollerJob.any_instance.stubs(:poll_comments_for_session)
    PollBackoff.expects(:record_poll!).with(
      instance_of(Session),
      job_key: GithubCommentPollerJob::POLL_BACKOFF_KEY
    ).at_least_once

    GithubCommentPollerJob.perform_now
  end

  # Test subclass that returns mocked PR and review comments
  class TestJobWithMockedComments < GithubCommentPollerJob
    def fetch_pr_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 111,
          "user" => { "login" => "randomuser" },
          "body" => "Some comment",
          "html_url" => "https://github.com/owner/repo/pull/123#issuecomment-111",
          "created_at" => "2025-01-01T12:00:00Z"
        }
      ]
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 222,
          "user" => { "login" => "randomuser" },
          "body" => "Review comment",
          "html_url" => "https://github.com/owner/repo/pull/123#discussion_r222",
          "path" => "test.rb",
          "line" => 10,
          "diff_hunk" => "@@ code",
          "in_reply_to_id" => nil,
          "created_at" => "2025-01-01T12:00:00Z"
        }
      ]
    end
  end

  # Test subclass that returns a comment from a whitelisted user
  class TestJobWithWhitelistedComment < GithubCommentPollerJob
    def fetch_pr_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 333,
          "user" => { "login" => "tadasant" },
          "body" => "Please fix this",
          "html_url" => "https://github.com/owner/repo/pull/123#issuecomment-333",
          "created_at" => "2025-01-01T12:00:00Z"
        }
      ]
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      []
    end
  end

  # Test subclass that returns a comment from a non-whitelisted user
  class TestJobWithNonWhitelistedComment < GithubCommentPollerJob
    def fetch_pr_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 444,
          "user" => { "login" => "randomuser" },
          "body" => "Nice PR!",
          "html_url" => "https://github.com/owner/repo/pull/123#issuecomment-444",
          "created_at" => "2025-01-01T12:00:00Z"
        }
      ]
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      []
    end
  end

  # Test subclass that returns an agent-generated comment
  class TestJobWithAgentComment < GithubCommentPollerJob
    def fetch_pr_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 555,
          "user" => { "login" => "tadasant" },
          "body" => "[CC Says] I've completed the task",
          "html_url" => "https://github.com/owner/repo/pull/123#issuecomment-555",
          "created_at" => "2025-01-01T12:00:00Z"
        }
      ]
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      []
    end
  end

  # Test subclass that returns a blacklisted comment (deploy command)
  class TestJobWithBlacklistedComment < GithubCommentPollerJob
    def fetch_pr_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 666,
          "user" => { "login" => "tadasant" },
          "body" => "/deploy staging",
          "html_url" => "https://github.com/owner/repo/pull/123#issuecomment-666",
          "created_at" => "2025-01-01T12:00:00Z"
        }
      ]
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      []
    end
  end

  # Test subclass that returns a blacklisted review comment (deploy staging command)
  class TestJobWithBlacklistedReviewComment < GithubCommentPollerJob
    def fetch_pr_comments(_owner, _repo, _pr_number)
      []
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 777,
          "user" => { "login" => "tadasant" },
          "body" => "/deploy staging",
          "html_url" => "https://github.com/owner/repo/pull/123#discussion_r777",
          "path" => "src/main.rb",
          "line" => 50,
          "diff_hunk" => "@@ -48,3 +48,5 @@ code here",
          "in_reply_to_id" => nil,
          "created_at" => "2025-01-01T12:00:00Z"
        }
      ]
    end
  end

  # === Tests for timestamp filtering ===

  test "comment_created_after_tracking_started? returns true when no tracking timestamp" do
    job = GithubCommentPollerJob.new

    comment_data = { "created_at" => "2025-01-01T12:00:00Z" }
    assert job.send(:comment_created_after_tracking_started?, comment_data, nil)
    assert job.send(:comment_created_after_tracking_started?, comment_data, "")
  end

  test "comment_created_after_tracking_started? returns true when comment created_at is missing" do
    job = GithubCommentPollerJob.new

    comment_data = {}
    assert job.send(:comment_created_after_tracking_started?, comment_data, "2025-01-01T12:00:00Z")

    comment_data_with_nil = { "created_at" => nil }
    assert job.send(:comment_created_after_tracking_started?, comment_data_with_nil, "2025-01-01T12:00:00Z")
  end

  test "comment_created_after_tracking_started? returns true when comment is after tracking started" do
    job = GithubCommentPollerJob.new

    # Comment created 1 hour after tracking started
    comment_data = { "created_at" => "2025-01-01T13:00:00Z" }
    tracking_started = "2025-01-01T12:00:00Z"

    assert job.send(:comment_created_after_tracking_started?, comment_data, tracking_started)
  end

  test "comment_created_after_tracking_started? returns true when comment is exactly at tracking start time" do
    job = GithubCommentPollerJob.new

    comment_data = { "created_at" => "2025-01-01T12:00:00Z" }
    tracking_started = "2025-01-01T12:00:00Z"

    assert job.send(:comment_created_after_tracking_started?, comment_data, tracking_started)
  end

  test "comment_created_after_tracking_started? returns false when comment is before tracking started" do
    job = GithubCommentPollerJob.new

    # Comment created 1 hour before tracking started
    comment_data = { "created_at" => "2025-01-01T11:00:00Z" }
    tracking_started = "2025-01-01T12:00:00Z"

    assert_not job.send(:comment_created_after_tracking_started?, comment_data, tracking_started)
  end

  test "comment_created_after_tracking_started? handles invalid timestamp gracefully" do
    job = GithubCommentPollerJob.new

    comment_data = { "created_at" => "not-a-valid-timestamp" }
    tracking_started = "2025-01-01T12:00:00Z"

    # Should return true (allow the comment) when parsing fails
    assert job.send(:comment_created_after_tracking_started?, comment_data, tracking_started)
  end

  test "poll_comments_for_session does not enqueue for comments before tracking started" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pr_tracking_started_at" => { "https://github.com/owner/repo/pull/123" => "2025-01-01T14:00:00Z" }
    })

    # Mock the prompt builder (shouldn't be called since comment is too old)
    GithubCommentPromptBuilder.expects(:new).never

    job = TestJobWithOldComment.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    # Comments should still be stored (for deduplication)
    pr_comments = @session_with_pr.custom_metadata.dig("github_comments", "https://github.com/owner/repo/pull/123", "pr_comments")
    assert_equal 1, pr_comments.size

    # But no enqueued message should be created
    assert_equal 0, @session_with_pr.enqueued_messages.count
  end

  test "poll_comments_for_session enqueues comments after tracking started" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pr_tracking_started_at" => { "https://github.com/owner/repo/pull/123" => "2025-01-01T10:00:00Z" }
    })

    # Mock the prompt builder
    mock_builder = mock
    mock_builder.stubs(:build).returns("Test prompt content")
    GithubCommentPromptBuilder.stubs(:new).returns(mock_builder)

    job = TestJobWithNewComment.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    # Should have created an enqueued message
    assert_equal 1, @session_with_pr.enqueued_messages.count
  end

  test "poll_comments_for_session allows comments when no tracking timestamp exists (legacy sessions)" do
    # Legacy session without tracking timestamp
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ]
    })

    # Mock the prompt builder
    mock_builder = mock
    mock_builder.stubs(:build).returns("Test prompt content")
    GithubCommentPromptBuilder.stubs(:new).returns(mock_builder)

    job = TestJobWithWhitelistedComment.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    # Should have created an enqueued message (backwards compatibility)
    assert_equal 1, @session_with_pr.enqueued_messages.count
  end

  # Test subclass with a comment created BEFORE tracking started
  class TestJobWithOldComment < GithubCommentPollerJob
    def fetch_pr_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 888,
          "user" => { "login" => "tadasant" },
          "body" => "Old comment from before tracking",
          "html_url" => "https://github.com/owner/repo/pull/123#issuecomment-888",
          "created_at" => "2025-01-01T12:00:00Z"  # Before tracking started at 14:00:00Z
        }
      ]
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      []
    end
  end

  # Test subclass with a comment created AFTER tracking started
  class TestJobWithNewComment < GithubCommentPollerJob
    def fetch_pr_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 999,
          "user" => { "login" => "tadasant" },
          "body" => "New comment after tracking started",
          "html_url" => "https://github.com/owner/repo/pull/123#issuecomment-999",
          "created_at" => "2025-01-01T15:00:00Z"  # After tracking started at 10:00:00Z
        }
      ]
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      []
    end
  end

  # === Tests for review comments with timestamp filtering ===

  test "poll_comments_for_session does not enqueue for review comments before tracking started" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pr_tracking_started_at" => { "https://github.com/owner/repo/pull/123" => "2025-01-01T14:00:00Z" }
    })

    # Mock the prompt builder (shouldn't be called since comment is too old)
    GithubCommentPromptBuilder.expects(:new).never

    job = TestJobWithOldReviewComment.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    # Review comments should still be stored (for deduplication)
    review_comments = @session_with_pr.custom_metadata.dig("github_comments", "https://github.com/owner/repo/pull/123", "review_comments")
    assert_equal 1, review_comments.size

    # But no enqueued message should be created
    assert_equal 0, @session_with_pr.enqueued_messages.count
  end

  test "poll_comments_for_session enqueues review comments after tracking started" do
    @session_with_pr.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_pr_tracking_started_at" => { "https://github.com/owner/repo/pull/123" => "2025-01-01T10:00:00Z" }
    })

    # Mock the prompt builder
    mock_builder = mock
    mock_builder.stubs(:build).returns("Test review prompt content")
    GithubCommentPromptBuilder.stubs(:new).returns(mock_builder)

    job = TestJobWithNewReviewComment.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    # Should have created an enqueued message
    assert_equal 1, @session_with_pr.enqueued_messages.count
  end

  # Test subclass with a review comment created BEFORE tracking started
  class TestJobWithOldReviewComment < GithubCommentPollerJob
    def fetch_pr_comments(_owner, _repo, _pr_number)
      []
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 1001,
          "user" => { "login" => "tadasant" },
          "body" => "Old review comment from before tracking",
          "html_url" => "https://github.com/owner/repo/pull/123#discussion_r1001",
          "path" => "src/main.rb",
          "line" => 25,
          "diff_hunk" => "@@ -20,3 +20,5 @@ code here",
          "in_reply_to_id" => nil,
          "created_at" => "2025-01-01T12:00:00Z"  # Before tracking started at 14:00:00Z
        }
      ]
    end
  end

  # Test subclass with a review comment created AFTER tracking started
  class TestJobWithNewReviewComment < GithubCommentPollerJob
    def fetch_pr_comments(_owner, _repo, _pr_number)
      []
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 1002,
          "user" => { "login" => "tadasant" },
          "body" => "New review comment after tracking started",
          "html_url" => "https://github.com/owner/repo/pull/123#discussion_r1002",
          "path" => "src/main.rb",
          "line" => 30,
          "diff_hunk" => "@@ -28,3 +28,5 @@ more code",
          "in_reply_to_id" => nil,
          "created_at" => "2025-01-01T15:00:00Z"  # After tracking started at 10:00:00Z
        }
      ]
    end
  end
end
