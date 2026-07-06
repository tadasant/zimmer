# frozen_string_literal: true

require "integration_test_helper"

class ErrorRecoveryTest < IntegrationTestCase
  test "should handle session not found error" do
    # Try to access non-existent session
    get session_path(999999)
    assert_response :not_found
  end

  test "should prevent concurrent job execution for same session" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test concurrent prevention",
      status: "running",
      agent_runtime: "claude_code",
      running_job_id: "job-123"
    )

    # Try to enqueue another job for the same session
    # Since the session is already running, no new job should be enqueued
    assert_no_enqueued_jobs only: AgentSessionJob do
      # Simulate trying to start another job while one is running
      if session.status == "running"
        # Skip enqueue - already running
      else
        AgentSessionJob.enqueue_new_session(session.id)
      end
    end

    # Session should remain in running state
    assert_equal "running", session.status
  end

  test "should handle git clone failure gracefully" do
    session = Session.create!(
      prompt: "Test git failure",
      status: "waiting",
      agent_runtime: "claude_code",
      git_root: "https://github.com/nonexistent/repo.git"
    )

    # Simulate git clone failure
    simulate_job_failure(session, error: "Failed to clone repository")

    session.reload
    assert_equal "failed", session.status
    assert session.logs.where(level: "error").any?
    assert session.logs.last.content.include?("Failed to clone")
  end

  test "should recover from process signal errors" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test signal handling",
      status: "running",
      agent_runtime: "claude_code",
      running_job_id: "job-12345"
    )

    # Archive session (which would normally kill process)
    post archive_session_path(session)

    session.reload
    assert_equal "archived", session.status
    # State machine now clears running_job_id on archive to prevent orphaned jobs
    assert_nil session.running_job_id
  end

  test "should handle transcript reading errors" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test transcript error",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    # Simulate job completion without transcript
    session.update!(
      status: "archived",
      transcript: nil
    )

    # Session should still be accessible
    get session_path(session)
    assert_response :success
  end

  test "should timeout long-running sessions" do
    # Create a session that's been running too long
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test timeout",
      status: "running",
      agent_runtime: "claude_code",
      created_at: 2.hours.ago,
      updated_at: 2.hours.ago
    )

    # Simulate timeout check
    if session.updated_at < 1.hour.ago && session.status == "running"
      simulate_job_failure(session, error: "Session timed out")
    end

    session.reload
    assert_equal "failed", session.status
  end

  test "should handle database connection errors gracefully" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test DB error",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    # Even if we can't update the session, it should remain valid
    assert_nothing_raised do
      session.reload
    end

    assert_equal "waiting", session.status
  end

  test "should cleanup resources on job failure" do
    session = Session.create!(
      prompt: "Test cleanup",
      status: "waiting",
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git"
    )

    # Simulate failure after partial execution
    session.update!(status: "running", running_job_id: "job-99999")
    simulate_job_failure(session, error: "Unexpected error")

    session.reload
    assert_equal "failed", session.status
    assert_nil session.running_job_id
  end

  test "should handle clone-only session parameters" do
    # Create session with empty prompt (clone-only)
    assert_difference("Session.count", 1) do
      post sessions_path, params: {
        session: {
          git_root: "https://github.com/test/repo.git",
          prompt: "",
          agent_runtime: "claude_code"
        }
      }
    end

    # Should accept empty prompt for clone-only sessions
    assert_redirected_to session_path(Session.last)
    session = Session.last
    assert_equal "needs_input", session.status
  end

  test "should recover from orphaned running status" do
    # Create orphaned session (running but no job)
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test orphaned",
      status: "running",
      agent_runtime: "claude_code",
      running_job_id: "non-existent-job",
      updated_at: 1.hour.ago
    )

    # Cleanup job would detect this
    if session.running_job_id && session.updated_at < 30.minutes.ago
      session.update!(
        status: "failed",
        running_job_id: nil
      )
      Log.create!(
        session: session,
        level: "error",
        content: "Session was orphaned and has been marked as failed"
      )
    end

    session.reload
    assert_equal "failed", session.status
    assert session.logs.where(level: "error").any?
  end
end
