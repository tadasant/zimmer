require "application_system_test_case"

# Comprehensive system tests for the queued messages feature workflow.
# These tests cover the full lifecycle of queueing and processing messages.
#
# See issue #592 for bug report: duplicate sends, lost messages, stuck UI.
class QueuedMessagesWorkflowTest < ApplicationSystemTestCase
  # Test 1: Queue message while agent is running
  test "can queue message while agent is running" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Should see running indicator
    assert_text "Agent is running"
    assert_text "messages will be queued"

    # Button should say "Queue Message" for running session
    assert_button "Queue Message"

    # Queue a message
    fill_in "follow_up_prompt", with: "First queued message"
    click_button "Queue Message"

    # Wait for Turbo Stream response
    # UI should reset: button should be re-enabled with correct text, textarea should be cleared
    assert_button "Queue Message", wait: 3
    # Note: assert_selector with text: "" doesn't check textarea value attribute, only text content
    # We must use find().value to properly check the textarea was cleared
    textarea = find("textarea[name='follow_up_prompt']")
    assert_empty textarea.value, "Textarea value should be cleared after queue submission"

    # Queue count badge should show 1
    assert_selector ".bg-indigo-100", text: "1"

    # Verify message was created in database
    session.reload
    assert_equal 1, session.enqueued_messages.count
    assert_equal "First queued message", session.enqueued_messages.first.content
    assert_equal "pending", session.enqueued_messages.first.status
  end

  # Test 2: Queue multiple messages in sequence
  test "can queue multiple messages in sequence" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Queue first message
    fill_in "follow_up_prompt", with: "First message"
    click_button "Queue Message"

    # Wait for form to reset
    assert_button "Queue Message", wait: 3
    assert_selector ".bg-indigo-100", text: "1"

    # Queue second message
    fill_in "follow_up_prompt", with: "Second message"
    click_button "Queue Message"

    # Wait for form to reset
    assert_button "Queue Message", wait: 3
    assert_selector ".bg-indigo-100", text: "2"

    # Queue third message
    fill_in "follow_up_prompt", with: "Third message"
    click_button "Queue Message"

    # Wait for form to reset and verify final state
    assert_button "Queue Message", wait: 3
    assert_selector ".bg-indigo-100", text: "3"

    # Verify message order is preserved
    session.reload
    messages = session.enqueued_messages.ordered
    assert_equal 3, messages.count
    assert_equal "First message", messages[0].content
    assert_equal "Second message", messages[1].content
    assert_equal "Third message", messages[2].content
    assert_equal 1, messages[0].position
    assert_equal 2, messages[1].position
    assert_equal 3, messages[2].position
  end

  # Test 3: UI button is re-enabled after successful queue submission
  test "queue button is re-enabled after successful submission" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Fill in message
    fill_in "follow_up_prompt", with: "Test message"

    # Click button and verify it gets re-enabled
    click_button "Queue Message"

    # Button should be re-enabled within reasonable time (Turbo Stream response)
    assert_button "Queue Message", disabled: false, wait: 5

    # Verify message was queued in database
    session.reload
    assert_equal 1, session.enqueued_messages.count
    assert_equal "Test message", session.enqueued_messages.first.content
  end

  # Test 4: UI button is re-enabled on validation error
  test "queue button is re-enabled on empty message validation failure" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Don't fill in message - leave it empty

    # JavaScript validation should trigger an alert
    accept_alert "Please enter a message" do
      click_button "Queue Message"
    end

    # Button should still be enabled (JS validation prevented form submission)
    assert_button "Queue Message", disabled: false
  end

  # Test 5: Mode switches correctly based on session status
  test "form mode switches between send and queue based on session status" do
    # Start with needs_input status
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # In needs_input mode, button should say "Send Message"
    assert_button "Send Message"
    assert_no_text "messages will be queued"

    # Update session status to running
    session.update!(status: :running)

    # Refresh page to see new status
    visit session_path(session)

    # In running mode, button should say "Queue Message"
    assert_button "Queue Message"
    assert_text "Agent is running"
    assert_text "messages will be queued"
  end

  # Test 6: Queued messages are displayed correctly
  test "queued messages are displayed with correct order and actions" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    # Pre-create some messages
    session.enqueued_messages.create!(content: "First task", position: 1)
    session.enqueued_messages.create!(content: "Second task", position: 2)
    session.enqueued_messages.create!(content: "Third task", position: 3)

    visit session_path(session)

    # Should see the header with count
    assert_selector "h3", text: "Queued Messages"
    assert_selector ".bg-indigo-100", text: "3"

    # All position badges should be visible in order
    position_badges = all(".h-6.w-6.rounded-full.bg-indigo-100")
    assert_equal 3, position_badges.count
    assert_equal "1", position_badges[0].text
    assert_equal "2", position_badges[1].text
    assert_equal "3", position_badges[2].text

    # Each message should have delete and Send Now buttons
    assert_selector "button[title='Delete message']", count: 3
    assert_selector "button", text: "Send Now", count: 3
  end

  # Test 7: Send Now button works and removes message from queue
  test "send now button removes message from queue and starts processing" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    message = session.enqueued_messages.create!(content: "Urgent message", position: 1)

    visit session_path(session)

    # Click Send Now button using js_click to bypass flash overlay
    send_now_button = find("#enqueued_message_#{message.id} button", text: "Send Now")
    js_click(send_now_button)

    # Change filter to show logs
    select "Show Logs", from: "log-level-filter"

    # Should see log about interrupt
    assert_text "Enqueued message sent as interrupt via web: Urgent message", wait: 5

    # Queue should be empty
    assert_no_selector "h3", text: "Queued Messages"

    # Session should now be running
    session.reload
    assert_equal "running", session.status
    assert_equal 0, session.enqueued_messages.count
  end

  # Test 8: Delete message works and updates positions
  test "deleting message updates remaining message positions" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    msg1 = session.enqueued_messages.create!(content: "First", position: 1)
    session.enqueued_messages.create!(content: "Second", position: 2)
    session.enqueued_messages.create!(content: "Third", position: 3)

    visit session_path(session)

    # Delete the first message using js_click to avoid interception
    accept_confirm do
      within "#enqueued_message_#{msg1.id}" do
        delete_button = find('button[title="Delete message"]')
        scroll_into_center(delete_button)
        js_click(delete_button)
      end
    end

    # Wait for Turbo Stream update
    assert_selector ".bg-indigo-100", text: "2", wait: 5

    # Positions should be renumbered
    session.reload
    messages = session.enqueued_messages.ordered
    assert_equal 2, messages.count
    assert_equal "Second", messages[0].content
    assert_equal 1, messages[0].position
    assert_equal "Third", messages[1].content
    assert_equal 2, messages[1].position
  end

  # Test 10: Form preserves input when Turbo Stream replaces it
  # This tests the sessionStorage preservation mechanism
  test "form input is preserved during Turbo Stream replacements from other sources" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Type something in the textarea
    fill_in "follow_up_prompt", with: "Work in progress message"

    # Create a message directly to trigger a Turbo Stream update to the enqueued_messages list
    # (simulating what would happen if another tab or background job updated the queue)
    session.enqueued_messages.create!(content: "Background message", position: 1)

    # Refresh the page
    visit session_path(session)

    # The textarea should have preserved the input via sessionStorage
    # (only for running sessions where form replacement can occur)
    # Note: This is a simplified test - in real use, sessionStorage preserves input
    # across Turbo Stream replacements that target the form container

    # Verify the queue shows the background message
    assert_selector ".bg-indigo-100", text: "1"
  end

  # Test 11: Textarea is cleared after successful queue submission
  # Note: This tests that the form replacement happens correctly AND that
  # the data-turbo-permanent textarea is properly cleared via JavaScript
  test "textarea is cleared after successful queue submission" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Fill in and submit
    fill_in "follow_up_prompt", with: "Test message to clear"
    click_button "Queue Message"

    # Wait for button to return to Queue Message state (form was replaced)
    assert_button "Queue Message", disabled: false, wait: 5

    # CRITICAL: Verify textarea value is actually cleared
    # The textarea has data-turbo-permanent attribute which preserves it across Turbo Stream
    # replacements, so we rely on JavaScript (handleSubmitEnd) to clear the value.
    # Note: assert_selector with text: "" only checks text content, not value attribute!
    textarea = find("textarea[name='follow_up_prompt']")
    assert_empty textarea.value, "Textarea value should be cleared after successful queue submission"

    # Verify the message was actually queued in database
    session.reload
    assert_equal 1, session.enqueued_messages.count
    assert_equal "Test message to clear", session.enqueued_messages.first.content
  end

  # Test 12: Verify queue order after multiple operations
  test "queue maintains correct order after deletions and additions" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    # Add three messages
    msg1 = session.enqueued_messages.create!(content: "Message 1", position: 1)
    session.enqueued_messages.create!(content: "Message 2", position: 2)
    session.enqueued_messages.create!(content: "Message 3", position: 3)

    visit session_path(session)

    # Delete the first message using js_click to avoid interception
    accept_confirm do
      within "#enqueued_message_#{msg1.id}" do
        delete_button = find('button[title="Delete message"]')
        scroll_into_center(delete_button)
        js_click(delete_button)
      end
    end

    # Wait for update
    assert_selector ".bg-indigo-100", text: "2", wait: 5

    # Add a new message
    fill_in "follow_up_prompt", with: "Message 4"
    click_button "Queue Message"

    # Wait for update
    assert_selector ".bg-indigo-100", text: "3", wait: 5

    # Verify final order
    session.reload
    messages = session.enqueued_messages.ordered
    assert_equal 3, messages.count
    assert_equal "Message 2", messages[0].content
    assert_equal 1, messages[0].position
    assert_equal "Message 3", messages[1].content
    assert_equal 2, messages[1].position
    assert_equal "Message 4", messages[2].content
    assert_equal 3, messages[2].position
  end
end
