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
    mock_builder.stubs(:actionable?).returns(true)
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
    mock_builder.stubs(:actionable?).returns(true)
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
    mock_builder.stubs(:actionable?).returns(true)
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
    mock_builder.stubs(:actionable?).returns(true)
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
    mock_builder.stubs(:actionable?).returns(true)
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
    mock_builder.stubs(:actionable?).returns(true)
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
    mock_builder.stubs(:actionable?).returns(true)
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
    mock_builder.stubs(:actionable?).returns(true)
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

  # === Automated comments ===

  test "automated_comment? recognizes a Zimmer automation report heading" do
    job = GithubCommentPollerJob.new

    assert job.send(:automated_comment?, merge_gate_body)
    assert job.send(:automated_comment?, "## Merge gate\n\nVerdict: HOLD")
    assert job.send(:automated_comment?, "### 🚦 merge gate")
    assert job.send(:automated_comment?, "## Merge gate ##")            # closing hashes
    assert job.send(:automated_comment?, "\n\n## 🚀 Merge gate\n")       # leading blank lines
    assert job.send(:automated_comment?, "## 🚀 Merge gate\r\n\r\nVerdict")  # CRLF
  end

  test "automated_comment? leaves human comments alone" do
    job = GithubCommentPollerJob.new

    assert_not job.send(:automated_comment?, "Please fix this bug")
    assert_not job.send(:automated_comment?, "The merge gate rated this small — do you agree?")
    assert_not job.send(:automated_comment?, "## Merge gate thoughts\n\nI think it over-rated this")
    assert_not job.send(:automated_comment?, "## Summary\n\nThis PR does X")
    assert_not job.send(:automated_comment?, "> ## 🚀 Merge gate\n\nabout this bit:")  # quoted
    assert_not job.send(:automated_comment?, "Thoughts on the gate:\n\n## 🚀 Merge gate")  # not the first line
    assert_not job.send(:automated_comment?, "")
    assert_not job.send(:automated_comment?, nil)
  end

  test "poll_comments_for_session ignores a merge gate comment authored by a whitelisted user" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    # No follow-up means no GitHub API traffic at all — in particular, no 👀 reaction
    Open3.expects(:capture3).never

    job = TestJobWithMergeGateComment.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    assert_equal 0, @session_with_pr.enqueued_messages.count
    # The comment is still tracked in metadata; it just doesn't wake the session
    tracked = @session_with_pr.custom_metadata.dig("github_comments", "https://github.com/owner/repo/pull/123", "pr_comments")
    assert_equal 1, tracked.size
  end

  test "poll_comments_for_session ignores a merge gate review comment" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ] })

    Open3.expects(:capture3).never

    job = TestJobWithMergeGateReviewComment.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    assert_equal 0, @session_with_pr.enqueued_messages.count
  end

  # === The 👀 reaction is only a promise Zimmer can keep ===

  test "poll_comments_for_session neither reacts nor enqueues when the visibility lookup fails" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/otherowner/repo/pull/123" ] })

    # A failed `gh api repos/...` is the only capture3 call we expect: no reaction follows
    failure_status = mock
    failure_status.stubs(:success?).returns(false)
    Open3.expects(:capture3).with("gh", "api", "repos/otherowner/repo", "--jq", ".private").returns([ "", "HTTP 502", failure_status ])

    job = TestJobWithWhitelistedComment.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    assert_equal 0, @session_with_pr.enqueued_messages.count
  end

  test "poll_comments_for_session neither reacts nor enqueues on an untrusted public repo" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/otherowner/repo/pull/123" ] })

    GithubCommentPromptBuilder.any_instance.stubs(:public_repo?).returns(true)
    Open3.expects(:capture3).never

    job = TestJobWithWhitelistedComment.new
    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    assert_equal 0, @session_with_pr.enqueued_messages.count
  end

  test "poll_comments_for_session reacts and enqueues for a human comment on a trusted repo" do
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/tadasant/zimmer/pull/123" ] })

    mock_builder = mock
    mock_builder.stubs(:actionable?).returns(true)
    mock_builder.stubs(:build).returns("Test prompt content")
    GithubCommentPromptBuilder.stubs(:new).returns(mock_builder)

    reacted_to = []
    job = TestJobWithWhitelistedComment.new
    job.define_singleton_method(:add_eyes_reaction) { |info| reacted_to << info.dig(:data, "id") }

    job.send(:poll_comments_for_session, @session_with_pr)

    @session_with_pr.reload

    assert_equal [ 333 ], reacted_to
    assert_equal 1, @session_with_pr.enqueued_messages.count
    assert_equal "Test prompt content", @session_with_pr.enqueued_messages.first.content
  end

  test "enqueue_follow_up_prompt does not react when the builder returns no prompt" do
    mock_builder = mock
    mock_builder.stubs(:actionable?).returns(true)
    mock_builder.stubs(:build).returns(nil)
    GithubCommentPromptBuilder.stubs(:new).returns(mock_builder)

    reacted_to = []
    job = GithubCommentPollerJob.new
    job.define_singleton_method(:add_eyes_reaction) { |info| reacted_to << info.dig(:data, "id") }

    job.send(:enqueue_follow_up_prompt, @session_with_pr, human_comment_info)

    assert_empty reacted_to
    assert_equal 0, @session_with_pr.reload.enqueued_messages.count
  end

  test "enqueue_follow_up_prompt does not react when the comment is not actionable" do
    mock_builder = mock
    mock_builder.stubs(:actionable?).returns(false)
    mock_builder.stubs(:visibility_lookup_failed?).returns(false)
    GithubCommentPromptBuilder.stubs(:new).returns(mock_builder)

    reacted_to = []
    job = GithubCommentPollerJob.new
    job.define_singleton_method(:add_eyes_reaction) { |info| reacted_to << info.dig(:data, "id") }

    job.send(:enqueue_follow_up_prompt, @session_with_pr, human_comment_info)

    assert_empty reacted_to
    assert_equal 0, @session_with_pr.reload.enqueued_messages.count
  end

  test "a failed reaction API call still enqueues the follow-up prompt" do
    mock_builder = mock
    mock_builder.stubs(:actionable?).returns(true)
    mock_builder.stubs(:build).returns("Test prompt content")
    GithubCommentPromptBuilder.stubs(:new).returns(mock_builder)

    failure_status = mock
    failure_status.stubs(:success?).returns(false)
    Open3.stubs(:capture3).returns([ "", "API error", failure_status ])

    job = GithubCommentPollerJob.new

    assert_nothing_raised do
      job.send(:enqueue_follow_up_prompt, @session_with_pr, human_comment_info)
    end

    assert_equal 1, @session_with_pr.reload.enqueued_messages.count
  end

  test "a raising reaction API call still enqueues the follow-up prompt" do
    mock_builder = mock
    mock_builder.stubs(:actionable?).returns(true)
    mock_builder.stubs(:build).returns("Test prompt content")
    GithubCommentPromptBuilder.stubs(:new).returns(mock_builder)

    Open3.stubs(:capture3).raises(Errno::ENOENT, "gh")

    job = GithubCommentPollerJob.new

    assert_nothing_raised do
      job.send(:enqueue_follow_up_prompt, @session_with_pr, human_comment_info)
    end

    assert_equal 1, @session_with_pr.reload.enqueued_messages.count
  end

  # Test subclass that returns the merge gate's rating comment, posted (as it is in
  # production) by `gh` authenticated as a whitelisted human and with no [CC Says] marker
  class TestJobWithMergeGateComment < GithubCommentPollerJob
    def fetch_pr_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 2001,
          "user" => { "login" => "tadasant" },
          "body" => "## 🚀 Merge gate\n\n**Verdict: AUTO-MERGE** — all four axes small.",
          "html_url" => "https://github.com/owner/repo/pull/123#issuecomment-2001",
          "created_at" => "2025-01-01T12:00:00Z"
        }
      ]
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      []
    end
  end

  # Test subclass that returns the merge gate's rating as an inline review comment, to
  # cover the review-comment call site of the filter as well as the PR-comment one
  class TestJobWithMergeGateReviewComment < GithubCommentPollerJob
    def fetch_pr_comments(_owner, _repo, _pr_number)
      []
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 2002,
          "user" => { "login" => "tadasant" },
          "body" => "## 🚀 Merge gate\n\n**Verdict: HOLD**",
          "html_url" => "https://github.com/owner/repo/pull/123#discussion_r2002",
          "path" => "src/main.rb",
          "line" => 12,
          "diff_hunk" => "@@ -10,3 +10,5 @@ code here",
          "in_reply_to_id" => nil,
          "created_at" => "2025-01-01T12:00:00Z"
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

  private

  def merge_gate_body
    <<~BODY
      ## 🚀 Merge gate

      **Verdict: AUTO-MERGE** — all four axes small.
    BODY
  end

  # A genuine human comment on a trusted repo, shaped as poll_comments_for_session builds it
  def human_comment_info
    {
      type: "pr",
      owner: "tadasant",
      repo: "zimmer",
      pr_number: "123",
      pr_url: "https://github.com/tadasant/zimmer/pull/123",
      data: {
        "id" => 999,
        "author" => "tadasant",
        "body" => "Please fix this",
        "url" => "https://github.com/tadasant/zimmer/pull/123#issuecomment-999"
      }
    }
  end
  # --- Agent-posted comments (the cross-session dispatch loop) ----------------

  # A whitelisted-author comment that a Zimmer session actually posted. Because
  # `gh` authenticates as the human inside every session, this is byte-identical
  # to a human comment from GitHub's side — which is the bug.
  class TestJobWithAgentPostedComment < GithubCommentPollerJob
    def fetch_pr_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 5145406778,
          "user" => { "login" => "tadasant" },
          "body" => "Reported back: the deploy is green.",
          "html_url" => "https://github.com/tadasant/zimmer/pull/123#issuecomment-5145406778",
          "created_at" => "2025-01-01T12:00:00Z"
        }
      ]
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      []
    end
  end

  # The same comment, arriving fresh — inside the window where the authorship hook
  # may not have claimed it yet.
  class TestJobWithFreshComment < GithubCommentPollerJob
    # Stamped once, so a later poll sees the same comment aging rather than a new
    # one created at the new "now".
    def created_at
      @created_at ||= Time.current.iso8601
    end

    def fetch_pr_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 5145406778,
          "user" => { "login" => "tadasant" },
          "body" => "Reported back: the deploy is green.",
          "html_url" => "https://github.com/tadasant/zimmer/pull/123#issuecomment-5145406778",
          "created_at" => created_at
        }
      ]
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      []
    end
  end

  def trusted_pr_session
    @session_with_pr.update!(custom_metadata: { "github_pull_request_urls" => [ "https://github.com/tadasant/zimmer/pull/123" ] })
    @session_with_pr
  end

  def stub_actionable_builder
    mock_builder = mock
    mock_builder.stubs(:actionable?).returns(true)
    mock_builder.stubs(:build).returns("Test prompt content")
    GithubCommentPromptBuilder.stubs(:new).returns(mock_builder)
  end

  def stored_pr_comments(session)
    session.reload.custom_metadata.dig("github_comments", "https://github.com/tadasant/zimmer/pull/123", "pr_comments")
  end

  test "poll_comments_for_session does not enqueue a comment another session posted" do
    session = trusted_pr_session
    poster = sessions(:running)
    AgentPostedGithubComment.record!(session: poster, comment_type: "pr", comment_id: 5145406778)

    stub_actionable_builder
    # No 👀 either: reacting is a promise to reply, and there is nothing to reply to.
    Open3.expects(:capture3).never

    TestJobWithAgentPostedComment.new.send(:poll_comments_for_session, session)

    assert_equal 0, session.reload.enqueued_messages.count
    assert_equal "skipped:agent_posted", stored_pr_comments(session).first["dispatch_state"]
  end

  test "poll_comments_for_session still records an agent-posted comment in custom_metadata" do
    session = trusted_pr_session
    AgentPostedGithubComment.record!(session: sessions(:running), comment_type: "pr", comment_id: 5145406778)
    stub_actionable_builder

    TestJobWithAgentPostedComment.new.send(:poll_comments_for_session, session)

    stored = stored_pr_comments(session)
    assert_equal 1, stored.size, "the comment is suppressed, not hidden"
    assert_equal 5145406778, stored.first["id"]
  end

  test "poll_comments_for_session defers a comment younger than the attribution grace period" do
    session = trusted_pr_session
    stub_actionable_builder
    Open3.expects(:capture3).never

    TestJobWithFreshComment.new.send(:poll_comments_for_session, session)

    assert_equal 0, session.reload.enqueued_messages.count
    assert_equal "deferred", stored_pr_comments(session).first["dispatch_state"]
  end

  test "poll_comments_for_session dispatches a deferred human comment once it ages past the grace period" do
    session = trusted_pr_session
    stub_actionable_builder
    job = TestJobWithFreshComment.new
    job.define_singleton_method(:add_eyes_reaction) { |_info| nil }

    job.send(:poll_comments_for_session, session)
    assert_equal "deferred", stored_pr_comments(session).first["dispatch_state"]

    travel (GithubCommentPollerJob::ATTRIBUTION_GRACE_SECONDS + 1).seconds do
      job.send(:poll_comments_for_session, session)
    end

    assert_equal 1, session.reload.enqueued_messages.count
    assert_equal "dispatched", stored_pr_comments(session).first["dispatch_state"]
  end

  test "poll_comments_for_session suppresses a deferred comment the authorship hook claims during the grace period" do
    # The race the grace period exists for: the poller sees the comment before
    # TranscriptHooks::GithubCommentAuthorshipHook has recorded who posted it.
    session = trusted_pr_session
    stub_actionable_builder
    job = TestJobWithFreshComment.new

    job.send(:poll_comments_for_session, session)
    assert_equal "deferred", stored_pr_comments(session).first["dispatch_state"]

    AgentPostedGithubComment.record!(session: sessions(:running), comment_type: "pr", comment_id: 5145406778)

    Open3.expects(:capture3).never
    travel (GithubCommentPollerJob::ATTRIBUTION_GRACE_SECONDS + 1).seconds do
      job.send(:poll_comments_for_session, session)
    end

    assert_equal 0, session.reload.enqueued_messages.count
    assert_equal "skipped:agent_posted", stored_pr_comments(session).first["dispatch_state"]
  end

  test "poll_comments_for_session leaves a terminal dispatch_state alone on later polls" do
    session = trusted_pr_session
    stub_actionable_builder
    job = TestJobWithNonWhitelistedComment.new

    job.send(:poll_comments_for_session, session)
    stored = stored_pr_comments(session)
    assert_equal "skipped:author_not_whitelisted", stored.first["dispatch_state"]

    # A second poll must not re-open a decision that was already made.
    job.send(:poll_comments_for_session, session)
    assert_equal 1, stored_pr_comments(session).size
    assert_equal "skipped:author_not_whitelisted", stored_pr_comments(session).first["dispatch_state"]
    assert_equal 0, session.reload.enqueued_messages.count
  end

  test "poll_comments_for_session records why a comment with the agent marker was skipped" do
    session = trusted_pr_session
    stub_actionable_builder

    TestJobWithAgentComment.new.send(:poll_comments_for_session, session)

    assert_equal "skipped:self_marker", stored_pr_comments(session).first["dispatch_state"]
  end

  test "poll_comments_for_session dispatches a human comment when nothing claims it" do
    session = trusted_pr_session
    stub_actionable_builder
    job = TestJobWithWhitelistedComment.new
    job.define_singleton_method(:add_eyes_reaction) { |_info| nil }

    job.send(:poll_comments_for_session, session)

    assert_equal 1, session.reload.enqueued_messages.count
    assert_equal "dispatched", stored_pr_comments(session).first["dispatch_state"]
  end

  test "an agent-authorship lookup failure fails open rather than swallowing the comment" do
    session = trusted_pr_session
    stub_actionable_builder
    AgentPostedGithubComment.stubs(:posted_by_agent).raises(ActiveRecord::StatementInvalid, "connection lost")

    job = TestJobWithWhitelistedComment.new
    job.define_singleton_method(:add_eyes_reaction) { |_info| nil }
    job.send(:poll_comments_for_session, session)

    assert_equal 1, session.reload.enqueued_messages.count
  end
  # A comment on a repo whose visibility `gh` cannot report.
  class TestJobWithUnknownVisibilityComment < GithubCommentPollerJob
    def created_at
      @created_at ||= 5.minutes.ago.iso8601
    end

    def fetch_pr_comments(_owner, _repo, _pr_number)
      [
        {
          "id" => 4242,
          "user" => { "login" => "tadasant" },
          "body" => "Please fix this",
          "html_url" => "https://github.com/tadasant/zimmer/pull/123#issuecomment-4242",
          "created_at" => created_at
        }
      ]
    end

    def fetch_review_comments(_owner, _repo, _pr_number)
      []
    end
  end

  test "a transient repo-visibility failure defers the comment instead of dropping it" do
    session = trusted_pr_session

    failing_builder = mock
    failing_builder.stubs(:actionable?).returns(false)
    failing_builder.stubs(:visibility_lookup_failed?).returns(true)
    GithubCommentPromptBuilder.stubs(:new).returns(failing_builder)

    job = TestJobWithUnknownVisibilityComment.new
    job.send(:poll_comments_for_session, session)

    assert_equal 0, session.reload.enqueued_messages.count
    assert_equal "deferred", stored_pr_comments(session).first["dispatch_state"]

    # Once `gh` answers, the same comment goes out rather than having been lost.
    stub_actionable_builder
    job.define_singleton_method(:add_eyes_reaction) { |_info| nil }
    job.send(:poll_comments_for_session, session)

    assert_equal 1, session.reload.enqueued_messages.count
    assert_equal "dispatched", stored_pr_comments(session).first["dispatch_state"]
  end

  test "a repo-visibility failure stops being retried once the comment ages out" do
    session = trusted_pr_session

    failing_builder = mock
    failing_builder.stubs(:actionable?).returns(false)
    failing_builder.stubs(:visibility_lookup_failed?).returns(true)
    GithubCommentPromptBuilder.stubs(:new).returns(failing_builder)

    job = TestJobWithUnknownVisibilityComment.new
    job.created_at # stamp the comment's age now, so travelling ages the comment itself

    travel (GithubCommentPollerJob::VISIBILITY_RETRY_WINDOW_SECONDS + 60).seconds do
      job.send(:poll_comments_for_session, session)
    end

    assert_equal "skipped:visibility_unknown", stored_pr_comments(session).first["dispatch_state"]
  end

  test "a public repo outside our control is still terminal, not retried" do
    session = trusted_pr_session

    public_builder = mock
    public_builder.stubs(:actionable?).returns(false)
    public_builder.stubs(:visibility_lookup_failed?).returns(false)
    GithubCommentPromptBuilder.stubs(:new).returns(public_builder)

    job = TestJobWithWhitelistedComment.new
    job.send(:poll_comments_for_session, session)

    assert_equal "skipped:not_actionable", stored_pr_comments(session).first["dispatch_state"]
  end

  test "the comment is persisted before it is dispatched, so a mid-dispatch death is terminal" do
    session = trusted_pr_session
    stub_actionable_builder

    job = TestJobWithWhitelistedComment.new
    # Die where the process would: after the pre-dispatch write, inside the handover.
    job.define_singleton_method(:enqueue_follow_up_prompt) { |_s, _i| raise Interrupt }

    assert_raises(Interrupt) { job.send(:poll_comments_for_session, session) }

    assert_equal "dispatching", stored_pr_comments(session).first["dispatch_state"],
      "the comment must be on record before the handover, so it is not re-dispatched forever"

    # A later poll leaves that terminal state alone.
    TestJobWithWhitelistedComment.new.send(:poll_comments_for_session, session)
    assert_equal "dispatching", stored_pr_comments(session).first["dispatch_state"]
    assert_equal 0, session.reload.enqueued_messages.count
  end

  # ---- Nil subprocess status (ZombieReaperJob reaped the gh child) ----
  #
  # ZombieReaperJob runs `Process.waitpid(-1, WNOHANG)` in the same worker process as
  # this poller. When it reaps a `gh` child before Open3.capture3's own waiter thread
  # does, that thread's waitpid gets ECHILD and `wait_thr.value` returns nil, so
  # capture3 returns `[stdout, stderr, nil]`. `status.success?` on that nil is what
  # crashed the tick in production and paged. These pin the nil path as a plain
  # failure: warn, retry next tick, never raise, never ERROR.

  test "fetch_paginated_comments treats a nil status as a failed fetch instead of raising" do
    Open3.stubs(:capture3).returns([ "", "gh: connection reset", nil ])

    job = GithubCommentPollerJob.new

    result = nil
    assert_nothing_raised do
      result = job.send(:fetch_paginated_comments, "repos/owner/repo/issues/1/comments")
    end

    # No comments were read this tick, so the caller gets the same "nothing to act on"
    # answer a non-zero exit already produces — retry on the next poll.
    assert_nil result
  end

  test "fetch_paginated_comments logs the reaped child distinctly from a non-zero exit" do
    Open3.stubs(:capture3).returns([ "", "gh: connection reset", nil ])

    warnings = capture_warn_logs do
      GithubCommentPollerJob.new.send(:fetch_paginated_comments, "repos/owner/repo/issues/1/comments")
    end

    warning = warnings.find { |line| line.include?("Failed to fetch comments") }
    assert warning, "expected a warn line naming the failed fetch, got: #{warnings.inspect}"
    # "we never learned the exit code" must not read as "gh returned non-zero".
    assert_includes warning, SubprocessStatus::REAPED_DESCRIPTION
    # stderr is still populated on the reaped path; only the exit code is lost.
    assert_includes warning, "gh: connection reset"
  end

  test "fetch_paginated_comments returns the pages it already read when a later page is reaped" do
    # A full first page makes the loop ask for page 2; page 2 loses the race with the reaper.
    full_page = Array.new(GithubCommentPollerJob::MAX_COMMENTS_PER_PAGE) do |i|
      { "id" => i + 1, "user" => { "login" => "someone" }, "body" => "hi" }
    end
    Open3.stubs(:capture3)
      .returns([ full_page.to_json, "", success_status ])
      .then.returns([ "", "", nil ])

    result = GithubCommentPollerJob.new.send(:fetch_paginated_comments, "repos/owner/repo/issues/1/comments")

    assert_equal GithubCommentPollerJob::MAX_COMMENTS_PER_PAGE, result.length
    assert_equal 1, result.first["id"]
  end

  test "add_eyes_reaction does not raise on a nil status" do
    Open3.stubs(:capture3).returns([ "", "", nil ])

    comment_info = {
      type: "pr",
      owner: "testowner",
      repo: "testrepo",
      pr_number: "42",
      data: { "id" => 11111, "author" => "tadasant" }
    }

    assert_nothing_raised do
      GithubCommentPollerJob.new.send(:add_eyes_reaction, comment_info)
    end
  end

  test "perform emits no ERROR record when gh children are reaped mid-poll" do
    @session_with_pr.update!(
      metadata: (@session_with_pr.metadata || {}).merge("last_user_activity_at" => 5.minutes.ago.iso8601)
    )
    Session.stubs(:with_github_prs).returns(Session.where(id: @session_with_pr.id))

    # Every gh call this tick loses the race with the reaper.
    Open3.stubs(:capture3).returns([ "", "gh: connection reset", nil ])

    # This is the regression: the crash surfaced as
    # "[GithubCommentPollerJob] Error polling comments for session N: undefined method
    # 'success?' for nil" from the per-session rescue in #perform, which is what paged.
    errors = capture_error_logs do
      assert_nothing_raised { GithubCommentPollerJob.perform_now }
    end

    assert_empty errors, "a reaped gh child must not produce an ERROR record — that is what paged"
  end

  def success_status
    Struct.new(:ok) do
      def success? = true
    end.new(true)
  end

  # Collects the strings passed to Rails.logger.warn during the block.
  def capture_warn_logs(&block)
    capture_logs_at(:warn, &block)
  end

  # Collects the strings passed to Rails.logger.error during the block.
  def capture_error_logs(&block)
    capture_logs_at(:error, &block)
  end

  def capture_logs_at(level)
    captured = []
    Rails.logger.stubs(level).with { |message| captured << message.to_s; true }
    yield
    captured
  end
end
