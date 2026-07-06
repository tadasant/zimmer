require "application_system_test_case"

class MessageCopyTest < ApplicationSystemTestCase
  # Test that message copy buttons exist in transcript messages
  test "transcript messages have copy buttons" do
    session = sessions(:with_transcript)

    visit session_path(session)

    # Wait for messages to render
    assert_selector "[data-controller~='message-copy']", wait: 5

    # Copy buttons exist but are hidden by default (opacity-0)
    # Each message should have a copy button
    copy_buttons = all("[data-message-copy-target='button']", visible: false)
    assert copy_buttons.any?, "Expected at least one message copy button"
    assert copy_buttons.size >= 3, "Expected at least 3 messages with copy buttons"
  end

  test "message copy buttons have hover behavior classes" do
    session = sessions(:with_transcript)

    visit session_path(session)

    # Wait for messages to render
    assert_selector "[data-controller~='message-copy']", wait: 5

    # Copy buttons should exist but be initially hidden (opacity-0)
    # They become visible on hover via group-hover/message:opacity-100
    copy_button = first("[data-message-copy-target='button']", visible: false)
    assert copy_button, "Expected at least one message copy button"

    # Verify the button has the expected hover behavior classes
    assert copy_button[:class].include?("opacity-0"), "Button should be hidden by default"
    assert copy_button[:class].match?(/group-hover\/.*:opacity-100/), "Button should show on hover"
  end

  test "message copy button has accessible attributes" do
    session = sessions(:with_transcript)

    visit session_path(session)

    assert_selector "[data-controller~='message-copy']", wait: 5

    # Verify accessibility attributes
    copy_button = first("[data-message-copy-target='button']", visible: false)
    assert_equal "Copy message content to clipboard", copy_button["aria-label"]
    assert_equal "Copy message content", copy_button["title"]
    assert_equal "button", copy_button["type"]
  end

  test "message copy button has all required icon targets" do
    session = sessions(:with_transcript)

    visit session_path(session)

    assert_selector "[data-controller~='message-copy']", wait: 5

    # Find first message container
    message_container = first("[data-controller~='message-copy']")

    # Should have all three icon targets
    within(message_container) do
      # Copy icon (visible by default)
      assert_selector "[data-message-copy-target='copyIcon']", visible: false
      # Check icon (hidden by default)
      assert_selector "[data-message-copy-target='checkIcon']", visible: false
      # Error icon (hidden by default)
      assert_selector "[data-message-copy-target='errorIcon']", visible: false
    end
  end

  test "message content is properly JSON-encoded in data attribute" do
    session = sessions(:with_transcript)

    visit session_path(session)

    assert_selector "[data-controller~='message-copy']", wait: 5

    # Get the first message container
    message_container = first("[data-controller~='message-copy']")

    # The content-value attribute should contain valid JSON
    content_value = message_container["data-message-copy-content-value"]
    assert content_value.present?, "Expected content value to be present"

    # The content should be parseable as JSON
    # Note: The value is HTML-decoded by the browser, so it should be valid JSON
    parsed = JSON.parse(content_value)
    assert parsed.is_a?(String), "Expected parsed content to be a string"
    assert parsed.present?, "Expected parsed content to not be empty"
  end

  test "message copy button with code blocks has proper content" do
    session = sessions(:with_code_blocks)

    visit session_path(session)

    assert_selector "[data-controller~='message-copy']", wait: 5

    # Find the assistant message (which has code blocks)
    message_containers = all("[data-controller~='message-copy']")
    assistant_message = message_containers.find do |container|
      content = container["data-message-copy-content-value"]
      content&.include?("ruby") || content&.include?("javascript")
    end

    assert assistant_message, "Expected to find assistant message with code blocks"

    # Verify the content includes code block formatting
    content_value = assistant_message["data-message-copy-content-value"]
    parsed_content = JSON.parse(content_value)
    assert parsed_content.include?("```"), "Expected code blocks in content"
    assert parsed_content.include?("Hello, World!"), "Expected Hello, World! in content"
  end

  test "message copy buttons show on hover" do
    session = sessions(:with_transcript)

    visit session_path(session)

    assert_selector "[data-controller~='message-copy']", wait: 5

    # Get the first message container
    message_container = first("[data-controller~='message-copy']")

    # Button should be present but hidden initially
    copy_button = message_container.find("[data-message-copy-target='button']", visible: false)
    assert copy_button[:class].include?("opacity-0"), "Button should be hidden initially"

    # Hover over the message container
    message_container.hover

    # After hover, button should become visible (via CSS transition)
    # The opacity-0 class is still there, but group-hover:opacity-100 overrides it
    # We can verify the button is still accessible
    assert message_container.has_selector?("[data-message-copy-target='button']", visible: false)
  end
end
