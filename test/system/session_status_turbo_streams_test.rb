require "application_system_test_case"

class SessionStatusTurboStreamsTest < ApplicationSystemTestCase
  # Test that status badge updates via Turbo Streams when session transitions from running to needs_input
  test "status badge updates via turbo stream when session transitions from running to needs_input" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)
    wait_for_turbo_streams_connected

    # Verify initial state shows Running in the status badge
    status_badge = find("[id='session_#{session.id}_status_badge']")
    assert_equal "Running", status_badge.text.strip

    # Trigger state change from background (simulating job completion)
    session.update!(status: :needs_input)

    # Verify Turbo Stream updates the status badge without page refresh
    assert_selector "[id='session_#{session.id}_status_badge']", text: "Needs Input", wait: 5
  end

  # Test that running indicator in follow-up form disappears when session transitions to needs_input
  test "running indicator in follow-up form disappears via turbo stream when session transitions to needs_input" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)
    wait_for_turbo_streams_connected

    # Verify running indicator is visible in the follow-up form (check for "will be queued" text)
    within "[id='session_#{session.id}_follow_up_form']" do
      assert_text "will be queued"
    end

    # Trigger state change
    session.update!(status: :needs_input)

    # Verify running indicator hint disappears from follow-up form without refresh
    within "[id='session_#{session.id}_follow_up_form']" do
      assert_no_text "will be queued", wait: 5
    end
  end

  # Test that pause button disappears when session transitions to needs_input
  test "pause button disappears via turbo stream when session transitions to needs_input" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)
    wait_for_turbo_streams_connected

    # Verify Pause link is visible for running session
    assert_link "Pause"

    # Trigger state change
    session.update!(status: :needs_input)

    # Verify Pause link disappears without refresh
    assert_no_link "Pause", wait: 5
  end

  # Test that all status elements update together when session status changes
  test "all status elements update together when session status changes" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)
    wait_for_turbo_streams_connected

    # Verify all running indicators
    assert_selector "[id='session_#{session.id}_status_badge']", text: "Running"
    within "[id='session_#{session.id}_follow_up_form']" do
      assert_text "will be queued"
    end
    assert_link "Pause"

    # Trigger state change
    session.update!(status: :needs_input)

    # ALL elements should update (test they're consistent)
    assert_selector "[id='session_#{session.id}_status_badge']", text: "Needs Input", wait: 5
    within "[id='session_#{session.id}_follow_up_form']" do
      assert_no_text "will be queued"
    end
    assert_no_link "Pause"
  end

  # Test status updates when transitioning to failed state
  test "status updates via turbo stream when session fails" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)
    wait_for_turbo_streams_connected

    assert_selector "[id='session_#{session.id}_status_badge']", text: "Running"

    session.update!(status: :failed)

    # Should show Failed status and Restart link
    assert_selector "[id='session_#{session.id}_status_badge']", text: "Failed", wait: 5
    assert_link "Restart"
    assert_no_link "Pause"
  end

  # Test that follow-up form updates properly (running indicator visibility within form)
  test "follow-up form running indicator updates when session transitions" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)
    wait_for_turbo_streams_connected

    # Verify running indicator shows "will be queued" hint in the follow-up form
    within "[id='session_#{session.id}_follow_up_form']" do
      assert_text "will be queued"
    end

    # Trigger state change
    session.update!(status: :needs_input)

    # After transitioning to needs_input, the "will be queued" hint should disappear
    within "[id='session_#{session.id}_follow_up_form']" do
      assert_no_text "will be queued", wait: 5
    end
  end

  # Test that Turbo Stream broadcasts work when using AASM events (pause!, fail!, etc.)
  # AASM uses save() which triggers after_update_commit callbacks for broadcasts.
  test "status updates via turbo stream when using AASM pause! event" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)
    wait_for_turbo_streams_connected

    # Verify initial state shows Running
    assert_selector "[id='session_#{session.id}_status_badge']", text: "Running"
    assert_link "Pause"

    # Use AASM event instead of direct update! - this is how the application
    # actually transitions states (e.g., when AgentSessionJob calls session.pause!)
    session.pause!

    # Verify Turbo Stream updates work with AASM events
    assert_selector "[id='session_#{session.id}_status_badge']", text: "Needs Input", wait: 5
    assert_no_link "Pause"
  end

  test "status updates via turbo stream when using AASM fail! event" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)
    wait_for_turbo_streams_connected

    assert_selector "[id='session_#{session.id}_status_badge']", text: "Running"

    # Use AASM event
    session.fail!

    # Verify Turbo Stream updates work with AASM events
    assert_selector "[id='session_#{session.id}_status_badge']", text: "Failed", wait: 5
    assert_link "Restart"
  end
end
