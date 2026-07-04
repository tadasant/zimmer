require "application_system_test_case"

class SessionsPauseTest < ApplicationSystemTestCase
  # Test pause button visibility
  test "pause button is visible for running session" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Should see the pause link (styled as button, uses link_to with data-turbo-method)
    assert_link "Pause"
  end

  test "pause button is not visible for waiting session" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Should NOT see the pause link
    assert_no_link "Pause"
  end

  test "pause button is not visible for needs_input session" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Should NOT see the pause link
    assert_no_link "Pause"
  end

  test "pause button is not visible for failed session" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :failed,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Should NOT see the pause link
    assert_no_link "Pause"
  end

  test "pause button is not visible for archived session" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :archived,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Should NOT see the pause link
    assert_no_link "Pause"
  end

  # Test pause action with process_pid
  test "pausing session with process_pid shows success message" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      metadata: { "process_pid" => 999999 } # Fake PID that doesn't exist
    )

    visit session_path(session)

    # Click the pause link - use click_link to properly trigger Turbo's data-turbo-method handling
    click_link "Pause"

    # Wait for page to update and show success message
    # Use a longer wait time since redirect/page update can take time
    assert_text "Session paused successfully", wait: 5

    # Session should now be in needs_input status
    session.reload
    assert_equal "needs_input", session.status
  end

  # Test pause action without process_pid
  test "pausing session without process_pid shows error message" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
      # No process_pid in metadata
    )

    visit session_path(session)

    # Click the pause link - use click_link to properly trigger Turbo's data-turbo-method handling
    click_link "Pause"

    # Should see error message about no process found
    assert_text "Cannot pause session: no process found", wait: 5

    # Session should still be in running status
    session.reload
    assert_equal "running", session.status
  end

  # Test that follow-up input is always visible (now sticky) and running indicator disappears after pause
  test "follow-up input is visible and running indicator disappears after pausing session" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      metadata: { "process_pid" => 999999 } # Fake PID that doesn't exist
    )

    visit session_path(session)

    # Should see follow-up input (now always visible for non-archived sessions)
    assert_selector "textarea[name='follow_up_prompt']"
    # Should see running indicator
    assert_text "Agent is running"

    # Click the pause link - use click_link to properly trigger Turbo's data-turbo-method handling
    click_link "Pause"

    # Should see success message
    assert_text "Session paused successfully", wait: 5

    # Should now see the follow-up input
    assert_selector "textarea[name='follow_up_prompt']"
  end
end
