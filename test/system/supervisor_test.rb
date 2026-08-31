require "application_system_test_case"

class SupervisorTest < ApplicationSystemTestCase
  include SupervisorAuthTestHelper

  setup do
    @session = sessions(:running)
    @log = logs(:info_log)
    present_supervisor_credential
  end

  test "visiting the sessions index shows supervisor button" do
    visit root_url
    assert_selector "h1", text: "Agent Sessions"
    assert_link "Supervisor", href: supervisor_root_path
  end

  test "clicking supervisor button navigates to supervisor sessions" do
    visit root_url
    click_link "Supervisor"
    assert_selector "h1", text: "Sessions"
    assert_current_path supervisor_root_path
  end

  test "supervisor sessions index displays sessions" do
    visit supervisor_sessions_url
    assert_selector "h1", text: "Sessions"
    assert_text @session.prompt
  end

  test "supervisor sessions show page displays session details" do
    visit supervisor_session_url(@session)
    assert_text @session.prompt
    assert_text @session.git_root
    assert_text @session.branch
  end

  test "supervisor logs index displays logs" do
    visit supervisor_logs_url
    assert_selector "h1", text: "Logs"
    assert_text @log.content
  end

  test "supervisor logs show page displays log details" do
    visit supervisor_log_url(@log)
    assert_text @log.content
    assert_text @log.level
  end

  # The 401 body the realm serves to a speculative (prefetched) request. It is a
  # real screen — Turbo hands a prefetched response to a later click on the same
  # link — and Zimmer gets read on a phone, so it has to fit one.
  test "the prefetch refusal page fits a phone and offers a way in" do
    page.driver.browser.manage.window.resize_to(375, 812)
    present_prefetch_marker_instead_of_credential

    visit supervisor_root_url

    assert_selector "h1", text: "Sign in to Supervisor"
    assert_link "Continue to Supervisor", href: supervisor_root_path

    # Probe 1: the document is no wider than the viewport.
    assert page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1"),
      "the page is wider than a 375px viewport"

    # Probe 2: nothing sticks out past the right edge. Probe 1 cannot see past a
    # clipping ancestor or a fixed box; this can.
    overflowing = page.evaluate_script(<<~JS)
      (function () {
        const limit = document.documentElement.clientWidth;
        return Array.from(document.querySelectorAll("*"))
          .filter((el) => el.getBoundingClientRect().right > limit + 1)
          .slice(0, 20)
          .map((el) => `${el.tagName.toLowerCase()}.${el.classList.value} @ ${Math.round(el.getBoundingClientRect().right)}px`);
      })()
    JS
    assert_empty overflowing, "elements past the right edge at 375px: #{overflowing.inspect}"

    page.save_screenshot(Rails.root.join("tmp/screenshots/supervisor-prefetch-401-375.png").to_s)
  ensure
    page.driver.browser.manage.window.resize_to(1400, 900)
  end

  private

  # Replaces the credential set in `setup` with the marker Turbo puts on a
  # hover-prefetch, so the browser asks for /supervisor exactly the way a
  # prefetch does. Network.setExtraHTTPHeaders replaces the whole header set, so
  # this drops the Authorization header rather than adding to it.
  def present_prefetch_marker_instead_of_credential
    page.driver.browser.execute_cdp(
      "Network.setExtraHTTPHeaders",
      headers: { "X-Sec-Purpose" => "prefetch" }
    )
  end

  # Chrome has no Capybara-level hook for request headers, and the panel is
  # behind an HTTP Basic realm — an unauthenticated `visit` lands on a 401, not
  # a dashboard. Push the credential in over CDP so every request the browser
  # makes for the rest of the test carries it. This is the browser-side
  # equivalent of SupervisorAuthTestHelper::AutoBasicAuth.
  def present_supervisor_credential
    browser = page.driver.browser
    browser.execute_cdp("Network.enable")
    browser.execute_cdp(
      "Network.setExtraHTTPHeaders",
      headers: { "Authorization" => supervisor_basic_credentials }
    )
  end
end
