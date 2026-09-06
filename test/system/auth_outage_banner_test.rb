require "application_system_test_case"

# The session page is the only surface a user actually looks at when a session
# stops making progress. Before this banner, a session parked for an exhausted
# account pool showed nothing but the runtime's own "Not logged in · Please run
# /login" text — no cause, and no sign it would come back on its own.
class AuthOutageBannerTest < ApplicationSystemTestCase
  def parked_session(reason:)
    Session.create!(
      prompt: "Test prompt",
      status: :waiting,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      metadata: {
        "auth_outage_reason" => reason,
        "auth_outage_parked_at" => Time.current.iso8601,
        "auth_outage_pool_recovers_at" => 1.hour.from_now.utc.iso8601
      }
    )
  end

  test "a quota-exhausted session explains the outage and how it comes back" do
    visit session_path(parked_session(reason: AuthOutageParkService::QUOTA_EXHAUSTED))

    assert_text "Quota exceeded across all accounts"
    assert_text "there is nothing to rotate into"
    # The sentence comes from AuthOutageWakeAuthority, so it names the mechanism
    # that is actually coming — the same one `get_session` names for an agent.
    assert_text "Zimmer's own auth-outage sweep resumes it, and that sweep runs every fifteen minutes"
    assert_text "The pool's earliest reset is"
  end

  # A spot session is woken in precedence order by the fleet wake, not simply
  # "when the pool recovers" — saying otherwise would promise a wake it does not
  # necessarily get next.
  test "a parked spot session says the fleet wake reaches it in precedence order" do
    session = parked_session(reason: AuthOutageParkService::QUOTA_EXHAUSTED)
    session.update!(scheduling_class: SessionGenesis::SPOT, precedence: 640)

    visit session_path(session)

    assert_text "fleet wake reaches it in precedence order"
    assert_text "640"
  end

  test "an auth-outage session names the login failure rather than the raw CLI text" do
    visit session_path(parked_session(reason: AuthOutageParkService::AUTH_UNRECOVERABLE))

    assert_text "No usable login available"
    assert_text "re-injecting credentials did not fix it"
  end

  # The banner's resume sentence grew when AuthOutageWakeAuthority took it over
  # (tadasant/zimmer#617), and it is read on a phone. Pinned at 375px: the amber
  # box has to stay inside the viewport, and the page has to stay no wider than
  # the screen — an overflow here is invisible on a laptop and unreachable on a
  # phone.
  test "the outage banner fits a 375px viewport" do
    page.driver.browser.manage.window.resize_to(375, 812)

    begin
      session = parked_session(reason: AuthOutageParkService::QUOTA_EXHAUSTED)
      session.update!(scheduling_class: SessionGenesis::SPOT, precedence: 640)
      visit session_path(session)
      assert_text "fleet wake reaches it in precedence order"

      assert page.evaluate_script(
        "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1"
      ), "the session page must not be wider than a 375px viewport"

      banner_overflow = page.evaluate_script(<<~JS)
        (function () {
          const limit = document.documentElement.clientWidth;
          const el = document.querySelector(".bg-amber-50");
          return el ? Math.round(el.getBoundingClientRect().right) - limit : -1;
        })()
      JS
      assert banner_overflow <= 1,
        "the outage banner's right edge is #{banner_overflow}px past the viewport"
    ensure
      page.driver.browser.manage.window.resize_to(1400, 900)
    end
  end

  test "a healthy session shows no outage banner" do
    session = Session.create!(
      prompt: "Test prompt",
      status: :needs_input,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main"
    )

    visit session_path(session)

    assert_no_text "Quota exceeded across all accounts"
    assert_no_text "No usable login available"
  end
end
