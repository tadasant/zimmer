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

  private

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
