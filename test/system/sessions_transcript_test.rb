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
  # page before that happens. It skips the post-`visit` Turbo Stream readiness
  # wait with it, which costs nothing here — the rows come from the frame's own
  # fetch, not from a broadcast.
  test "opening the transcript below the fold still loads its rows" do
    page.driver.browser.manage.window.resize_to(800, 600)

    page.visit session_path(sessions(:with_transcript))
    wait_for_stimulus_controller("transcript-panel")

    assert_panel_below_the_fold

    open_transcript_panel

    assert_text "Hello, can you help me?"
  end

  # The other opening nobody scrolls to, and the one a reader actually meets: the
  # log-level filter re-fetches with `transcript=open` so the panel comes back
  # open at the level just picked (log_level_filter_controller.js#refetchAtLevel).
  # That page renders the disclosure already open, so no toggle fires and
  # #loadFrame has to be reached through `frameTargetConnected` instead. On a
  # phone the panel is a long way down the page, so intersection cannot be what
  # rescues it.
  test "a transcript rendered already open loads its rows below the fold" do
    page.driver.browser.manage.window.resize_to(800, 600)

    page.visit session_path(sessions(:with_transcript), transcript: "open")
    wait_for_stimulus_controller("transcript-panel")

    assert_selector "details[data-controller~='transcript-panel'][open]", visible: :all
    assert_panel_below_the_fold

    assert_selector "turbo-frame[id$='_transcript'][complete]", wait: 10
    assert_text "Hello, can you help me?"
  end

  private

  # Both tests above are only about the frame's fetch trigger, so each has to
  # prove that the trigger the fix replaces — appearing in the viewport — is
  # genuinely unavailable. Without this a layout change that lifts the panel
  # above the fold would leave two tests that pass for the wrong reason.
  def assert_panel_below_the_fold
    assert_selector "details[data-controller~='transcript-panel']", visible: :all

    # Stated rather than assumed. A reader who has not scrolled is at the top of
    # the page, which is the position both tests are about; leaving it to
    # whatever the composer's autofocus and the sticky footer settle on would
    # make the precondition an accident of layout rather than the case under
    # test.
    page.execute_script("window.scrollTo(0, 0)")

    viewport_height = page.evaluate_script("window.innerHeight")
    offset = panel_viewport_offset

    assert offset >= viewport_height,
      "the Transcript disclosure has to start outside the viewport for this to test anything; " \
      "it is at #{offset}px in a #{viewport_height}px viewport"
  end

  # How far below the top of the viewport the Transcript disclosure sits, in CSS
  # pixels. Read from the document rather than from a Capybara node: the question
  # is about position, and Capybara's own visibility has nothing to say about it.
  def panel_viewport_offset
    page.evaluate_script(<<~JS)
      document.querySelector("details[data-controller~='transcript-panel']").getBoundingClientRect().top
    JS
  end
end
