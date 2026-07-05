require "test_helper"
require "minitest/mock"

class GithubCommentPromptBuilderTest < ActiveSupport::TestCase
  setup do
    @session = sessions(:with_pr_url)
  end

  test "builds prompt with correct header for PR comments" do
    comment_info = build_comment_info(
      type: "pr",
      body: "Can you explain this?",
      author: "tadasant"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)
    prompt = builder.build

    assert_includes prompt, "## GitHub Comment Response Required"
    assert_includes prompt, "**User:** tadasant"
    assert_includes prompt, "**Comment type:** PR comment"
    assert_includes prompt, "**Comment URL:** https://github.com/owner/repo/pull/123#issuecomment-999"
    assert_includes prompt, "**PR:** https://github.com/owner/repo/pull/123"
  end

  test "builds prompt with correct header for inline review comments" do
    comment_info = build_comment_info(
      type: "review",
      body: "This looks wrong",
      author: "macoughl",
      path: "src/main.rb",
      line: 42,
      diff_hunk: "@@ -40,3 +40,5 @@\n def foo\n end"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)
    prompt = builder.build

    assert_includes prompt, "**Comment type:** inline review comment"
    assert_includes prompt, "**File:** `src/main.rb`"
    assert_includes prompt, "**Line:** 42"
    assert_includes prompt, "```diff\n@@ -40,3 +40,5 @@\n def foo\n end\n```"
  end

  test "builds prompt with intent instructions for agent to determine" do
    comment_info = build_comment_info(
      type: "pr",
      body: "Why did you implement it this way?",
      author: "tadasant"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)
    prompt = builder.build

    # Should include instructions for both question and change request scenarios
    assert_includes prompt, "Read the user's comment carefully and determine what they're asking for"
    assert_includes prompt, "**If the user is asking a question**"
    assert_includes prompt, "**If the user is requesting a code change**"
    assert_includes prompt, "Do NOT make code changes unless explicitly requested"
    assert_includes prompt, "Create a **single commit**"
    assert_includes prompt, "[CC Says]"
  end

  test "includes quoted user comment in prompt" do
    comment_info = build_comment_info(
      type: "pr",
      body: "This is my comment\nwith multiple lines",
      author: "tadasant"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)
    prompt = builder.build

    assert_includes prompt, "### User's Comment"
    assert_includes prompt, "> This is my comment\n> with multiple lines"
  end

  test "includes gh command examples for PR comments" do
    comment_info = build_comment_info(
      type: "pr",
      body: "Nice work!",
      author: "tadasant"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)
    prompt = builder.build

    assert_includes prompt, "gh pr comment"
    assert_includes prompt, "[CC Says]"
  end

  test "includes gh api command example for inline review comments" do
    comment_info = build_comment_info(
      type: "review",
      body: "Fix this",
      author: "macoughl",
      path: "test.rb",
      line: 10,
      diff_hunk: "@@ code"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)
    prompt = builder.build

    assert_includes prompt, "gh api repos/"
    assert_includes prompt, "in_reply_to="
  end

  test "fetches thread context for review comments with in_reply_to_id" do
    # Set up existing comments in the thread
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_comments" => {
        "https://github.com/owner/repo/pull/123" => {
          "pr_comments" => [],
          "review_comments" => [
            { "id" => 100, "author" => "macoughl", "body" => "Original comment", "created_at" => "2025-01-01T12:00:00Z", "in_reply_to_id" => nil },
            { "id" => 101, "author" => "tadasant", "body" => "Reply to original", "created_at" => "2025-01-01T12:05:00Z", "in_reply_to_id" => 100 }
          ]
        }
      }
    })

    comment_info = build_comment_info(
      type: "review",
      body: "Another reply",
      author: "macoughl",
      in_reply_to_id: 100
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)
    context = builder.send(:fetch_thread_context, comment_info[:data])

    assert_includes context, "Previous comments in this thread"
    assert_includes context, "Original comment"
    assert_includes context, "Reply to original"
  end

  test "fetches all previous comments context for PR comments" do
    @session.update!(custom_metadata: {
      "github_pull_request_urls" => [ "https://github.com/owner/repo/pull/123" ],
      "github_comments" => {
        "https://github.com/owner/repo/pull/123" => {
          "pr_comments" => [
            { "id" => 1, "author" => "user1", "body" => "First comment", "created_at" => "2025-01-01T12:00:00Z" },
            { "id" => 2, "author" => "user2", "body" => "Second comment", "created_at" => "2025-01-01T12:05:00Z" },
            { "id" => 3, "author" => "user3", "body" => "Third comment", "created_at" => "2025-01-01T12:10:00Z" }
          ],
          "review_comments" => []
        }
      }
    })

    # New comment after the existing ones
    comment_info = build_comment_info(
      type: "pr",
      body: "New comment",
      author: "tadasant",
      created_at: "2025-01-01T12:15:00Z"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)
    context = builder.send(:fetch_pr_comment_thread_context, comment_info[:data])

    # Should include ALL previous comments, not just the last 3
    assert_includes context, "Previous comments on this PR"
    assert_includes context, "First comment"
    assert_includes context, "Second comment"
    assert_includes context, "Third comment"
  end

  test "appends public repo warning when repo is public" do
    comment_info = build_comment_info(
      type: "pr",
      body: "Please fix this bug",
      author: "tadasant"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)

    # Stub public_repo? to return true
    builder.stub(:public_repo?, true) do
      prompt = builder.build

      assert_includes prompt, "PUBLIC REPOSITORY NOTICE"
      assert_includes prompt, "You should NOT make any public-facing changes"
      assert_includes prompt, "explicit review and approval by a human"
      assert_includes prompt, "\"Continue\" is not sufficient approval"
      assert_includes prompt, "**DO** still do all the exploring"
      assert_includes prompt, "**DO NOT** execute public-facing actions"
    end
  end

  test "does not append public repo warning when repo is private" do
    comment_info = build_comment_info(
      type: "pr",
      body: "Please fix this bug",
      author: "tadasant"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)

    # Stub public_repo? to return false
    builder.stub(:public_repo?, false) do
      prompt = builder.build

      refute_includes prompt, "PUBLIC REPOSITORY NOTICE"
      refute_includes prompt, "explicit review and approval by a human"
    end
  end

  test "public_repo? returns true for public repositories" do
    comment_info = build_comment_info(
      type: "pr",
      body: "Test",
      author: "tadasant"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)

    # Mock the Open3.capture3 call to return private=false (i.e., public repo)
    Open3.stub(:capture3, [ "false\n", "", mock_success_status ]) do
      assert builder.send(:public_repo?)
    end
  end

  test "public_repo? returns false for private repositories" do
    comment_info = build_comment_info(
      type: "pr",
      body: "Test",
      author: "tadasant"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)

    # Mock the Open3.capture3 call to return private=true
    Open3.stub(:capture3, [ "true\n", "", mock_success_status ]) do
      refute builder.send(:public_repo?)
    end
  end

  test "public_repo? returns true when API call fails to err on side of caution" do
    comment_info = build_comment_info(
      type: "pr",
      body: "Test",
      author: "tadasant"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)

    # Mock the Open3.capture3 call to return failure
    # When API fails, treat as public to require approval (safer during outages)
    Open3.stub(:capture3, [ "", "Not Found", mock_failure_status ]) do
      assert builder.send(:public_repo?)
    end
  end

  test "public_repo? caches result to avoid repeated API calls" do
    comment_info = build_comment_info(
      type: "pr",
      body: "Test",
      author: "tadasant"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)

    call_count = 0
    mock_capture3 = ->(* args) {
      call_count += 1
      [ "false\n", "", mock_success_status ]
    }

    Open3.stub(:capture3, mock_capture3) do
      # Call twice
      result1 = builder.send(:public_repo?)
      result2 = builder.send(:public_repo?)

      assert result1
      assert result2
      assert_equal 1, call_count, "API should only be called once due to caching"
    end
  end

  test "public_repo? returns false when owner or repo is missing" do
    comment_info = {
      type: "pr",
      data: { "id" => 999, "author" => "test", "body" => "test", "url" => "http://example.com", "created_at" => "2025-01-01" },
      pr_url: "https://github.com/owner/repo/pull/123",
      owner: nil,  # Missing owner
      repo: "repo",
      pr_number: "123"
    }

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)
    refute builder.send(:public_repo?)
  end

  test "public_repo? returns false when owner or repo is empty string" do
    comment_info = {
      type: "pr",
      data: { "id" => 999, "author" => "test", "body" => "test", "url" => "http://example.com", "created_at" => "2025-01-01" },
      pr_url: "https://github.com/owner/repo/pull/123",
      owner: "",  # Empty string owner
      repo: "repo",
      pr_number: "123"
    }

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)
    refute builder.send(:public_repo?)
  end

  test "public_repo? returns true when exception is raised to err on side of caution" do
    comment_info = build_comment_info(
      type: "pr",
      body: "Test",
      author: "tadasant"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)

    # Mock Open3.capture3 to raise an exception
    # When exception occurs, treat as public to require approval (safer during outages)
    Open3.stub(:capture3, ->(*) { raise StandardError, "Connection failed" }) do
      assert builder.send(:public_repo?)
    end
  end

  test "public_repo? caches exception result to avoid repeated API calls" do
    comment_info = build_comment_info(
      type: "pr",
      body: "Test",
      author: "tadasant"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)

    call_count = 0
    mock_capture3_raise = ->(*) {
      call_count += 1
      raise StandardError, "Connection failed"
    }

    Open3.stub(:capture3, mock_capture3_raise) do
      # Call twice - first raises exception, second should use cached result
      result1 = builder.send(:public_repo?)
      result2 = builder.send(:public_repo?)

      assert result1
      assert result2
      assert_equal 1, call_count, "API should only be called once even after exception (cached)"
    end
  end

  test "public_repo? returns false for pulsemcp-owned repos without API call" do
    comment_info = build_comment_info_with_owner(
      type: "pr",
      body: "Test",
      author: "tadasant",
      owner: "zimmer",
      repo: "agents"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)

    call_count = 0
    mock_capture3 = ->(*) {
      call_count += 1
      [ "false\n", "", mock_success_status ]  # Would return public
    }

    Open3.stub(:capture3, mock_capture3) do
      refute builder.send(:public_repo?), "pulsemcp repos should be treated as trusted (no warning)"
      assert_equal 0, call_count, "API should not be called for trusted owners"
    end
  end

  test "public_repo? returns false for tadasant-owned repos without API call" do
    comment_info = build_comment_info_with_owner(
      type: "pr",
      body: "Test",
      author: "someone",
      owner: "tadasant",
      repo: "some-repo"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)

    call_count = 0
    mock_capture3 = ->(*) {
      call_count += 1
      [ "false\n", "", mock_success_status ]  # Would return public
    }

    Open3.stub(:capture3, mock_capture3) do
      refute builder.send(:public_repo?), "tadasant repos should be treated as trusted (no warning)"
      assert_equal 0, call_count, "API should not be called for trusted owners"
    end
  end

  test "public_repo? trusted owner check is case-insensitive for uppercase" do
    comment_info = build_comment_info_with_owner(
      type: "pr",
      body: "Test",
      author: "someone",
      owner: "PULSEMCP",  # uppercase
      repo: "some-repo"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)

    call_count = 0
    mock_capture3 = ->(*) {
      call_count += 1
      [ "false\n", "", mock_success_status ]
    }

    Open3.stub(:capture3, mock_capture3) do
      refute builder.send(:public_repo?), "Trusted owner check should be case-insensitive"
      assert_equal 0, call_count, "API should not be called for trusted owners"
    end
  end

  test "public_repo? trusted owner check is case-insensitive for mixed case" do
    comment_info = build_comment_info_with_owner(
      type: "pr",
      body: "Test",
      author: "someone",
      owner: "PulseMCP",  # mixed case
      repo: "some-repo"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)

    call_count = 0
    mock_capture3 = ->(*) {
      call_count += 1
      [ "false\n", "", mock_success_status ]
    }

    Open3.stub(:capture3, mock_capture3) do
      refute builder.send(:public_repo?), "Trusted owner check should be case-insensitive for mixed case"
      assert_equal 0, call_count, "API should not be called for trusted owners"
    end
  end

  test "public_repo? still checks API for non-trusted owners" do
    comment_info = build_comment_info_with_owner(
      type: "pr",
      body: "Test",
      author: "tadasant",
      owner: "some-other-org",
      repo: "some-repo"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)

    call_count = 0
    mock_capture3 = ->(*) {
      call_count += 1
      [ "false\n", "", mock_success_status ]  # Public repo
    }

    Open3.stub(:capture3, mock_capture3) do
      assert builder.send(:public_repo?), "Non-trusted public repos should show warning"
      assert_equal 1, call_count, "API should be called for non-trusted owners"
    end
  end

  test "does not append public repo warning for pulsemcp-owned repos" do
    comment_info = build_comment_info_with_owner(
      type: "pr",
      body: "Please fix this bug",
      author: "tadasant",
      owner: "zimmer",
      repo: "agents"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)
    prompt = builder.build

    refute_includes prompt, "PUBLIC REPOSITORY NOTICE", "pulsemcp repos should not show warning"
  end

  test "does not append public repo warning for tadasant-owned repos" do
    comment_info = build_comment_info_with_owner(
      type: "pr",
      body: "Please fix this bug",
      author: "someone",
      owner: "tadasant",
      repo: "my-project"
    )

    builder = GithubCommentPromptBuilder.new(session: @session, comment_info: comment_info)
    prompt = builder.build

    refute_includes prompt, "PUBLIC REPOSITORY NOTICE", "tadasant repos should not show warning"
  end

  private

  def mock_success_status
    status = Minitest::Mock.new
    status.expect(:success?, true)
    status
  end

  def mock_failure_status
    status = Minitest::Mock.new
    status.expect(:success?, false)
    status
  end

  def build_comment_info(type:, body:, author:, path: nil, line: nil, diff_hunk: nil, in_reply_to_id: nil, created_at: "2025-01-01T12:00:00Z")
    build_comment_info_with_owner(
      type: type,
      body: body,
      author: author,
      owner: "owner",
      repo: "repo",
      path: path,
      line: line,
      diff_hunk: diff_hunk,
      in_reply_to_id: in_reply_to_id,
      created_at: created_at
    )
  end

  def build_comment_info_with_owner(type:, body:, author:, owner:, repo:, path: nil, line: nil, diff_hunk: nil, in_reply_to_id: nil, created_at: "2025-01-01T12:00:00Z")
    data = {
      "id" => 999,
      "author" => author,
      "attribution" => author,
      "body" => body,
      "url" => "https://github.com/#{owner}/#{repo}/pull/123#issuecomment-999",
      "created_at" => created_at
    }

    if type == "review"
      data["path"] = path || "test.rb"
      data["line"] = line || 1
      data["diff_hunk"] = diff_hunk || "@@ code"
      data["in_reply_to_id"] = in_reply_to_id
      data["url"] = "https://github.com/#{owner}/#{repo}/pull/123#discussion_r999"
    end

    {
      type: type,
      data: data,
      pr_url: "https://github.com/#{owner}/#{repo}/pull/123",
      owner: owner,
      repo: repo,
      pr_number: "123"
    }
  end
end
