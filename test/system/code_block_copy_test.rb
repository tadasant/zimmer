require "application_system_test_case"

class CodeBlockCopyTest < ApplicationSystemTestCase
  # Test that code blocks in transcripts have copy buttons
  test "code blocks in transcript messages have copy buttons" do
    session = sessions(:with_code_blocks)

    visit session_path(session)

    # Wait for the code block controller to enhance the pre elements
    # The controller adds a wrapper div with class "code-block-wrapper"
    assert_selector ".code-block-wrapper", wait: 5

    # Copy buttons exist but are hidden by default (opacity-0)
    # Use visible: false to find them, minimum: 2 for Ruby and JS examples
    assert_selector ".code-copy-button", visible: false, minimum: 2
  end

  test "copy buttons have hover behavior classes" do
    session = sessions(:with_code_blocks)

    visit session_path(session)

    # Wait for enhancement
    assert_selector ".code-block-wrapper", wait: 5

    # Copy buttons should exist but be initially hidden (opacity-0)
    # They become visible on hover via group-hover:opacity-100
    copy_buttons = all(".code-copy-button", visible: false)
    assert copy_buttons.any?, "Expected at least one copy button"

    # Verify the button has the expected hover behavior classes
    first_button = copy_buttons.first
    assert first_button[:class].include?("opacity-0"), "Button should be hidden by default"
    assert first_button[:class].include?("group-hover:opacity-100"), "Button should show on hover"
  end

  test "code blocks without pre tags are not enhanced" do
    session = sessions(:with_transcript)

    visit session_path(session)

    # This session has no code blocks, so no wrappers should be added
    assert_no_selector ".code-block-wrapper"
    assert_no_selector ".code-copy-button", visible: false
  end

  test "copy button has accessible attributes" do
    session = sessions(:with_code_blocks)

    visit session_path(session)

    assert_selector ".code-block-wrapper", wait: 5

    # Verify accessibility attributes (use visible: false since buttons are hidden until hover)
    copy_button = first(".code-copy-button", visible: false)
    assert_equal "Copy code to clipboard", copy_button["aria-label"]
    assert_equal "Copy code", copy_button["title"]
    assert_equal "button", copy_button["type"]
  end

  test "enhanced markdown partial renders code blocks correctly" do
    session = sessions(:with_code_blocks)

    visit session_path(session)

    # Should render the code content
    assert_text "Hello, World!"
    assert_text "puts"
    assert_text "console.log"

    # The pre elements should be wrapped
    assert_selector ".code-block-wrapper pre"
  end
end
