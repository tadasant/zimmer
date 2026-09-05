require "application_system_test_case"

# A grant renewed while the session was already live cannot reach the agent
# process that is running: Claude Code reads its MCP servers once, at launch. So
# the session page has to say so — before this banner the user saw "Successfully
# authorized", a session with none of that server's tools, and nothing at all
# connecting the two (#195).
class McpOauthReconnectBannerTest < ApplicationSystemTestCase
  include MobileOverflowAssertions

  NOTICE_HEADING = "Authorization complete — reconnects on the next turn".freeze

  def live_session(status:, servers: [ "notion" ])
    session = Session.create!(
      prompt: "Investigate the failure and land a fix.",
      status: status,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      mcp_servers: servers
    )
    session.merge_metadata!(
      Session::MCP_OAUTH_RECONNECT_KEY => {
        "servers" => servers, "authorized_at" => Time.current.iso8601
      }
    )
    session
  end

  test "a needs_input session says the grant is back and offers to reconnect" do
    visit session_path(live_session(status: :needs_input))

    assert_text NOTICE_HEADING
    assert_text "Zimmer has stored the renewed grant for notion"
    assert_text "Send a message to reconnect."
    assert_selector "input[type=submit][value='Reconnect now']"
  end

  # Mid-turn the message queues rather than being delivered, and the banner must
  # not promise otherwise.
  test "a running session says the reconnect message queues behind the current turn" do
    visit session_path(live_session(status: :running))

    assert_text NOTICE_HEADING
    assert_text "a message sent now queues and reconnects on the turn after it"
    assert_selector "input[type=submit][value='Queue a reconnect message']"
  end

  test "a session with no renewed grant shows no notice" do
    session = Session.create!(
      prompt: "Investigate the failure and land a fix.",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      mcp_servers: [ "notion" ]
    )

    visit session_path(session)

    assert_text "Needs Input"
    assert_no_text NOTICE_HEADING
  end

  # The notice carries a button, and a button row that cannot wrap is exactly how
  # a control ends up off the right edge of a phone.
  test "the notice fits a phone" do
    page.driver.browser.manage.window.resize_to(MOBILE_WIDTH, MOBILE_HEIGHT)

    visit session_path(live_session(status: :needs_input, servers: [ "notion", "linear" ]))
    assert_text NOTICE_HEADING

    assert_no_horizontal_overflow("session page with the MCP OAuth reconnect notice")

    page.save_screenshot("screenshots/mcp-oauth-reconnect-375.png")
  ensure
    page.driver.browser.manage.window.resize_to(1400, 900)
  end
end
