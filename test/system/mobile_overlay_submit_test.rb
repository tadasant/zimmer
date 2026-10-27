require "application_system_test_case"

class MobileOverlaySubmitTest < ApplicationSystemTestCase
  MOBILE_WIDTH = 375
  MOBILE_HEIGHT = 812

  setup do
    # Set a mobile viewport size (iPhone X dimensions, below the sm: 640px breakpoint)
    page.driver.browser.manage.window.resize_to(MOBILE_WIDTH, MOBILE_HEIGHT)
  end

  teardown do
    # Restore default desktop viewport to avoid affecting other tests
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  test "mobile drawer shows collapsed trigger bar on session show page" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Mobile trigger bar should be visible (sm:hidden means visible below 640px)
    assert_selector "[data-bottom-drawer-target='trigger']", visible: true
    assert_text "Send a follow-up..."

    # The full form content should be hidden on mobile by default
    # Use visible: :hidden to assert the element exists but is not visible
    assert_selector "[data-bottom-drawer-target='content']", visible: :hidden
  end

  test "tapping mobile trigger opens the drawer and reveals the form" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Tap the collapsed trigger bar to open the drawer
    find("[data-bottom-drawer-target='trigger'] button").click

    # The full form content should now be visible
    assert_selector "[data-bottom-drawer-target='content']", visible: true

    # Should see the mobile textarea and submit button
    assert_selector "textarea[name='follow_up_prompt_mobile']", visible: true
    assert_selector "[data-follow-up-prompt-target='submitButtonMobile']", visible: true
  end

  test "mobile close button collapses the drawer" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Open the drawer
    find("[data-bottom-drawer-target='trigger'] button").click
    assert_selector "[data-bottom-drawer-target='content']", visible: true

    # Click the close button (sm:hidden, visible on mobile)
    find("[data-action='click->bottom-drawer#close']").click

    # The drawer should collapse back
    assert_selector "[data-bottom-drawer-target='content']", visible: :hidden
    assert_selector "[data-bottom-drawer-target='trigger']", visible: true
  end

  test "submitting follow-up via mobile overlay creates session activity" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Open the mobile drawer
    find("[data-bottom-drawer-target='trigger'] button").click

    # Fill in the mobile textarea
    mobile_textarea = find("textarea[name='follow_up_prompt_mobile']")
    mobile_textarea.fill_in with: "Mobile follow-up message"

    # Submit via the mobile submit button
    find("[data-follow-up-prompt-target='submitButtonMobile']").click

    # The optimistic message should appear in the timeline
    assert_text "Mobile follow-up message"

    # `waiting`, not `running`: since #1040 the follow-up hands the turn to the
    # `agents` queue, and a worker's `start` is what makes the session `running`.
    # The running indicator follows the turn rather than the submit, so what this
    # asserts is the hand-over.
    session.reload
    assert_equal "waiting", session.status
    assert_equal "Mobile follow-up message", TurnSource.strip(session.metadata["pending_follow_up_prompt"])
  end

  test "mobile overlay shows queue mode for running session" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :running,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Mobile trigger should show queue messaging
    assert_text "Queue a message..."

    # Open the drawer
    find("[data-bottom-drawer-target='trigger'] button").click

    # Mobile submit button should say "Queue Message"
    assert_selector "[data-follow-up-prompt-target='submitButtonMobile']", text: "Queue Message"
  end

  test "mobile overlay is not shown for archived session" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :archived,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Follow-up form should not be rendered for archived sessions
    assert_no_selector "[data-bottom-drawer-target='trigger']"
    assert_no_selector "textarea[name='follow_up_prompt_mobile']", visible: :all
  end

  test "cannot submit empty message via mobile overlay" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Open the mobile drawer
    find("[data-bottom-drawer-target='trigger'] button").click

    # Try to submit without entering a message
    accept_alert "Please enter a follow-up prompt" do
      find("[data-follow-up-prompt-target='submitButtonMobile']").click
    end

    # Should still be on the same page
    assert_current_path session_path(session)
  end

  test "escape key closes the mobile drawer" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    # Open the drawer
    find("[data-bottom-drawer-target='trigger'] button").click
    assert_selector "[data-bottom-drawer-target='content']", visible: true

    # Press Escape to close
    find("body").send_keys(:escape)

    # The drawer should collapse
    assert_selector "[data-bottom-drawer-target='content']", visible: :hidden
    assert_selector "[data-bottom-drawer-target='trigger']", visible: true
  end

  # The detail screen's two deferred panels are on screen twice — once as a
  # skeleton, once as the content that replaces it — and a placeholder sized for a
  # laptop is exactly the kind of thing that reaches past a phone's right edge
  # without anything failing. Both states are measured.
  #
  # Two probes, because each is blind to something the other sees: the document
  # measure cannot see past a clipping ancestor, and getBoundingClientRect cannot
  # be fooled by one but does see the off-canvas overlays the layout parks to the
  # right of the viewport on purpose (the notes drawer, the chat bubble), which is
  # why those are excluded by their own transform class rather than by position.
  # A horizontal scroll strip (`overflow-x-auto` — the board's view switcher) is
  # excluded too: its overflow is reachable by scrolling, which is its purpose.
  test "the deferred panels fit a phone, as skeletons and as content" do
    session = Session.create!(
      prompt: "Initial prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      transcript: 3.times.map { |i|
        { type: "user", message: { role: "user", content: "Message #{i}" },
          timestamp: (Time.current - (3 - i).minutes).iso8601 }.to_json
      }.join("\n")
    )

    visit session_path(session)

    # Skeleton state: opened before the frames land, so both placeholders are up.
    page.execute_script(
      "document.querySelector(\"details[data-controller~='transcript-panel']\").open = true"
    )
    assert_no_horizontal_overflow("deferred panel skeletons")

    # Content state, with every disclosure open.
    open_provenance_panels
    assert_selector "turbo-frame[id$='_transcript'][complete]", visible: :all
    assert_no_horizontal_overflow("deferred panel content")
  end

  # The CarPlay-fit chip and its control are on the User view row and on the
  # phone's bottom sheet; the popover is sized for a laptop column, which is
  # exactly the kind of width that reaches past a phone's right edge.
  test "the CarPlay fit chip and control fit a phone, on the board and the session page" do
    session = Session.create!(
      prompt: "Initial prompt",
      title: "Paste the Grafana and 1Password secrets into the strad console",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      carplay_fit: SessionCarplayFit::LAPTOP_ONLY,
      carplay_fit_reason: SessionCarplayFit::REASON_CREDENTIAL,
      carplay_fit_source: SessionCarplayFit::SOURCE_AUTO,
      carplay_fit_line_count: 0,
      carplay_fit_set_at: Time.current
    )

    visit root_path(view: SessionsController::VIEW_MODE_USER)
    assert_selector "#user_view_row_#{session.id} [data-carplay-fit='laptop_only']", text: "Laptop only"
    assert_no_horizontal_overflow("User view row with the CarPlay fit chip")

    find("#user_view_row_#{session.id} details[data-carplay-fit-menu] summary").click
    assert_selector "#user_view_row_#{session.id} button[name='carplay_fit'][value='carplay_ok']", visible: true
    assert_no_horizontal_overflow("User view row with the CarPlay fit popover open")
    # The popover hangs off a control on the LEFT of the row, so the edge it can
    # fall off at 375px is the left one, which the overflow probes never measure.
    popover_left = page.evaluate_script(
      "document.querySelector('#user_view_row_#{session.id} details[data-carplay-fit-menu] form').getBoundingClientRect().left"
    )
    assert_operator popover_left, :>=, 0, "the CarPlay fit popover hangs off the left edge at #{MOBILE_WIDTH}px"
    page.execute_script(
      "document.querySelector('#user_view_row_#{session.id} details[data-carplay-fit-menu]').scrollIntoView({ block: 'start' })"
    )
    page.save_screenshot("tmp/screenshots/carplay-fit-board-375.png")

    visit session_path(session)
    # The header's control is `hidden md:block`; the phone reaches it from the
    # bottom sheet, whose disclosure expands inline. The sheet is slid in the way
    # the joystick controller's fallback does it, so the item is measured on
    # screen rather than off-canvas.
    find("[data-joystick-menu-target='sheet'] details[data-carplay-fit-menu] summary", visible: :all)
    page.execute_script(<<~JS)
      const sheet = document.querySelector("[data-joystick-menu-target='sheet']");
      sheet.classList.remove("translate-y-full", "opacity-0");
      sheet.classList.add("translate-y-0", "opacity-100");
      document.querySelector("[data-joystick-menu-target='sheetOverlay']").classList.remove("hidden");
      const item = sheet.querySelector("details[data-carplay-fit-menu]");
      item.open = true;
      item.scrollIntoView({ block: "center" });
    JS
    assert_selector "[data-joystick-menu-target='sheet'] button[name='carplay_fit'][value='laptop_only']", visible: true
    assert_no_horizontal_overflow("session page with the CarPlay fit sheet item open")
    page.save_screenshot("tmp/screenshots/carplay-fit-session-375.png")
  end

  private

  def assert_no_horizontal_overflow(label)
    assert page.evaluate_script(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1"
    ), "#{label}: the document is wider than the viewport at #{MOBILE_WIDTH}px"

    offenders = page.evaluate_script(<<~JS)
      (function () {
        const limit = document.documentElement.clientWidth;
        return Array.from(document.querySelectorAll("*"))
          .filter((el) => el.getBoundingClientRect().right > limit + 1)
          .filter((el) => !el.closest('[class*="translate-x-full"]'))
          .filter((el) => !el.closest('.overflow-x-auto'))
          .slice(0, 20)
          .map((el) => `${el.tagName.toLowerCase()}.${el.classList.value} @ ${Math.round(el.getBoundingClientRect().right)}px`);
      })()
    JS

    assert_empty offenders,
      "#{label}: these elements reach past the right edge at #{MOBILE_WIDTH}px: #{offenders.join(', ')}"
  end
end
