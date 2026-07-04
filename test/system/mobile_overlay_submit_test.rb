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

    # Session should transition to running
    assert_text "Agent is running"

    # Session status should be updated in the database
    session.reload
    assert_equal "running", session.status
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
end
