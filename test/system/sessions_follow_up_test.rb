require "application_system_test_case"

class SessionsFollowUpTest < ApplicationSystemTestCase
  # Test follow-up input UI visibility
  test "follow-up input is visible for waiting session" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Should see the follow-up input
    assert_selector "label", text: "Follow-up Prompt"
    assert_selector "textarea[name='follow_up_prompt']"
    # Button text is set by Stimulus controller based on session status
    assert_button "Send Message"
  end

  test "follow-up input is visible for needs_input session" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Should see the follow-up input
    assert_selector "label", text: "Follow-up Prompt"
    assert_selector "textarea[name='follow_up_prompt']"
    # Button text is set by Stimulus controller based on session status
    assert_button "Send Message"
  end

  test "follow-up input is visible for running session with running indicator" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Should see the follow-up input (now always visible for non-archived sessions)
    assert_selector "textarea[name='follow_up_prompt']"
    assert_text "Follow-up Prompt"
    # Should see running indicator above the form
    assert_text "Agent is running"
    assert_text "messages will be queued"
  end

  test "follow-up input is not visible for archived session" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :archived,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Should NOT see the follow-up input
    assert_no_selector "textarea[name='follow_up_prompt']"
    assert_no_text "Follow-up Prompt"
  end

  # Test submitting follow-up prompts
  test "submitting follow-up prompt via button" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Fill in the follow-up prompt
    fill_in "follow_up_prompt", with: "Please continue with the implementation"

    # Click submit button
    click_button "Send Message"

    # The optimistic message should appear in the timeline (via Turbo Stream, no
    # page reload).
    assert_text "Please continue with the implementation"

    # `waiting`, not `running`: since #1040 the follow-up hands the turn to the
    # `agents` queue and a worker's `start` is what makes the session `running`.
    # The running indicator and the composer's queue mode both follow the turn
    # rather than the submit, so neither is asserted here — this test is about the
    # optimistic message and the hand-over.
    session.reload
    assert_equal "waiting", session.status
    assert_equal "Please continue with the implementation",
      session.metadata["pending_follow_up_prompt"],
      "the accepted prompt has to be on the row for the turn that picks it up"
  end

  test "cannot submit empty follow-up prompt" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Verify the textarea exists but without required attribute
    # (validation is now done via JavaScript instead of HTML5 validation)
    assert_selector "textarea[name='follow_up_prompt']"
    assert_no_selector "textarea[name='follow_up_prompt'][required]"

    # Try to submit without filling in the prompt
    # JavaScript validation in follow-up-prompt controller should show alert
    accept_alert "Please enter a follow-up prompt" do
      click_button "Send Message"
    end

    # Should still be on the same page
    assert_current_path session_path(session)
  end

  test "follow-up prompt supports multi-line input" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # The textarea should have multiple rows
    assert_selector "textarea[name='follow_up_prompt'][rows='3']"

    # Fill in multi-line prompt
    multi_line_prompt = "Line 1\nLine 2\nLine 3"
    fill_in "follow_up_prompt", with: multi_line_prompt

    click_button "Send Message"

    # The multi-line message should appear in the timeline
    assert_text "Line 1"
    assert_text "Line 2"
    assert_text "Line 3"
    assert_equal "waiting", session.reload.status,
      "the follow-up queues the turn for a worker (#1040)"
  end

  test "follow-up input has helpful label and instructions" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Should see label with instructions
    assert_text "Follow-up Prompt"
    assert_text "Cmd+Enter to submit"
  end

  test "follow-up input has placeholder text" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Should see placeholder text
    assert_selector "textarea[placeholder*='Enter your follow-up prompt']"
    assert_selector "textarea[placeholder*='markdown']"
  end

  # Test complete workflow
  test "complete follow-up workflow" do
    # Create a session in waiting status
    session = Session.create!(
      prompt: "Build a user authentication system",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    # Visit the session page
    visit session_path(session)

    # Prompt is no longer displayed on session detail page per Issue pulsemcp/agents#57
    # Should see session info instead
    assert_text "Model:"

    # Should see the follow-up input
    assert_selector "textarea[name='follow_up_prompt']"

    # Enter a follow-up prompt
    fill_in "follow_up_prompt", with: "Now add password reset functionality"

    # Submit the form
    click_button "Send Message"

    # The optimistic message should appear in the timeline (via Turbo Stream, no page reload)
    # This verifies the fix for the disappearing optimistic message bug
    assert_text "Now add password reset functionality"

    # Should still be on the session page (no redirect with Turbo Stream)
    assert_current_path session_path(session)

    # The turn is handed over and queued for a worker (#1040); `running` waits for
    # a worker to spawn its process, which no system test has.
    session.reload
    assert_equal "waiting", session.status
    assert_equal "Now add password reset functionality",
      session.metadata["pending_follow_up_prompt"]
  end

  # Test undo functionality for follow-up prompts via keyboard shortcut
  # Note: Visual undo button was removed; undo is available via Ctrl/Cmd+Z when textarea is empty
  test "undo via keyboard shortcut when textarea is empty" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Fill in and submit a follow-up prompt
    original_message = "Keyboard shortcut test message"
    fill_in "follow_up_prompt", with: original_message
    click_button "Send Message"

    # Wait for the optimistic message to appear in the timeline (Turbo Stream response)
    assert_text original_message

    # Change session back to needs_input and clear sent_message
    # (sent_message is for recovery when message wasn't confirmed in transcript;
    # this test is specifically for the undo feature, so clear it to test undo in isolation)
    # Need to reload first to get the metadata that was set during the follow-up submission
    session.reload
    session.update!(status: :needs_input, metadata: session.metadata&.except("sent_message", "sent_message_at") || {})
    visit session_path(session)

    # Find the textarea and make sure it's focused
    textarea = find("textarea[name='follow_up_prompt']")
    textarea.click

    # Ensure textarea is empty (no sent_message recovery, so undo can be tested)
    assert_equal "", textarea.value

    # Press Ctrl+Z (works on both Linux CI and Mac)
    # Note: On Mac, Ctrl+Z also triggers undo in our implementation since we check for both
    textarea.send_keys([ :control, "z" ])

    # The textarea should now contain the original message
    assert_equal original_message, textarea.value
  end
end
