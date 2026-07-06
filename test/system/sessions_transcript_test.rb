require "application_system_test_case"

class SessionsTranscriptTest < ApplicationSystemTestCase
  # Test transcript display in session detail page
  # Per Issue #57, transcript and activity logs are now consolidated into a unified timeline
  test "session show page displays conversation and activity timeline section" do
    session = sessions(:running)

    visit session_path(session)

    assert_selector "[data-controller='transcript-copy'] button[aria-label='Copy full transcript to clipboard']"
  end

  test "session show page displays placeholder when no timeline items" do
    # Create a session with no transcript or logs
    session = Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Test session",
      status: :running,
      agent_runtime: "claude_code"
    )

    visit session_path(session)

    assert_text "Agent is running..."
    assert_text "The conversation and activity will appear here as the agent progresses"
  end

  test "session show page displays transcript messages in timeline" do
    session = sessions(:with_transcript)

    visit session_path(session)

    # Wait for the timeline column to render
    assert_selector "[data-controller='transcript-copy'] button[aria-label='Copy full transcript to clipboard']"

    # Should display the messages
    assert_text "Hello, can you help me?"
    assert_text "Of course! I'd be happy to help. What do you need?"
    assert_text "I need to create a new feature"

    # Should display role indicators
    assert_text "User"
    assert_text "Assistant"
  end

  test "timeline displays both conversation and activity logs together" do
    session = sessions(:with_transcript)

    visit session_path(session)

    # Wait for the timeline column to render
    assert_selector "[data-controller='transcript-copy'] button[aria-label='Copy full transcript to clipboard']"

    # Should NOT have separate "Conversation Transcript" or "Activity Logs" headers
    # — transcript and activity logs are consolidated into a single timeline.
    assert_no_text "Conversation Transcript"
    assert_no_text "Activity Logs"
  end
end
