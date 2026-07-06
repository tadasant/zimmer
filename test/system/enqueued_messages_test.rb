require "application_system_test_case"

class EnqueuedMessagesTest < ApplicationSystemTestCase
  # Test viewing enqueued messages list
  test "should not show enqueued messages section when no messages exist" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Should not see the enqueued messages header since there are no messages
    assert_no_selector "h3", text: "Queued Messages"
  end

  test "should show enqueued messages list when messages exist" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    # Create some enqueued messages
    session.enqueued_messages.create!(content: "First message", position: 1)
    session.enqueued_messages.create!(content: "Second message", position: 2)

    visit session_path(session)

    # Should see the enqueued messages section
    assert_selector "h3", text: "Queued Messages"
    assert_selector ".bg-indigo-100", text: "2" # Badge showing count
    assert_text "Will be sent automatically when the agent requests input"
  end

  test "should display enqueued messages in order by position" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    # Create messages out of order to verify ordering
    session.enqueued_messages.create!(content: "Third message", position: 3)
    session.enqueued_messages.create!(content: "First message", position: 1)
    session.enqueued_messages.create!(content: "Second message", position: 2)

    visit session_path(session)

    # Messages should be displayed in position order
    # Check that position badges are in order (1, 2, 3)
    position_badges = all(".h-6.w-6.rounded-full.bg-indigo-100")
    assert_equal 3, position_badges.count
    assert_equal "1", position_badges[0].text
    assert_equal "2", position_badges[1].text
    assert_equal "3", position_badges[2].text
  end

  # Test deleting an enqueued message
  test "should delete enqueued message via delete button" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    message = session.enqueued_messages.create!(content: "Message to delete", position: 1)

    visit session_path(session)

    # Should see the message
    assert_selector "h3", text: "Queued Messages"
    assert_selector ".bg-indigo-100", text: "1"

    # Click delete button (with confirmation) using js_click to bypass flash overlay
    accept_confirm do
      delete_button = find("#enqueued_message_#{message.id} button[title='Delete message']")
      js_click(delete_button)
    end

    # Message section should disappear (no more queued messages)
    assert_no_selector "h3", text: "Queued Messages"

    # Verify message was deleted from database
    session.reload
    assert_equal 0, session.enqueued_messages.count
  end

  # Note: Deletion UI tested via controller tests (EnqueuedMessagesControllerTest)
  # System test skipped due to flaky click interception issues in headless Chrome
  test "should show delete button for enqueued messages" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    session.enqueued_messages.create!(content: "Test message", position: 1)

    visit session_path(session)

    # Verify delete button is present
    assert_selector "button[title='Delete message']"
  end

  # Test sending an enqueued message via interrupt button
  test "should send enqueued message immediately via Send Now button" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    message = session.enqueued_messages.create!(content: "Interrupt message", position: 1)

    visit session_path(session)

    # Click the "Send Now" interrupt button using js_click to bypass flash overlay
    send_now_button = find("#enqueued_message_#{message.id} button", text: "Send Now")
    js_click(send_now_button)

    # Change filter to "Show Logs" to see log entries (default "minimal" hides logs)
    select "Show Logs", from: "log-level-filter"

    # Wait for the log to appear in the timeline (broadcast via Turbo Streams)
    # Should see the log entry for the interrupt (shown in timeline)
    assert_text "Enqueued message sent as interrupt via web: Interrupt message", wait: 5

    # Message should be removed from queue
    assert_no_selector "h3", text: "Queued Messages"

    # Verify message was deleted and session transitioned
    session.reload
    assert_equal 0, session.enqueued_messages.count
    assert_equal "running", session.status
  end

  # Test accordion expand/collapse functionality
  # Note: Accordion expand/collapse tested via JS click to avoid flaky click interception
  test "should expand and collapse message content via accordion" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    full_content = "This is the full message content that should be revealed when expanded"
    session.enqueued_messages.create!(content: full_content, position: 1)

    visit session_path(session)

    # Content target should be initially hidden
    content_div = find('[data-enqueued-message-accordion-target="content"]', visible: :hidden)
    assert content_div[:class].include?("hidden")

    # Click on the toggle button to expand using JS click to bypass interception
    toggle_button = find('[data-action="click->enqueued-message-accordion#toggle"]')
    js_click(toggle_button)

    # Wait for content to be visible
    assert_selector '[data-enqueued-message-accordion-target="content"]:not(.hidden)', visible: true

    # Should see the full content
    assert_text full_content

    # Click again to collapse using JS click
    toggle_button = find('[data-action="click->enqueued-message-accordion#toggle"]')
    js_click(toggle_button)

    # Content should be hidden again
    assert_selector '[data-enqueued-message-accordion-target="content"].hidden', visible: :hidden
  end

  # Test message with goal shows it in expanded view
  test "should display goal in expanded message view" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    session.enqueued_messages.create!(
      content: "Test message",
      goal: "wait for user approval",
      position: 1
    )

    visit session_path(session)

    # Expand the message using JS click to bypass interception
    toggle_button = find('[data-action="click->enqueued-message-accordion#toggle"]')
    js_click(toggle_button)

    # Should see the goal
    assert_text "Goal:"
    assert_text "wait for user approval"
  end

  # Test that messages without goal don't show goal section
  test "should not display goal section when message has no goal" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    message = session.enqueued_messages.create!(
      content: "Test message without goal",
      position: 1
    )

    visit session_path(session)

    # Expand the message using JS click to bypass interception
    toggle_button = find('[data-action="click->enqueued-message-accordion#toggle"]')
    js_click(toggle_button)

    # Should NOT see the goal label inside the message accordion.
    # (The session metadata bar always renders "Goal: None" — that's a separate
    # concern from the message-level goal display this test cares about.)
    within("#enqueued_message_#{message.id}") do
      assert_no_text "Goal:"
    end
  end

  # Test viewing multiple messages - simplified to avoid flaky click interactions
  # Full workflow (delete, interrupt) is tested in controller tests
  test "complete enqueued messages workflow - viewing multiple messages" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Initially no enqueued messages
    assert_no_selector "h3", text: "Queued Messages"

    # Create messages directly (simulating backend creation)
    session.enqueued_messages.create!(content: "First task", position: 1)
    session.enqueued_messages.create!(content: "Second task", position: 2)
    session.enqueued_messages.create!(content: "Third task", position: 3)

    # Refresh page to see messages
    visit session_path(session)

    # Should see the enqueued messages section with count
    assert_selector "h3", text: "Queued Messages"
    assert_selector ".bg-indigo-100", text: "3"

    # Expand first message to see content using JS click
    first_toggle = all('[data-action="click->enqueued-message-accordion#toggle"]').first
    js_click(first_toggle)
    assert_text "First task"

    # All three position badges should be visible
    assert_selector ".rounded-full.bg-indigo-100", text: "1"
    assert_selector ".rounded-full.bg-indigo-100", text: "2"
    assert_selector ".rounded-full.bg-indigo-100", text: "3"

    # Delete and interrupt buttons should be present
    assert_selector "button[title='Delete message']", count: 3
    assert_selector "button", text: "Send Now", count: 3
  end

  test "should show enqueued messages for running session" do
    session = Session.create!(
      prompt: "Test",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
    session.enqueued_messages.create!(content: "Message for running session", position: 1)

    visit session_path(session)
    assert_selector "h3", text: "Queued Messages"
    assert_text "Message for running session"
  end

  test "should show enqueued messages for waiting session" do
    session = Session.create!(
      prompt: "Test",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )
    session.enqueued_messages.create!(content: "Message for waiting session", position: 1)

    visit session_path(session)
    assert_selector "h3", text: "Queued Messages"
    assert_text "Message for waiting session"
  end

  # Test truncated content in collapsed view
  test "should show truncated content in collapsed view for long messages" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    long_content = "A" * 150 # Content longer than truncate limit of 100
    session.enqueued_messages.create!(content: long_content, position: 1)

    visit session_path(session)

    # Should see truncated content (100 chars + "...")
    truncated_text = find(".truncate").text
    assert truncated_text.length < long_content.length
    assert truncated_text.include?("...")
  end

  # Test drag handle is visible for reordering
  test "should display drag handle for reordering" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    session.enqueued_messages.create!(content: "Test message", position: 1)

    visit session_path(session)

    # Should see drag handle with cursor-move class
    assert_selector ".cursor-move"
  end

  # Test that messages are draggable
  test "messages should have draggable attribute" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    session.enqueued_messages.create!(content: "Draggable message", position: 1)

    visit session_path(session)

    # Find the draggable element
    draggable = find('[draggable="true"]')
    assert_not_nil draggable
  end
end
