require "application_system_test_case"

class SessionsTranscriptTest < ApplicationSystemTestCase
  # Test transcript display in session detail page
  # Per Issue pulsemcp/agents#57, transcript and activity logs are now consolidated
  # into a unified timeline
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

  # The panel's rows are a `<turbo-frame loading="lazy">`, and lazy is an
  # INTERSECTION trigger rather than a layout one: Turbo fetches when the frame
  # appears in the viewport. A short window puts the disclosure below the fold,
  # so opening it used to leave the frame on its skeleton indefinitely — which is
  # how two LostElicitationBannerTest cases failed
  # [CI run 34060027053](https://github.com/tadasant/zimmer/actions/runs/34060027053)
  # at Chrome's 800x600 default while passing at 1400x900.
  #
  # `transcript-panel#loadFrame` makes opening the disclosure the trigger, so the
  # rows have to arrive at a window where the panel starts off screen. The window
  # is the one from that run, and `page.visit` is deliberate: the suite's own
  # `visit` opens the panel for every caller, and this test has to look at the
  # page before that happens.
  test "opening the transcript below the fold still loads its rows" do
    page.driver.browser.manage.window.resize_to(800, 600)

    page.visit session_path(sessions(:with_transcript))

    assert_selector "details[data-controller~='transcript-panel']", visible: :all
    assert panel_below_the_fold?,
      "the Transcript disclosure has to start outside the viewport for this to test anything; " \
      "it is at #{panel_viewport_offset}px in a #{page.evaluate_script('window.innerHeight')}px viewport"

    open_transcript_panel

    assert_text "Hello, can you help me?"
  end

  private

  # How far below the top of the viewport the Transcript disclosure sits, in CSS
  # pixels. Read from the document rather than from a Capybara node: the question
  # is about position, and Capybara's own visibility has nothing to say about it.
  def panel_viewport_offset
    page.evaluate_script(<<~JS)
      document.querySelector("details[data-controller~='transcript-panel']").getBoundingClientRect().top
    JS
  end

  def panel_below_the_fold?
    panel_viewport_offset >= page.evaluate_script("window.innerHeight")
  end
end
