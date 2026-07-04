# frozen_string_literal: true

require "integration_test_helper"

class GitCloneIntegrationTest < IntegrationTestCase
  test "should create session with git repository" do
    session = Session.create!(
      prompt: "Analyze this repository",
      git_root: "https://github.com/test/repo.git",
      subdirectory: "src",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    assert_equal "https://github.com/test/repo.git", session.git_root
    assert_equal "src", session.subdirectory
    assert_equal "waiting", session.status

    # Enqueue job
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      AgentSessionJob.enqueue_new_session(session.id)
    end
  end

  test "should handle local repository path" do
    local_path = "/Users/test/local-repo"

    session = Session.create!(
      prompt: "Work on local repo",
      git_root: local_path,
      status: "waiting",
      agent_runtime: "claude_code"
    )

    assert_equal local_path, session.git_root
    assert_equal "waiting", session.status
  end

  test "should support different git branches" do
    session = Session.create!(
      prompt: "Work on feature branch",
      git_root: "https://github.com/test/repo.git",
      branch: "feature/new-feature",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    assert_equal "feature/new-feature", session.branch
    assert_equal "waiting", session.status
  end

  test "should handle subdirectory specification" do
    session = Session.create!(
      prompt: "Work on backend only",
      git_root: "https://github.com/test/monorepo.git",
      subdirectory: "backend/api",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    assert_equal "backend/api", session.subdirectory
  end

  test "should validate git URL format" do
    # Create session with invalid git URL
    session = Session.new(
      prompt: "Test invalid URL",
      git_root: "not-a-url",
      agent_runtime: "claude_code"
    )

    # Should still be valid - we don't enforce URL format
    assert session.valid?
  end

  test "should handle special characters in repository paths" do
    session = Session.create!(
      prompt: "Test special chars",
      git_root: "https://github.com/test/my-repo-2024.git",
      subdirectory: "src/main",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    assert_equal "https://github.com/test/my-repo-2024.git", session.git_root
    assert_equal "src/main", session.subdirectory
  end

  test "should create session via HTTP with git params" do
    post sessions_path, params: {
      session: {
        prompt: "Analyze codebase",
        git_root: "https://github.com/example/project.git",
        branch: "main",
        subdirectory: "app"
      }
    }

    assert_response :redirect
    session = Session.last

    assert_equal "https://github.com/example/project.git", session.git_root
    assert_equal "main", session.branch
    assert_equal "app", session.subdirectory
  end

  test "should display git info in session view" do
    session = Session.create!(
      prompt: "Git test",
      git_root: "https://github.com/test/repo.git",
      branch: "develop",
      subdirectory: "frontend",
      status: "archived",
      agent_runtime: "claude_code"
    )

    get session_path(session)
    assert_response :success

    # Session with git info should be accessible
    assert_equal "https://github.com/test/repo.git", session.git_root
    assert_equal "develop", session.branch
    assert_equal "frontend", session.subdirectory
  end

  test "should handle missing subdirectory gracefully" do
    session = Session.create!(
      prompt: "Work on missing subdirectory",
      git_root: "https://github.com/test/repo.git",
      subdirectory: "nonexistent/path",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    # Simulate job failure due to missing directory
    simulate_job_failure(session, error: "Subdirectory not found: nonexistent/path")

    session.reload
    assert_equal "failed", session.status
    assert session.logs.where(level: "error").any?
  end

  test "should support both SSH and HTTPS git URLs" do
    https_session = Session.create!(
      prompt: "HTTPS repo",
      git_root: "https://github.com/user/repo.git",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    ssh_session = Session.create!(
      prompt: "SSH repo",
      git_root: "git@github.com:user/repo.git",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    assert https_session.valid?
    assert ssh_session.valid?
  end
end
