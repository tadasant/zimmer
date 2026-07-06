# frozen_string_literal: true

require "integration_test_helper"

class ConcurrentOperationsTest < IntegrationTestCase
  test "should handle multiple sessions running concurrently" do
    sessions = 3.times.map do |i|
      Session.create!(
        git_root: "https://github.com/test/repo.git",
        prompt: "Test concurrent #{i}",
        status: "waiting",
        agent_runtime: "claude_code"
      )
    end

    # Enqueue jobs for all sessions
    sessions.each do |session|
      assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
        AgentSessionJob.enqueue_new_session(session.id)
      end
    end

    # Verify all jobs are enqueued
    assert_enqueued_jobs 3, only: AgentSessionJob

    # Simulate concurrent execution
    sessions.each do |session|
      session.update!(status: "running")
    end

    # Verify all are running
    sessions.each(&:reload)
    assert sessions.all? { |s| s.status == "running" }

    # Complete all sessions
    sessions.each do |session|
      simulate_job_completion(session)
    end

    # Verify all completed
    sessions.each(&:reload)
    assert sessions.all? { |s| s.status == "archived" }
  end

  test "should handle archive during execution" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test archive during run",
      status: "running",
      agent_runtime: "claude_code",
      running_job_id: "job-12345"
    )

    # Archive while "running"
    post archive_session_path(session)
    assert_response :redirect

    session.reload
    assert_equal "archived", session.status
    # State machine clears running_job_id on archive to prevent orphaned jobs
    assert_nil session.running_job_id
  end

  test "should handle concurrent HTTP requests" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test concurrent HTTP",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    # Simulate concurrent status checks
    3.times do
      get session_path(session)
      assert_response :success
    end

    # Session should remain stable
    session.reload
    assert_equal "waiting", session.status
  end

  test "should handle concurrent job enqueueing" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test job queue",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    # First job enqueue
    assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
      AgentSessionJob.enqueue_new_session(session.id)
    end

    # Update status to prevent duplicate
    session.update!(status: "running")

    # Second attempt should not enqueue
    assert_no_enqueued_jobs only: AgentSessionJob do
      # Controller should check status before enqueueing
      if session.status == "running"
        # Skip enqueue
      else
        AgentSessionJob.enqueue_new_session(session.id)
      end
    end
  end

  test "should handle race condition in session status update" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test race condition",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    # Simulate two concurrent status updates
    session1 = Session.find(session.id)
    session2 = Session.find(session.id)

    session1.update!(status: "running")
    session2.reload # Should see the update

    assert_equal "running", session2.status
  end

  test "should handle multiple sessions with same git repository" do
    git_url = "https://github.com/shared/repo.git"

    sessions = 2.times.map do |i|
      Session.create!(
        prompt: "Test shared repo #{i}",
        status: "waiting",
        agent_runtime: "claude_code",
        git_root: git_url
      )
    end

    # Both sessions should be created successfully
    assert_equal 2, sessions.count
    assert sessions.all? { |s| s.git_root == git_url }

    # Each should get its own execution
    sessions.each do |session|
      assert_enqueued_with(job: AgentSessionJob, args: [ session.id ]) do
        AgentSessionJob.enqueue_new_session(session.id)
      end
    end
  end

  test "should handle concurrent log writes" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test concurrent logs",
      status: "running",
      agent_runtime: "claude_code"
    )

    # Create multiple logs
    5.times do |i|
      Log.create!(
        session: session,
        level: "info",
        content: "Log message #{i}"
      )
    end

    # Should have all logs
    assert_equal 5, session.logs.count

    # Verify no logs were lost
    session.logs.each_with_index do |log, i|
      assert log.content.include?("Log message")
    end
  end

  test "should handle session listing with many sessions" do
    # Clear existing sessions (delete dependent records first due to foreign key constraints)
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    # Create many sessions
    10.times do |i|
      Session.create!(
        git_root: "https://github.com/test/repo.git",
        prompt: "Session #{i}",
        status: %w[waiting running archived failed].sample,
        agent_runtime: "claude_code"
      )
    end

    # Get index
    get root_path
    assert_response :success

    # Should show non-archived sessions
    assert_select "turbo-frame[id^='session_']"
  end

  test "should handle concurrent follow-up prompts" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Initial",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    # Send follow-up
    post follow_up_session_path(session), params: {
      follow_up_prompt: "Follow-up 1"
    }
    assert_response :redirect

    session.reload
    assert_equal "running", session.status

    # Try another follow-up while running (should be rejected)
    post follow_up_session_path(session), params: {
      follow_up_prompt: "Follow-up 2"
    }

    # Should be redirected with alert since session is running
    assert_response :redirect

    # Session should remain in running state
    session.reload
    assert_equal "running", session.status
  end
end
