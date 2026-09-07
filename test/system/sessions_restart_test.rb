require "application_system_test_case"

# The Restart control in a real browser, in the states it is and is not offered.
#
# Until [#830](https://github.com/tadasant/zimmer/issues/830) the web door was
# strictly narrower than the other two: a session stranded in `needs_input` was
# restartable by an agent through MCP and by a script through the REST API, and
# by a person not at all. The button now follows Session#restartable_by_hand?,
# which is the `may_resume?` those two doors gate on minus `waiting`.
class SessionsRestartTest < ApplicationSystemTestCase
  def session_in(status, session_id: SecureRandom.uuid)
    Session.create!(
      prompt: "Test prompt",
      title: "Restart affordance #{status}",
      status: status,
      agent_runtime: "claude_code",
      git_root: "https://github.com/test/repo.git",
      branch: "main",
      session_id: session_id
    )
  end

  test "Restart is offered for a failed session and fires without a dialog" do
    visit session_path(session_in(:failed))

    assert_link "Restart"
    assert_nil find_link("Restart")["data-turbo-confirm"],
      "restarting a failed session is the operation the button has always named"
  end

  test "Restart is offered for a needs_input session and says it is a takeover" do
    visit session_path(session_in(:needs_input))

    assert_link "Restart"
    assert_match(/paused, not failed/, find_link("Restart")["data-turbo-confirm"])
  end

  # The case that motivated the issue: paused with no conversation behind it, so
  # the same click re-runs the whole setup pipeline instead of continuing one.
  test "Restart on a never-run needs_input session says the pipeline re-runs" do
    visit session_path(session_in(:needs_input, session_id: nil))

    assert_link "Restart"
    assert_match(/setup never finished/, find_link("Restart")["data-turbo-confirm"])
  end

  # The whole click, end to end: the dialog is shown, accepting it posts the
  # restart, and the session that a human could not restart at all before this
  # change comes back resumed with its turn queued.
  test "accepting the dialog restarts a never-run needs_input session" do
    session = session_in(:needs_input, session_id: nil)
    visit session_path(session)

    accept_confirm(/setup never finished/) { click_link "Restart" }

    # The flash is a toast on a dismissal timer, so what is asserted is the state
    # the click left behind rather than the message it flashed on the way.
    assert_no_link "Restart", wait: 5
    assert_equal "waiting", session.reload.status
    assert session.logs.where("content LIKE ?", "%Restarting session from scratch%").exists?
  end

  test "Restart is not offered for a waiting session" do
    visit session_path(session_in(:waiting))

    assert_no_link "Restart"
  end

  test "Restart is not offered for a running session" do
    visit session_path(session_in(:running))

    assert_no_link "Restart"
  end

  # The mobile joystick's sheet is the phone twin of the header, and reads the
  # same predicate. Asserted with `visible: :all` because the sheet is `md:hidden`
  # and closed at the desktop viewport these tests run at.
  test "the mobile sheet offers Restart in the same states as the header" do
    visit session_path(session_in(:needs_input))
    assert_selector "button[data-petal-key='restart']", visible: :all

    visit session_path(session_in(:waiting))
    assert_no_selector "button[data-petal-key='restart']", visible: :all
  end

  # A dashboard card that gained a button gained it on a phone too, where the
  # footer row is the one that runs out of width — a control that lands past the
  # right edge is unreachable and nothing fails to say so. Both overflow probes,
  # at the 375px reference width: the document must not be wider than the
  # viewport, and nothing may stick out past its right edge.
  test "the Restart button a needs_input card gained fits a 375px phone" do
    session = session_in(:needs_input)
    page.driver.browser.manage.window.resize_to(375, 812)
    visit root_path

    card = find("#session_#{session.id}")
    assert card.has_button?("Restart"), "the card should offer Restart for a needs_input session"

    assert page.evaluate_script(
      "document.documentElement.scrollWidth <= document.documentElement.clientWidth + 1"
    ), "the dashboard is wider than a 375px viewport"

    boxes = page.evaluate_script(<<~JS)
      (function () {
        const limit = document.documentElement.clientWidth;
        return Array.from(document.querySelectorAll("form[action$='/restart'] button"))
          .map((el) => ({ right: el.getBoundingClientRect().right, limit: limit }));
      })()
    JS

    assert boxes.any?, "the probe found no Restart button to measure"
    boxes.each do |box|
      assert_operator box["right"], :<=, box["limit"] + 1,
        "a Restart button ends past the right edge of a 375px viewport"
    end
  ensure
    page.driver.browser.manage.window.resize_to(1400, 900)
  end
end
