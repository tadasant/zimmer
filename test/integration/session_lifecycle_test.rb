# frozen_string_literal: true

require "integration_test_helper"

class SessionLifecycleTest < IntegrationTestCase
  test "complete session workflow from creation to completion" do
    # Step 1: Create session via HTTP
    post sessions_path, params: {
      session: {
        prompt: "Build user authentication",
        mcp_servers: [],
        git_root: "https://github.com/test/repo.git"
      }
    }

    assert_response :redirect
    session = Session.last
    # Sessions start in waiting state; the job transitions them to running
    assert_equal "waiting", session.status
    assert_equal "Build user authentication", session.prompt

    # Step 2: Simulate job processing
    simulate_job_completion(session)

    session.reload
    assert_equal "archived", session.status
    assert session.logs.any?
    assert_not_nil session.transcript
  end

  test "session workflow with process failure" do
    post sessions_path, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "Test failure",
        mcp_servers: []
      }
    }
    session = Session.last

    # Simulate process failure
    simulate_job_failure(session, error: "Process exited with code 1")

    session.reload
    assert_equal "failed", session.status
    assert session.logs.where(level: "error").any?
  end

  test "session with follow-up prompt" do
    # Create initial session in waiting status (required for follow_up action)
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Initial prompt",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    # Send follow-up via HTTP
    post follow_up_session_path(session), params: {
      follow_up_prompt: "Follow-up question"
    }

    assert_response :redirect
    session.reload

    assert_equal "running", session.status

    # Verify job is enqueued
    assert_enqueued_jobs 1, only: AgentSessionJob
  end

  test "session transitions through expected states" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test transitions",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    # Transition to running
    session.update!(status: "running", running_job_id: "job-123")
    assert_equal "running", session.status

    # Transition to archived
    simulate_job_completion(session)
    assert_equal "archived", session.status
  end

  test "session with MCP servers configuration" do
    mcp_servers = [ "playwright-custom", "twist-wolfbot" ]

    post sessions_path, params: {
      session: {
        git_root: "https://github.com/test/repo.git",
        prompt: "Test with MCP",
        mcp_servers: mcp_servers
      }
    }

    session = Session.last
    assert_equal mcp_servers, session.mcp_servers

    # Verify session is created with proper config
    assert_not_nil session
    # Sessions start in waiting state; the job transitions them to running
    assert_equal "waiting", session.status
  end

  test "session archive during execution" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test archive",
      status: "running",
      agent_runtime: "claude_code"
    )

    # Archive the session
    post archive_session_path(session)
    assert_response :redirect

    session.reload
    assert_equal "archived", session.status
  end

  test "session creation with git repository and subdirectory" do
    post sessions_path, params: {
      session: {
        prompt: "Work on backend",
        git_root: "https://github.com/test/monorepo.git",
        subdirectory: "backend"
      }
    }

    session = Session.last
    assert_equal "https://github.com/test/monorepo.git", session.git_root
    assert_equal "backend", session.subdirectory
    # Sessions start in waiting state; the job transitions them to running
    assert_equal "waiting", session.status
  end

  test "session logs are created during execution" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test logging",
      status: "waiting",
      agent_runtime: "claude_code"
    )

    initial_log_count = session.logs.count

    # Simulate execution with logs
    Log.create!(session: session, level: "info", content: "Starting job")
    Log.create!(session: session, level: "info", content: "Processing")
    simulate_job_completion(session)

    session.reload
    assert session.logs.count > initial_log_count,
           "Logs should be created during execution"

    # Verify log levels
    log_levels = session.logs.pluck(:level).uniq
    assert log_levels.include?("info"), "Should have info logs"
  end

  test "session creation allows clone-only sessions without prompt" do
    # Create session without prompt (clone-only)
    assert_difference("Session.count", 1) do
      post sessions_path, params: {
        session: {
          git_root: "https://github.com/test/repo.git",
          prompt: "",
          mcp_servers: []
        }
      }
    end

    # Should create clone-only session successfully
    assert_redirected_to session_path(Session.last)
    session = Session.last
    assert_equal "needs_input", session.status
    assert session.prompt.blank?
  end

  test "session shows correct status in listing" do
    # Clear any existing sessions from database first
    # Delete dependent records first due to foreign key constraints
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    # Create sessions in different states
    waiting = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Waiting", status: "waiting", agent_runtime: "claude_code")
    running = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Running", status: "running", agent_runtime: "claude_code")
    archived = Session.create!(git_root: "https://github.com/test/repo.git", prompt: "Archived", status: "archived", agent_runtime: "claude_code")

    # Get index (shows only non-archived by default)
    get root_path

    assert_response :success

    # Verify non-archived sessions are shown (2 sessions, not 3)
    # Use selector that matches per-session turbo-frame tags (session_<id>),
    # excluding the dashboard's session detail drawer frame (session_detail).
    assert_select "turbo-frame[id^='session_']:not(#session_detail)", 2

    # Get index with archived sessions
    get root_path(show_archived: true)

    assert_response :success

    # Verify all sessions are shown when showing archived
    assert_select "turbo-frame[id^='session_']:not(#session_detail)", 3
  end

  # Tests for Issue #586: Enqueued messages auto-processing

  test "enqueued message is processed when session has dirty state from AASM update_all" do
    # Create a running session
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Initial prompt",
      status: "running",
      agent_runtime: "claude_code"
    )

    # Queue a message for this session
    message = session.enqueued_messages.create!(
      content: "Follow-up from queue",
      position: 1,
      status: "pending"
    )

    # Explicitly simulate what AASM does with skip_validation_on_save:
    # 1. update_all to persist to DB (bypasses ActiveRecord dirty tracking clear)
    # 2. write_attribute to update in-memory value (marks attribute as changed)
    # This creates a "dirty" state where the record thinks it has unpersisted changes
    Session.where(id: session.id).update_all(status: "needs_input")
    session.send(:write_attribute, :status, "needs_input")

    # Verify the session is in the expected dirty state
    assert session.changed?, "Session should have dirty state"

    job = AgentSessionJob.new
    log_buffer = LogBuffer.new(session)

    # Before the fix, this would fail with:
    # "Locking a record with unpersisted changes is not supported"
    # The fix adds session.reload BEFORE session.lock! to clear dirty state
    result = job.send(:process_next_enqueued_message_if_available, session, log_buffer)

    # Verify the message was processed
    assert result, "Expected enqueued message to be processed"
    assert_nil EnqueuedMessage.find_by(id: message.id), "Message should be deleted after processing"

    # Verify session transitioned back to running
    session.reload
    assert_equal "running", session.status

    # Verify a new job was enqueued for the message
    assert_enqueued_jobs 1, only: AgentSessionJob
  end

  test "enqueued message with goal updates session goal when processed" do
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Initial prompt",
      status: "needs_input",
      agent_runtime: "claude_code",
      goal: nil
    )

    # Queue a message with a goal
    session.enqueued_messages.create!(
      content: "Run until CI passes",
      position: 1,
      status: "pending",
      goal: "CI pipeline passes successfully"
    )

    job = AgentSessionJob.new
    log_buffer = LogBuffer.new(session)

    job.send(:process_next_enqueued_message_if_available, session, log_buffer)

    # Verify goal was propagated to session
    session.reload
    assert_equal "CI pipeline passes successfully", session.goal
  end

  test "multiple enqueued messages are processed in order" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: "needs_input",
      agent_runtime: "claude_code",
      session_id: SecureRandom.uuid,
      git_root: "https://github.com/test/repo.git",
      execution_provider: "local_filesystem"
    )

    # Create messages out of order to test position-based sorting
    msg3 = session.enqueued_messages.create!(content: "Third", position: 3, status: "pending")
    msg1 = session.enqueued_messages.create!(content: "First", position: 1, status: "pending")
    msg2 = session.enqueued_messages.create!(content: "Second", position: 2, status: "pending")

    job = AgentSessionJob.new
    log_buffer = LogBuffer.new(session)

    # Process first message (should enqueue a job for the message)
    result = job.send(:process_next_enqueued_message_if_available, session, log_buffer)
    assert result, "Expected message to be processed. Logs: #{session.logs.pluck(:content).join('; ')}"

    # Verify first message (position 1) was processed
    assert_nil EnqueuedMessage.find_by(id: msg1.id), "First message should be deleted"
    assert_not_nil EnqueuedMessage.find_by(id: msg2.id), "Second message should still exist"
    assert_not_nil EnqueuedMessage.find_by(id: msg3.id), "Third message should still exist"

    # Verify remaining messages were renumbered
    msg2.reload
    msg3.reload
    assert_equal 1, msg2.position
    assert_equal 2, msg3.position
  end
end
