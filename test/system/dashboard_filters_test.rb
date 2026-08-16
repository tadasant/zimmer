require "application_system_test_case"

# The dashboard's Filters section, driven through a real browser: the default
# needs_input-only view, a multi-status selection, persistence across a reload,
# "none selected means show all", and Reset.
#
# The 375px case here is about *legibility* — it captures the phone screenshot that
# goes in the PR. The geometry invariant (nothing scrolls sideways, nothing is
# clipped out of reach) is asserted where the house convention keeps it, in
# test/system/mobile_horizontal_overflow_test.rb.
class DashboardFiltersTest < ApplicationSystemTestCase
  MOBILE_WIDTH = 375
  MOBILE_HEIGHT = 812
  DESKTOP_WIDTH = 1400
  DESKTOP_HEIGHT = 900

  SCREENSHOT_DIR = Rails.root.join("tmp", "screenshots")

  setup do
    McpOauthPendingFlow.delete_all
    Notification.delete_all
    Log.delete_all
    Session.delete_all

    @needs_input = create_session(:needs_input)
    @running = create_session(:running)
    @failed = create_session(:failed)
    @archived = create_session(:archived)

    FileUtils.mkdir_p(SCREENSHOT_DIR)
  end

  teardown do
    page.driver.browser.manage.window.resize_to(DESKTOP_WIDTH, DESKTOP_HEIGHT)
  end

  test "filters default to needs_input, survive a reload, and reset" do
    page.driver.browser.manage.window.resize_to(DESKTOP_WIDTH, DESKTOP_HEIGHT)

    # 1. Default: the queue only.
    visit root_path
    assert_selector "h2", text: "Filters"
    assert_card @needs_input
    refute_card @running
    refute_card @failed
    refute_card @archived
    page.save_screenshot(SCREENSHOT_DIR.join("filters-default-needs-input.png").to_s)

    # 2. Multi-select: two statuses at once, and the queue drops out.
    uncheck_status("needs_input")
    check_status("running")
    check_status("failed")
    click_on "Apply filters"

    assert_card @running
    assert_card @failed
    refute_card @needs_input
    refute_card @archived
    page.save_screenshot(SCREENSHOT_DIR.join("filters-multi-status.png").to_s)

    # 3. Persistence: a bare visit to / — no query string at all — keeps the choice.
    visit root_path
    assert_card @running
    assert_card @failed
    refute_card @needs_input
    assert page.has_checked_field?("status-filter-running")
    assert page.has_checked_field?("status-filter-failed")

    # 4. None selected means every status, archived included.
    uncheck_status("running")
    uncheck_status("failed")
    click_on "Apply filters"

    assert_card @needs_input
    assert_card @running
    assert_card @failed
    assert_card @archived

    # ...and that too persists across a reload.
    visit root_path
    assert_card @archived

    # 5. Reset puts it back to the default.
    click_on "Reset filters"
    assert_card @needs_input
    refute_card @archived
    assert page.has_checked_field?("status-filter-needs-input")
  end

  test "the Filters section is legible at a 375px phone viewport" do
    page.driver.browser.manage.window.resize_to(MOBILE_WIDTH, MOBILE_HEIGHT)

    visit root_path
    assert_selector "h2", text: "Filters"
    assert_card @needs_input
    page.save_screenshot(SCREENSHOT_DIR.join("filters-375px.png").to_s)

    # ...and with a multi-status selection applied, where the pills wrap.
    check_status("running")
    click_on "Apply filters"
    assert_card @running
    assert_card @needs_input
    page.save_screenshot(SCREENSHOT_DIR.join("filters-375px-multi-status.png").to_s)
  end

  private

  def create_session(status)
    Session.create!(
      git_root: "https://github.com/test/repo.git",
      prompt: "Dashboard filter #{status}",
      title: "Dashboard filter #{status}",
      status: status,
      agent_runtime: "claude_code"
    )
  end

  def assert_card(session)
    assert_selector "turbo-frame##{ActionView::RecordIdentifier.dom_id(session)}",
      count: 1, wait: 5
  end

  def refute_card(session)
    assert_no_selector "turbo-frame##{ActionView::RecordIdentifier.dom_id(session)}"
  end

  # The status pills hide nothing — each is a real checkbox — but they sit inside a
  # <label>, so drive them by id rather than by label text.
  def check_status(status)
    check "status-filter-#{status.dasherize}", allow_label_click: true
  end

  def uncheck_status(status)
    uncheck "status-filter-#{status.dasherize}", allow_label_click: true
  end
end
